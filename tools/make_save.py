# R8-4：生成 / 查看 TF 卡根目录的 SAVE.BIN（掉电保存存档，格式见 doc/R8-4_方案.md 第 3 节）
# FPGA 只覆盖这个文件的前几个扇区、不改 FAT 和目录，所以卡上必须先有这个文件。
# R9：文件改成 1536 字节 = 3 个扇区：第 1 扇区设置 + 急救记录（第 25 字节 bit0 = 1 表示后面存着位置条），
#   第 2、3 扇区 = 急救位置条点阵（512x16，同 tools/uart_subtitle.py --loc）。电脑串口改位置条后 FPGA 自己写回这两个扇区。
# 用法（仓库根目录）：
#   python -I tools/make_save.py [输出.bin] [选项...]        生成存档，不带选项 = 和上电默认完全一样
#   python -I tools/make_save.py --show SAVE.BIN             查看存档内容（含校验）
# 选项（都可省略，省略 = 上电默认）：
#   bri=1~4      亮度档（4 最亮，默认 4）          con=1~4   对比度档（默认 2）
#   sat=0~3      色彩 黑白 / 淡 / 标准 / 鲜艳（默认 2）
#   scol=0~7     字幕颜色（默认 0 白）             int=0~5   轮播间隔 1/3/5/8/10/15 秒（默认 1 = 3 秒）
#   stat=0/1     状态栏（默认 0）  sub=0/1 字幕（默认 0）  auto=0/1 自动轮播（默认 0）
#   mirror=0/1   镜像（默认 0）    flip=0/1 翻转（默认 0）
#   viz=0/1/2/4  可视化 关 / 波形 / 频谱 / 音量表（默认 0；R10 起开机不恢复可视化，写什么都是关）
#   fx=0~13      转场效果（默认 0）  speed=1~8 转场速度（默认 3）  vol=0~10 音量（默认 6）
#   pic=0~4      开机显示第几张轮播图（按 bank，默认 0）
#   loc=文字     R9 急救位置条（不写 = 用 FPGA 片内默认「当前位置：XX商场二楼手机店  AED：一楼大厅服务中心」（R11））
# 例：python -I tools/make_save.py out/test_card_r84a/SAVE.BIN bri=2 con=3 sat=3 scol=5 int=0 stat=1 sub=1 mirror=1 viz=2 fx=5 speed=6 vol=4 pic=2
import importlib.util
import os
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8')   # Git Bash 是 UTF-8 终端，Windows 下 Python 默认按 GBK 输出会乱码
except AttributeError:
    pass

BRI = {4: 255, 3: 192, 2: 128, 1: 64}          # 亮度档 -> 寄存器值（ui_key_router 循环 255 -> 192 -> 128 -> 64）
CON = {1: 64, 2: 128, 3: 192, 4: 255}          # 对比度档
DEFAULT = dict(bri=4, con=2, sat=2, scol=0, int=1, stat=0, sub=0, auto=0, mirror=0, flip=0,
               viz=0, fx=0, speed=3, vol=6, pic=0)
RANGE = dict(bri=BRI.keys(), con=CON.keys(), sat=range(4), scol=range(8), int=range(6),
             stat=range(2), sub=range(2), auto=range(2), mirror=range(2), flip=range(2),
             viz=(0, 1, 2, 4), fx=range(14), speed=range(1, 9), vol=range(11), pic=range(5))


def build(v, loc=None):
    b = bytearray(1536)
    b[0:4] = b'CPRS'
    b[4] = 1
    b[5] = BRI[v['bri']]
    b[6] = CON[v['con']]
    b[7] = v['sat']
    b[8] = v['scol']
    b[9] = v['int']
    b[10] = v['stat'] | v['sub'] << 1 | v['auto'] << 2 | v['mirror'] << 3 | v['flip'] << 4
    b[11] = v['viz']
    b[12] = v['fx']
    b[13] = v['speed']
    b[14] = v['vol']
    b[15] = v['pic']
    # 16~23 上次急救记录、24 急救次数：新存档全 0（R8-4b 由 FPGA 写）
    if loc:                                    # R9：位置条点阵进第 2、3 扇区
        spec = importlib.util.spec_from_file_location('uart_subtitle', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'uart_subtitle.py'))
        us = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(us)
        _, bmp = us.render(loc, False, 404)
        b[512:1536] = bytes(bmp)
        b[25] = 1
    x = 0
    for c in b[:31]:
        x ^= c
    b[31] = x
    return bytes(b)


def show(path):
    b = open(path, 'rb').read()
    x = 0
    for c in b[:32]:
        x ^= c
    ok = len(b) >= 512 and b[0:4] == b'CPRS' and b[4] == 1 and x == 0
    print('%s：%d 字节，%s' % (path, len(b), '有效' if ok else '无效（FPGA 会用上电默认值）'))
    if len(b) < 32:
        return
    inv = lambda d, val: next((k for k, w in d.items() if w == val), '?(%d)' % val)
    print('  亮度档 %s  对比度档 %s  色彩 %d  字幕颜色 %d  间隔 %d' % (inv(BRI, b[5]), inv(CON, b[6]), b[7], b[8], b[9]))
    f = b[10]
    print('  状态栏 %d  字幕 %d  轮播 %d  镜像 %d  翻转 %d' % (f & 1, f >> 1 & 1, f >> 2 & 1, f >> 3 & 1, f >> 4 & 1))
    print('  可视化 %d  转场效果 %d  速度 %d  音量 %d  开机图 bank%d' % (b[11], b[12], b[13], b[14], b[15]))
    print('  上次急救：用时 %02x:%02x  按压 %02x%02x 次  首次 AED %02x:%02x  累计 %d 次' %
          (b[17], b[16], b[19], b[18], b[21], b[20], b[24]))
    print('  急救位置条：%s' % ('存在文件第 2、3 扇区' if b[25] & 1 else
          ('未设置（用片内默认；文件 %s 1536 字节，%s）' % ('够' if len(b) >= 1536 else '不足', '串口改了能存' if len(b) >= 1536 else '串口改了存不进卡'))))


def main(argv):
    if argv[:1] == ['--show']:
        show(argv[1] if len(argv) > 1 else 'SAVE.BIN')
        return
    out = 'SAVE.BIN'
    v = dict(DEFAULT)
    loc = None
    for a in argv:
        if '=' not in a:
            out = a
            continue
        k, val = a.split('=', 1)
        if k == 'loc':
            loc = val
            continue
        if k not in v:
            sys.exit('不认识的选项：%s（见文件头说明）' % k)
        n = int(val)
        if n not in RANGE[k]:
            sys.exit('%s=%d 超出范围 %s' % (k, n, list(RANGE[k])))
        v[k] = n
    open(out, 'wb').write(build(v, loc))
    print('已生成', out)
    show(out)


main(sys.argv[1:])
