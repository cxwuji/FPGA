# 把任意 WAV 转成第11课 wav_stream_player 能直接播放的 MUSIC.WAV：
#   48kHz、16bit 有符号小端、单声道；WAV 头用 JUNK 块补到 512 字节，PCM 正好从第 2 个扇区开始
#   （FPGA 从 MUSIC.WAV 的第 2 个扇区开始按连续扇区读，不解析 WAV 头）
# 用法（仓库根目录）：python -I tools/make_music_wav.py 输入.wav [输出.wav] [最长秒数]
#   默认输出 MUSIC.WAV。输入支持 8/16/24/32bit PCM、任意声道数、任意采样率（线性插值重采样）。
import array
import struct
import sys
import wave

try:
    sys.stdout.reconfigure(encoding='utf-8')   # Git Bash 是 UTF-8 终端，Windows 下 Python 默认按 GBK 输出会乱码
except AttributeError:
    pass

src = sys.argv[1]
dst = sys.argv[2] if len(sys.argv) > 2 else 'MUSIC.WAV'
max_sec = float(sys.argv[3]) if len(sys.argv) > 3 else 600.0
OUT_RATE = 48000

w = wave.open(src, 'rb')
ch, sw, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
n = min(n, int(max_sec * rate))
raw = w.readframes(n)
w.close()
print('输入：%d 声道 %dbit %dHz，%.1f 秒' % (ch, sw * 8, rate, n / rate))

# 解码成整数并混成单声道（-32768..32767）
mono = array.array('i', [0]) * n
step = ch * sw
for i in range(n):
    acc = 0
    base = i * step
    for c in range(ch):
        o = base + c * sw
        if sw == 1:
            v = (raw[o] - 128) << 8
        elif sw == 2:
            v = struct.unpack_from('<h', raw, o)[0]
        elif sw == 3:
            v = int.from_bytes(raw[o:o + 3], 'little', signed=True) >> 8
        else:
            v = struct.unpack_from('<i', raw, o)[0] >> 16
        acc += v
    mono[i] = acc // ch

# 线性插值重采样到 48kHz
m = int(n * OUT_RATE / rate)
out = array.array('h', [0]) * m
ratio = rate / OUT_RATE
for j in range(m):
    x = j * ratio
    k = int(x)
    f = x - k
    a = mono[k]
    b = mono[k + 1] if k + 1 < n else a
    v = int(a + (b - a) * f)
    out[j] = max(-32768, min(32767, v))
if sys.byteorder != 'little':
    out.byteswap()
pcm = out.tobytes()

# RIFF(12) + fmt(24) + JUNK(8+468) + data 头(8) = 512 字节
junk = 512 - 12 - 24 - 8 - 8
hdr = b'RIFF' + struct.pack('<I', 4 + 24 + 8 + junk + 8 + len(pcm)) + b'WAVE'
hdr += b'fmt ' + struct.pack('<IHHIIHH', 16, 1, 1, OUT_RATE, OUT_RATE * 2, 2, 16)
hdr += b'JUNK' + struct.pack('<I', junk) + b'\0' * junk
hdr += b'data' + struct.pack('<I', len(pcm))
assert len(hdr) == 512
open(dst, 'wb').write(hdr + pcm)
print('输出：%s，48kHz 16bit 单声道，%.1f 秒，%.1f MB' % (dst, m / OUT_RATE, (512 + len(pcm)) / 1e6))
