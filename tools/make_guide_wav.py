# R10 急救语音 GUIDE.WAV：默认用 edge-tts 晓晓（zh-CN-XiaoxiaoNeural，要联网）合成 43 段，按 guide_seq 的段号排好（R11 换了 33~38 / 41 段）；
#   --offline 改用 Windows 自带的 Microsoft Huihui（离线后备，音质发虚）。
#   用法（仓库根目录）：python -I tools/make_guide_wav.py [输出.wav] [--offline]
#   默认输出 out/test_card_r10/GUIDE.WAV，另存每段试听 out/guide/NN.wav 和时长表 out/guide/list.txt
# 格式（和 MUSIC.WAV 一样）：48 kHz 16 位单声道，WAV 头补到 512 字节；之后第 n 段固定 1024 个扇区（262144 个样点 = 5.46 秒），
#   不够补静音。FPGA 按 段起点 = 数据起点 + n × 1024 扇区 直接读，不解析 WAV 头，所以 GUIDE.WAV 必须连续存放（格式化后按顺序拷入）。
# 每段有时长上限（要在下一个时刻到来之前说完，见 io/guide_seq.v 的时刻表）：合成后去掉首尾静音，超了就加快一档语速重合成。
# edge-tts 出 mp3，用 miniaudio 解码成 48 kHz 16 位单声道。
import asyncio
import os
import struct
import subprocess
import sys
import tempfile
import time
import wave

import numpy as np

try:
    sys.stdout.reconfigure(encoding='utf-8')
except AttributeError:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
args = sys.argv[1:]
OFFLINE = '--offline' in args
if OFFLINE:
    args.remove('--offline')
OUT = args[0] if args else os.path.join(ROOT, 'out', 'test_card_r11', 'GUIDE.WAV')
RATE = 48000
SLOT = 1024 * 256                            # 每段样点数
VOICE = 'zh-CN-XiaoxiaoNeural'
BEEP = 0.5                                   # 吹气提示音长度（秒）

CN = ['一', '二', '三', '四', '五', '六', '七', '八', '九', '十']
def num(n):
    if n <= 10:
        return CN[n - 1]
    t, u = divmod(n, 10)
    return ('' if t == 1 else CN[t - 1]) + '十' + (CN[u - 1] if u else '')

# (文字, 时长上限秒, 晓晓起始语速 %, 慧慧起始语速, 是否接提示音)；段号 = 列表下标
#   上限 = 下一句到来前说完（guide_seq 时刻表，doc/R11_方案.md）；接提示音的段，上限含 0.5 秒提示音（R11 起没有段接提示音）
#   秒相位不清：一部分开头的第一秒可能不足 1 秒，所以上限都比两句间隔少 0.1 秒
SEGS = [(num(n), 0.48, 40, 4, False) for n in range(1, 31)] + [   # 0~29  ② 每拍（545 ms 一拍）
    ('拍他双肩，大声喊：你怎么了', 2.9, 0, 1, False),               # 30  ① 2 秒（5 秒播 31）
    ('看胸口有没有起伏', 1.9, 0, 1, False),                         # 31  ① 5 秒（7 秒开始倒数五~一）
    ('没有呼吸！一人打一二零，一人去取AED，位置看黄条', 4.8, 0, 1, False),  # 32  ① 12 秒（17 秒播 41）
    ('按图片技巧，按压两乳头中间，三十次', 3.5, 0, 1, False),       # 33  ② 第一次 / K1 重讲 0 秒（停顿约 5 秒，9 秒播 37）
    ('下面进行人工呼吸，捏鼻包嘴，吹气两次，第一次，开始', 4.9, 10, 2, False),   # 34  人工呼吸 0 秒（5 秒吹第 1 口）
    ('第二次吹气', 0.95, 10, 4, False),                             # 35  人工呼吸 6 秒（7 秒吹第 2 口）
    ('继续准备按压', 1.9, 0, 2, False),                             # 36  人工呼吸 8 秒（10 秒下一组）
    ('开始按压', 0.95, 10, 2, False),                               # 37  ② 准备 9 秒（10 秒第 1 拍）
    ('这里有人晕倒了', 1.9, 0, 1, False),                           # 38  ① 0 秒（2 秒播 30）
    ('继续按压，跟我数', 2.9, 0, 1, False),                         # 39  ③ 回 ②（准备 3 秒）
    ('AED到了，打开AED，照图做', 4.8, 0, 1, False),                 # 40  ③ 0 秒（5 秒播 42）
    ('下面进行CPR按压和人工呼吸', 4.5, 0, 1, False),                # 41  ① 17 秒（之后等 K3）
    ('听AED语音，别碰患者', 5.3, 0, 1, False),                      # 42  ③ 5 秒
]
assert len(SEGS) == 43
GD = os.path.join(ROOT, 'out', 'guide')
os.makedirs(GD, exist_ok=True)


def trim(x):
    """去掉首尾静音（留 10 ms）"""
    on = np.nonzero(np.abs(x) > 600)[0]
    if len(on) == 0:
        return x[:0]
    return x[max(0, on[0] - 480): on[-1] + 480]


# ---------------- edge-tts 晓晓（默认） ----------------
async def _edge(text, rate):
    import edge_tts
    c = edge_tts.Communicate(text, VOICE, rate='%+d%%' % rate)
    b = b''
    async for ch in c.stream():
        if ch['type'] == 'audio':
            b += ch['data']
    return b


