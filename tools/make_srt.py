# 视频成片时间线（doc/拍摄懒人手册.md 第 5 节）-> 两份字幕 + 时间线清单，剪映「文本 → 本地字幕 → 导入」直接用
#   用法（仓库根目录）：python -I tools/make_srt.py    （先跑 tools/make_narration.py，旁白时长从 mp3 读）
#   输出 out/拍摄包/字幕/功能标签.srt（画面上方的功能名）、旁白字幕.srt（画面下方，和配音逐句对齐）、out/拍摄包/剪辑时间线.txt
import os
import re

import sys

import miniaudio

try:
    sys.stdout.reconfigure(encoding='utf-8')
except AttributeError:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, 'out', '拍摄包')

# (开始秒, 结束秒, 镜头, 画面来源, 功能标签)
CLIPS = [
    (0.0, 1.5, 'C01', '素材 00_比赛封面.png', ''),
    (1.5, 8.5, 'C02', '素材 01_作品海报（A / B 二选一）', ''),
    (8.5, 14.5, 'C03', 'Take 4 第 1 步（或 Take 5 第 4 步）：实物全景', '实物：HX4S20C 开发板（EG4S20）+ HDMI 显示器'),
    (14.5, 19.5, 'C04', 'Take 1 第 2~3 步：插卡 → 上电 → 出图（等待段 2 倍速）', '基础功能1：上电自动运行 · TF 卡 FAT32 读取 BMP'),
    (19.5, 23.5, 'C05', 'Take 1 第 4 步：状态栏出现后的稳定画面', '基础功能2：HDMI 640×480@60Hz 稳定输出'),
    (23.5, 28.5, 'C06', 'Take 1 第 5~7 步：K2 切换（加板子特写画中画）', '基础功能3：按键切换 下一张 / 上一张'),
    (28.5, 32.5, 'C07', 'Take 1 第 8 步：K1 开轮播、自动换图', '基础功能4：自动轮播（间隔 1~15 秒可调）'),
    (32.5, 37.5, 'C08', 'Take 1 第 9 步：SW4 拨上、音乐响起', '基础功能5：48 kHz / 16 bit 音频经 HDMI 输出'),
    (37.5, 44.5, 'C09', 'Take 2 第 4~9 步：调速度 / 模式（快进）+ 15 次预览（3 倍速）', '扩展功能1：16 种转场特效（含 2 种无黑场推移）· 8 档速度'),
    (44.5, 49.5, 'C10', 'Take 2 第 11~12 步：频谱', '扩展功能2：512 点 FFT 音乐频谱'),
    (49.5, 59.5, 'C11', 'Take 2 第 13~20 步：串口字幕（第 14 步加电脑录屏画中画）+ 台标弹跳 / 半透明', '扩展功能3：多图层叠加 · 电脑串口下发字幕'),
    (59.5, 70.5, 'C12', 'Take 2 第 22~27 步：PIC2 / PIC4 状态栏第四行 + 横向放大 / 镜像', '扩展功能4：自适应缩放（1280×960 缩小 / 480×360 放大）'),
    (70.5, 76.5, 'C13', 'Take 2 第 29~33 步：亮度 / 对比度 / 色彩', '扩展功能5：亮度 / 对比度 / 色彩实时调节'),
    (76.5, 79.5, 'C14', 'Take 2 第 35~37 步：缩略图', '扩展功能6：2×2 缩略图选图'),
    (79.5, 86.5, 'C15', 'Take 3 第 2~3 步：黄条「待设置」→ 串口发送 → 真实位置（加电脑录屏画中画）', '扩展功能7：AED 位置条 · 串口写入并存 TF 卡'),
    (86.5, 91.5, 'C16', 'Take 3 第 5~6 步：断电 → 上电（3 倍速）→ 数值没变、黄条没丢', '扩展功能8：设置掉电保存（断电重启后不变）'),
    (91.5, 97.5, 'C17', 'Take 4 第 1 步：广告轮播 + 字幕 + 音乐', '主题演示：商场广告屏的日常'),
    (97.5, 105.5, 'C18a', 'Take 4 第 2 步前半：按 K4 →「这里有人晕倒了」…倒数（原声）', '有人晕倒 → 按急救键 → ① 判断呼救（语音 · 底栏 · 要点同步）'),
    (105.5, 113.5, 'C18b', 'Take 4 第 2 步后半（跳切）：「没有呼吸…」「下面进行CPR…」正中黄框', 'AED 位置看黄条；讲完停住，等施救者准备好按 K3'),
    (113.5, 118.5, 'C19', 'Take 4 第 3 步开头：按 K3 → 要领 →「开始按压」（跳切掉 5 秒停顿）', '② 心肺复苏：先讲按压要领'),
    (118.5, 124.5, 'C20', 'Take 4 第 3 步：报数「一、二、三…」', '硬件 110 次/分节拍 · 逐拍语音报数 · LED 同步闪'),
    (124.5, 133.0, 'C21', 'Take 4 第 3 步：第一次人工呼吸 10 秒', '30:2：每 30 次按压引导 2 次人工呼吸'),
    (133.0, 136.0, 'C22', 'Take 4 第 3 步末尾：正中黄框「到了两分钟，建议换人」', '急救满 2 分钟：提示换人（不打断按压）'),
    (136.0, 141.5, 'C23', 'Take 4 第 4 步：按 K3 →「AED到了…」「听AED语音…」', '③ AED 到达：停止打拍，让位给 AED 语音'),
    (141.5, 145.0, 'C24', 'Take 4 第 5 步：按 K3 →「继续按压，跟我数」', 'AED 提示继续：回到按压，从「一」重新数'),
    (145.0, 149.5, 'C25a', 'Take 4 第 6 步：K4 长按 → 交接页', '交接页：晕倒时长 · 按压次数（给 120 参考）'),
    (149.5, 154.0, 'C25b', 'Take 4 第 7 步：K4 长按 → 回到广告', '一键恢复广告'),
    (154.0, 164.0, 'C26', '回放剪辑：C20 报数 3 秒 + C12 缩放 3 秒 + C10 频谱 4 秒', '亮点：逐拍语音急救指导 · 自适应缩放 · 定点 FFT'),
    (164.0, 170.5, 'C27', '素材 05_资源与可靠性.png', ''),
    (170.5, 176.5, 'C28', 'Take 5 第 2~3 步：拔卡 → 红条提示 → 插回 →「TF 卡已恢复」', '可靠性：TF 卡拔出 → 提示 → 插回自动恢复'),
    (176.5, 178.5, 'C29', '素材 01_作品海报（和开头同一张）', ''),
]
# (配音文件, 开始秒)：跟着所在镜头的开头
NARR = [('N01_开场', 1.5), ('N02_基础功能', 14.5), ('N03_E1转场', 37.5), ('N04_E2频谱', 44.5), ('N05_E3图层字幕', 49.5), ('N06_E4缩放', 59.5), ('N07_E5画质', 70.5), ('N08_E6缩略图', 76.5), ('N09_E7位置条', 79.5), ('N10_E8掉电保存', 86.5), ('N11_主题日常', 91.5), ('N12_主题交接', 145.0), ('N13_结尾亮点', 154.0), ('N14_结尾资源', 164.4), ('N15_结尾可靠性', 170.6)]


