# TF 卡自查：FPGA 扫描器只读根目录第 1 个扇区（前 16 个目录项），GUIDE.WAV 按"起点 + 段号 × 1024 扇区"直接读，必须连续存放
#   用法（Git Bash，卡插在电脑上）：python -I tools/check_card.py /dev/sdb1   （设备名用 ls /dev/sd* 看，FAT32 分区那个）
#   检查：PIC1~6 / MUSIC / GUIDE / SAVE 是否都在前 16 项、各文件簇链是否连续、BMP 头、SAVE.BIN 大小
import struct
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8')
except AttributeError:
    pass

DEV = sys.argv[1] if len(sys.argv) > 1 else '/dev/sdb1'


def rd(sec, cnt=1):
    r = subprocess.run(['dd', 'if=' + DEV, 'bs=512', 'skip=%d' % sec, 'count=%d' % cnt, 'status=none'],
                       capture_output=True)
    return r.stdout


bs = rd(0)
if bs[82:87] != b'FAT32':
    sys.exit('%s 不是 FAT32 分区（或者设备名不对）' % DEV)
spc, rsv, nf = bs[13], struct.unpack('<H', bs[14:16])[0], bs[16]
fsz, rc = struct.unpack('<I', bs[36:40])[0], struct.unpack('<I', bs[44:48])[0]
data = rsv + nf * fsz
fat = rd(rsv, fsz)


def nxt(c):
    return struct.unpack('<I', fat[c * 4:c * 4 + 4])[0] & 0x0FFFFFFF


root = rd(data + (rc - 2) * spc, spc)
need = ['PIC1    BMP', 'PIC2    BMP', 'PIC3    BMP', 'PIC4    BMP', 'PIC5    BMP', 'PIC6    BMP',
        'MUSIC   WAV', 'GUIDE   WAV', 'SAVE    BIN']
found = {}
bad = 0
for i in range(len(root) // 32):
    e = root[i * 32:i * 32 + 32]
    if e[0] == 0:
        break
    if e[0] == 0xE5 or e[11] == 0x0F:
        continue
    name = e[0:11].decode('latin1').upper()
    if name in need:
        found[name] = (i, struct.unpack('<H', e[20:22])[0] << 16 | struct.unpack('<H', e[26:28])[0],
                       struct.unpack('<I', e[28:32])[0])
for n in need:
    if n not in found:
        print('缺少 %s' % n.replace(' ', '').replace('BMP', '.BMP').replace('WAV', '.WAV').replace('BIN', '.BIN'))
        bad += 1
        continue
    i, cl, sz = found[n]
    msg = '%-12s 第 %2d 项  %9d 字节' % (n, i, sz)
    if i >= 16:
        msg += '  ✗ 不在根目录第 1 扇区（FPGA 找不到）'
        bad += 1
    c, k, br = cl, 0, 0
    while 2 <= c < 0x0FFFFFF8 and k < 1 << 20:
        x = nxt(c)
        if 2 <= x < 0x0FFFFFF8 and x != c + 1:
            br += 1
        c, k = x, k + 1
    if br:
        msg += '  ✗ 不连续（%d 处断开）' % br
        if n.startswith('GUIDE'):
            bad += 1                            # GUIDE 按扇区直接读，断开就会播错段
    if n.endswith('BMP'):
        h = rd(data + (cl - 2) * spc)
        w, hh = struct.unpack('<ii', h[18:26])
        bpp = struct.unpack('<H', h[28:30])[0]
        msg += '  %dx%d %d 位' % (w, abs(hh), bpp)
        if h[0:2] != b'BM' or bpp != 24:
            msg += '  ✗ 不是 24 位 BMP'
            bad += 1
    if n.startswith('SAVE') and sz < 1536:
        msg += '  ✗ 小于 1536 字节（位置条存不进卡，用 out/test_card_r10/SAVE.BIN）'
        bad += 1
    print(msg)
print('结论：' + ('全部正常' if bad == 0 else '%d 处问题 -> 格式化 FAT32 后按 PIC1~6 -> MUSIC -> GUIDE -> SAVE 顺序拷入' % bad))