def edge_say(text, rate):
    import miniaudio
    for k in range(4):                         # 联网失败重试
        try:
            mp3 = asyncio.run(_edge(text, rate))
            if not mp3:
                raise RuntimeError('没有收到音频')
            d = miniaudio.decode(mp3, output_format=miniaudio.SampleFormat.SIGNED16, nchannels=1, sample_rate=RATE)
            return trim(np.frombuffer(d.samples, '<i2').astype(np.float64))
        except Exception as e:
            print('  联网合成失败（第 %d 次）「%s」%+d%%：%s' % (k + 1, text, rate, e))
            time.sleep(2 + 3 * k)
    sys.exit('edge-tts 合成失败，检查网络，或加 --offline 用慧慧离线合成')


def edge_rates(r0):
    return list(range(r0, 101, 10))           # 逐档 +10%，最快 +100%


# ---------------- Windows 慧慧（--offline 后备） ----------------
def winpath(p):
    r = subprocess.run(['cygpath', '-w', p], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else p


def huihui(jobs):
    """jobs: [(文字, 语速, 输出路径)]，一次 PowerShell 合成全部（48 kHz 16 位单声道）"""
    tmp = tempfile.NamedTemporaryFile('w', suffix='.ps1', delete=False, encoding='utf-8-sig')
    tmp.write('Add-Type -AssemblyName System.Speech\n'
              '$s = New-Object System.Speech.Synthesis.SpeechSynthesizer\n'
              '$s.SelectVoice("Microsoft Huihui Desktop")\n'
              '$f = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(48000, '
              '[System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)\n')
    for text, rate, path in jobs:
        tmp.write('$s.Rate = %d; $s.SetOutputToWaveFile("%s", $f); $s.Speak("%s")\n' % (rate, winpath(path).replace('/', '\\'), text))
    tmp.write('$s.SetOutputToNull()\n')
    tmp.close()
    subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', tmp.name], check=True)
    os.unlink(tmp.name)


def load(path):
    w = wave.open(path, 'rb')
    assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2, path
    x = np.frombuffer(w.readframes(w.getnframes()), '<i2').astype(np.float64)
    w.close()
    return trim(x)


def huihui_rates(r0):
    return [min(10, r0 + 2 * k) for k in range(4)]


# 慧慧：每段在 4 个语速下一次性合成好候选；晓晓：按需逐档合成
cand = {}
if OFFLINE:
    jobs = []
    for i, (text, lim, er0, hr0, beep) in enumerate(SEGS):
        for rate in huihui_rates(hr0):
            p = os.path.join(GD, 'tmp_%02d_%d.wav' % (i, rate))
            jobs.append((text, rate, p))
            cand[(i, rate)] = p
    print('慧慧离线合成 %d 个候选……' % len(jobs))
    huihui(jobs)
else:
    print('edge-tts %s 联网合成 %d 段……' % (VOICE, len(SEGS)))


def say(i, text, rate):
    return load(cand[(i, rate)]) if OFFLINE else edge_say(text, rate)


def tone():
    t = np.arange(int(BEEP * RATE)) / RATE    # 500 Hz 柔和提示音，起 30 ms / 落 100 ms
    return np.sin(2 * np.pi * 500 * t) * np.minimum(1, np.minimum(t / 0.03, (BEEP - t) / 0.1)) * 9000


pcm = []
lines = ['段  时长 / 上限        语速   文字']
over = []
for i, (text, lim, er0, hr0, beep) in enumerate(SEGS):
    vlim = lim - BEEP if beep else lim         # 接提示音的段，人声要留出 0.5 秒
    rates = huihui_rates(hr0) if OFFLINE else edge_rates(er0)
    x = None
    for rate in rates:
        x = say(i, text, rate)
        if len(x) <= vlim * RATE:
            break
    if len(x) > vlim * RATE:                   # 语速最快还超：截断（会丢尾音，打印警告）
        print('  警告：段 %d「%s」%.2f 秒 > %.2f 秒，已截断' % (i, text, len(x) / RATE, vlim))
        over.append(i)
        x = x[: int(vlim * RATE)]
    x = x / max(1.0, np.abs(x).max()) * 23000  # 人声峰值 -3 dBFS
    if beep:
        x = np.concatenate([x, tone()])
    seg = np.zeros(SLOT)
    seg[: len(x)] = x
    pcm.append(seg.astype('<i2'))
    w = wave.open(os.path.join(GD, '%02d.wav' % i), 'wb')
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE); w.writeframes(x.astype('<i2').tobytes()); w.close()
    rs = ('%+d' % rate) if OFFLINE else ('%+d%%' % rate)
    lines.append('%2d  %.2f s / %.2f s  %-5s  %s' % (i, len(x) / RATE, lim, rs, text + ('（+ 0.5 秒提示音）' if beep else '')))
    print(lines[-1])
for f in os.listdir(GD):
    if f.startswith('tmp_'):
        os.unlink(os.path.join(GD, f))
data = np.concatenate(pcm).tobytes()
junk = 512 - 12 - 24 - 8 - 8
hdr = b'RIFF' + struct.pack('<I', 4 + 24 + 8 + junk + 8 + len(data)) + b'WAVE'
hdr += b'fmt ' + struct.pack('<IHHIIHH', 16, 1, 1, RATE, RATE * 2, 2, 16)
hdr += b'JUNK' + struct.pack('<I', junk) + b'\0' * junk
hdr += b'data' + struct.pack('<I', len(data))
assert len(hdr) == 512
os.makedirs(os.path.dirname(OUT) or '.', exist_ok=True)
open(OUT, 'wb').write(hdr + data)
lines.append('音色：%s；超时截断的段：%s' % ('慧慧（离线）' if OFFLINE else VOICE, over or '无'))
open(os.path.join(GD, 'list.txt'), 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print('输出：%s，%d 段 × 1024 扇区，%d 字节（每段试听 out/guide/NN.wav）；超时截断：%s'
      % (OUT, len(SEGS), 512 + len(data), over or '无'))
