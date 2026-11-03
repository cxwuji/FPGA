# R8-1c 电脑串口换字幕：把文字画成 512x16 黑白点阵，经板载 CH340（Type-C）发给板子（115200 8N1），板子回 OK / ER。
#   用法（仓库根目录）：
#     python -I tools/uart_subtitle.py --text "今日店庆 全场八折" --color 黄 --motion 滚动 --speed 3
#     python -I tools/uart_subtitle.py --text "本层 AED 在服务台旁" --motion 静止 --center --only-current
#     python -I tools/uart_subtitle.py --restore              恢复片内默认字幕
#     python -I tools/uart_subtitle.py --text "..." --dry-run  不发送，只生成预览图 out/uart_subtitle_preview.png
#   给串口助手用（只生成文件不发送）：--bin out/sub.bin（发送文件）或 --hex out/sub.txt（HEX 发送粘贴）；
#     恢复默认字幕直接 HEX 发送：A5 5A 02 00 00 02
#   R9 急救位置条（安装时设一次，板子收到后写进 TF 卡 SAVE.BIN，断电不丢）：
#     python -I tools/uart_subtitle.py --loc "当前位置：XX商场二楼手机店  AED：一楼大厅服务中心"
#     python -I tools/uart_subtitle.py --loc "..." --loc-hex src/user_source/hdl_source/display/loc_default.hex   生成片内默认（不发送）
#     位置条只显示前 404 点（约 25 个汉字），靠左画；CMD 03，帧格式同 CMD 01（P1 P2 = 0）
#   仿真用的测试帧（sim/uart_frame_u7.hex）：
#     python -I tools/uart_subtitle.py --text "今日店庆 全场八折 AED 在一楼服务台" --color 黄 --speed 3 --dry-run --dump sim/uart_frame_u7.hex
#   串口默认自动找 CH340（USB VID 1A86），找不到时用 --port COM5 指定。
# 帧格式（和 io/uart_subtitle.v 一致）：A5 5A CMD P1 P2 [点阵 1024 字节] CS
#   CMD 01 替换：P1 = {速度-1[1:0] << 4 | 全部图 << 3 | 运动 << 1 | 显示}，P2 = 颜色；CMD 02 恢复默认（P1 P2 = 0，没有点阵）
#   点阵：行 0~15 × 每行 64 字节，每字节 8 点最高位在左；CS = CMD + P1 + P2 + 点阵各字节 的低 8 位
# 字形和片内字库一样用宋体 16 点阵：ASCII 半宽 8 点，其他字 16 点，一共最多 512 点（约 32 个汉字）。
import argparse
import os
import sys
import time

from PIL import Image, ImageDraw, ImageFont

try:
    sys.stdout.reconfigure(encoding='utf-8')
except AttributeError:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONTS = [os.environ.get('CN_FONT', ''), 'C:/Windows/Fonts/simsun.ttc', 'C:/Windows/Fonts/simsun.ttc']
COLORS = {'白': 0, '黄': 1, '红': 2, '绿': 3, '青': 4, '橙': 5, '粉': 6, '蓝': 7,
          'white': 0, 'yellow': 1, 'red': 2, 'green': 3, 'cyan': 4, 'orange': 5, 'pink': 6, 'blue': 7}
MOTIONS = {'静止': 0, '弹跳': 1, '滚动': 2, 'static': 0, 'bounce': 1, 'scroll': 2}
W, H = 512, 16