def ts(t):
    ms = int(round(t * 1000))
    return '%02d:%02d:%02d,%03d' % (ms // 3600000, ms // 60000 % 60, ms // 1000 % 60, ms % 1000)


def srt(items, path):
    with open(path, 'w', encoding='utf-8-sig', newline='\r\n') as f:
        for i, (a, b, t) in enumerate(items, 1):
            f.write('%d\n%s --> %s\n%s\n\n' % (i, ts(a), ts(b), t))


def width(t):
    return sum(1 if ord(c) >= 0x80 else 0.5 for c in t)


def cut(p, maxw):
    """太长的句子从中间附近切开，不切断英文 / 数字（如 FPGA、640×480）"""
    if width(p) <= maxw:
        return [p]
    best = None
    for i in range(1, len(p)):
        a, b = p[i - 1], p[i]
        if p[:i].count('《') > p[:i].count('》'):     # 书名号里不切
            continue
        if (a.isascii() and a.isalnum()) and (b.isascii() and b.isalnum() or b in '×.%'):
            continue
        if a in '×.—《' or b in '—》' or b == ' ' and a.isascii():
            continue
        score = abs(width(p[:i]) - width(p) / 2)
        if best is None or score < best[0]:
            best = (score, i)
    i = best[1]
    return cut(p[:i].strip(), maxw) + cut(p[i:].strip(), maxw)


def chunks(text, maxw=18):
    """按标点切成短句，每句宽度 <= maxw 个汉字（英文 / 数字算半个）"""
    parts = [p.strip() for p in re.split(r'(?<=[，。；：、！？])', text) if p.strip()]
    out = []
    for p in parts:
        for c in cut(p, maxw):
            if out and width(out[-1]) + width(c) <= 13:   # 太短的并到上一句
                out[-1] += c
            else:
                out.append(c)
    k = 0
    while k < len(out):                               # 只剩一两个字的（如「平时，」）并到后一句
        if k + 1 < len(out) and (width(out[k]) <= 3 or out[k].endswith('：') and width(out[k]) + width(out[k + 1]) <= 18):
            out[k + 1] = out[k] + out[k + 1]
            del out[k]
        else:
            k += 1
    return [c.rstrip('，。；、') for c in out]


# 配音清单里的字幕文字（make_narration.py 写的）
show = {}
for ln in open(os.path.join(PKG, '配音', '配音清单.txt'), encoding='utf-8').read().splitlines()[1:-1]:
    name, rest = ln.split(None, 1)
    show[name] = rest.split('秒', 1)[1].strip()
labels = [(a, b, t) for a, b, _, _, t in CLIPS if t]
sub = []
for name, t0 in NARR:
    dur = miniaudio.decode(open(os.path.join(PKG, '配音', name + '.mp3'), 'rb').read()).duration   # decode_file 不认中文路径
    cs = chunks(show[name])
    n = sum(width(c) for c in cs)
    t = t0
    for c in cs:
        d = dur * width(c) / n
        sub.append((t, t + d - 0.05, c))
        t += d
os.makedirs(os.path.join(PKG, '字幕'), exist_ok=True)
srt(labels, os.path.join(PKG, '字幕', '功能标签.srt'))
srt(sub, os.path.join(PKG, '字幕', '旁白字幕.srt'))
lines = ['成片总长 %d:%04.1f' % (CLIPS[-1][1] // 60, CLIPS[-1][1] % 60), '',
         '开始    结束    镜头  画面（从哪条素材剪）                                  功能标签（上方字幕）']
for a, b, c, src, t in CLIPS:
    lines.append('%5.1f  %5.1f  %-5s %s    |  %s' % (a, b, c, src, t or '—'))
lines += ['', '配音放置（文件 @ 开始秒）：'] + ['  %s @ %.1f 秒' % (n, t) for n, t in NARR]
open(os.path.join(PKG, '剪辑时间线.txt'), 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print('\n'.join(lines))
print('功能标签 %d 条，旁白字幕 %d 条' % (len(labels), len(sub)))