def render(text, center, limit=None):
    path = next((p for p in FONTS if p and os.path.exists(p)), None)
    if not path:
        sys.exit('找不到宋体 simsun.ttc，用环境变量 CN_FONT 指定字体文件')
    font = ImageFont.truetype(path, 16)
    widths = [8 if ord(c) < 0x80 else 16 for c in text]
    total = sum(widths)
    if total > (limit or W):
        sys.exit('文字太长：%d 点，最多 %d 点' % (total, limit or W))
    im = Image.new('1', (W, H), 0)
    d = ImageDraw.Draw(im)
    d.fontmode = '1'
    x = (W - total) // 2 if center else 0
    for c, wd in zip(text, widths):
        d.text((x, 0), c, font=font, fill=1)
        x += wd
    bmp = []
    for r in range(H):
        for cb in range(W // 8):
            b = 0
            for k in range(8):
                if im.getpixel((cb * 8 + k, r)):
                    b |= 0x80 >> k
            bmp.append(b)
    return im, bmp


def frame(cmd, p1, p2, data):
    cs = (cmd + p1 + p2 + sum(data)) & 0xff
    return bytes([0xa5, 0x5a, cmd, p1, p2] + data + [cs])


def find_port():
    from serial.tools import list_ports
    ports = list(list_ports.comports())
    ch340 = [p for p in ports if p.vid == 0x1a86]
    if ch340:
        return ch340[0].device
    names = ', '.join('%s（%s）' % (p.device, p.description) for p in ports) or '无'
    sys.exit('没找到 CH340 串口。电脑上现有串口：%s。用 --port COMx 指定，或检查 Type-C 线 / 驱动' % names)


def main():
    ap = argparse.ArgumentParser(description='电脑串口换字幕（R8-1c）')
    ap.add_argument('--text', help='字幕文字（≤ 512 点，约 32 个汉字）')
    ap.add_argument('--color', default='白', help='白 黄 红 绿 青 橙 粉 蓝')
    ap.add_argument('--motion', default='滚动', help='静止 / 弹跳 / 滚动')
    ap.add_argument('--speed', type=int, default=2, choices=[1, 2, 3, 4], help='滚动每帧移几点')
    ap.add_argument('--hide', action='store_true', help='字幕层隐藏（点阵照样换）')
    ap.add_argument('--only-current', action='store_true', help='只替换板子当前显示的这张图（默认全部图）')
    ap.add_argument('--center', action='store_true', default=True, help='文字居中（R11 起默认就是居中）')
    ap.add_argument('--left', dest='center', action='store_false', help='文字靠左（滚动时可以用）')
    ap.add_argument('--restore', action='store_true', help='恢复片内默认字幕')
    ap.add_argument('--loc', help='R9：急救位置条文字（≤ 404 点，约 25 个汉字），板子收到后存进 TF 卡')
    ap.add_argument('--loc-hex', help='R9：把位置条点阵写成 $readmemh 文件（每行一个字节，1024 行），不发送')
    ap.add_argument('--port', help='串口号，如 COM5（默认自动找 CH340）')
    ap.add_argument('--dry-run', action='store_true', help='不发送，只生成预览图')
    ap.add_argument('--bin', help='把整帧写成二进制文件（串口助手"发送文件"用），不发送')
    ap.add_argument('--hex', help='把整帧写成空格分隔的十六进制文本（串口助手"HEX 发送"粘贴用），不发送')
    ap.add_argument('--dump', help='把整帧按每行一个十六进制字节写进文件（仿真 sim/tb_uart_sub.v 的 U7 用）')
    a = ap.parse_args()

    if a.loc:
        im, bmp = render(a.loc, False, 404)
        pkt = frame(0x03, 0, 0, bmp)
        prev = os.path.join(ROOT, 'out', 'uart_loc_preview.png')
        os.makedirs(os.path.dirname(prev), exist_ok=True)
        im.convert('L').crop((0, 0, 404, H)).resize((404 * 2, H * 2), Image.NEAREST).save(prev)
        print('位置条：%s  预览图 %s' % (a.loc, prev))
        if a.loc_hex:
            with open(a.loc_hex, 'w', newline='\n') as f:
                f.write(''.join('%02x\n' % b for b in bmp))
            print('点阵 1024 字节已写进 %s（不发送）' % a.loc_hex)
            return
    elif a.restore:
        pkt = frame(0x02, 0, 0, [])
        print('恢复片内默认字幕')
    else:
        if not a.text:
            ap.error('要么 --text，要么 --restore')
        if a.color not in COLORS:
            ap.error('颜色只能是：白 黄 红 绿 青 橙 粉 蓝')
        if a.motion not in MOTIONS:
            ap.error('运动只能是：静止 / 弹跳 / 滚动')
        im, bmp = render(a.text, a.center)
        p1 = ((a.speed - 1) << 4) | ((0 if a.only_current else 1) << 3) | (MOTIONS[a.motion] << 1) | (0 if a.hide else 1)
        pkt = frame(0x01, p1, COLORS[a.color], bmp)
        prev = os.path.join(ROOT, 'out', 'uart_subtitle_preview.png')
        os.makedirs(os.path.dirname(prev), exist_ok=True)
        im.convert('L').resize((W * 2, H * 2), Image.NEAREST).save(prev)
        print('字幕：%s（%s / %s / 速度 %d / %s）预览图 %s' % (a.text, a.color, a.motion, a.speed,
              '只换当前图' if a.only_current else '全部图', prev))
    if a.dump:
        with open(a.dump, 'w', newline='\n') as f:
            f.write(''.join('%02x\n' % b for b in pkt))
        print('整帧已写进 %s' % a.dump)
    if a.bin:
        with open(a.bin, 'wb') as f:
            f.write(pkt)
        print('整帧 %d 字节已写进 %s（串口助手：发送文件）' % (len(pkt), a.bin))
    if a.hex:
        with open(a.hex, 'w', newline='\n') as f:
            f.write(' '.join('%02X' % b for b in pkt))
        print('整帧 %d 字节的十六进制已写进 %s（串口助手：HEX 发送，整段粘贴）' % (len(pkt), a.hex))
    if a.dry_run or a.bin or a.hex:
        print('dry-run：帧长 %d 字节，未发送' % len(pkt))
        return

    import serial
    port = a.port or find_port()
    with serial.Serial(port, 115200, timeout=2) as ser:
        ser.reset_input_buffer()
        t0 = time.time()
        ser.write(pkt)
        ser.flush()
        rep = ser.read_until(b'\n', 4)
    dt = (time.time() - t0) * 1000
    if rep.startswith(b'OK'):
        print('%s：板子回 OK（%.0f ms）' % (port, dt))
    elif rep.startswith(b'ER'):
        sys.exit('%s：板子回 ER（校验错或传输中断），请重发' % port)
    else:
        sys.exit('%s：2 秒内没收到回复（%r）。检查：bit 是否已下载、Type-C 线是否插在板子串口口上' % (port, rep))


if __name__ == '__main__':
    main()
