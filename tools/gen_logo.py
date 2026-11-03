# R3 台标图层：画一个 96x40 的 4 色台标（红底圆角 + 白色爱心里一条红色心电图 + 白字 "AED"）
#   用法（仓库根目录）：python -I tools/gen_logo.py
#   输出：src/user_source/hdl_source/display/logo_rom.hex（3840 行，每行 1 个十六进制数 = 调色板号，行优先）
#         out/logo_preview.png
# 调色板（layer_compositor.v 里写死）：0 透明 / 1 红 D81E28 / 2 白 FFFFFF / 3 深红 7A0E14（描边）
import os
import sys
from PIL import Image, ImageDraw, ImageFont

try:
    sys.stdout.reconfigure(encoding='utf-8')
except AttributeError:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HDL = os.path.join(ROOT, 'src', 'user_source', 'hdl_source')
FONT = os.environ.get('LOGO_FONT', 'C:/Windows/Fonts/arialbd.ttf')
W, H = 96, 40
PAL = [(0, 0, 0), (0xd8, 0x1e, 0x28), (0xff, 0xff, 0xff), (0x7a, 0x0e, 0x14)]

S = 4                                   # 先 4 倍画再缩小取最近色，边缘更圆
im = Image.new('P', (W * S, H * S), 0)
im.putpalette([c for rgb in PAL for c in rgb] + [0] * (256 - 4) * 3)
d = ImageDraw.Draw(im)
d.rounded_rectangle([0, 0, W * S - 1, H * S - 1], radius=8 * S, fill=3)
d.rounded_rectangle([2 * S, 2 * S, W * S - 1 - 2 * S, H * S - 1 - 2 * S], radius=6 * S, fill=1)
# 爱心：两个圆 + 一个三角
cx, cy, r = 20 * S, 17 * S, 7 * S
d.ellipse([cx - 2 * r + S, cy - r, cx + S, cy + r], fill=2)
d.ellipse([cx - S, cy - r, cx + 2 * r - S, cy + r], fill=2)
d.polygon([(cx - 2 * r + int(1.6 * S), cy + int(0.35 * r)), (cx + 2 * r - int(1.6 * S), cy + int(0.35 * r)), (cx, cy + 2 * r + 2 * S)], fill=2)
# 心电图
pts = [(6, 20), (13, 20), (16, 13), (19, 27), (22, 9), (25, 20), (34, 20)]
d.line([(x * S, y * S) for x, y in pts], fill=1, width=int(1.6 * S), joint='curve')
font = ImageFont.truetype(FONT, 22 * S)
d.text((39 * S, 6 * S), 'AED', font=font, fill=2)
im = im.resize((W, H), Image.NEAREST)

px = im.load()
with open(os.path.join(HDL, 'display', 'logo_rom.hex'), 'w', newline='\n') as f:
    for y in range(H):
        for x in range(W):
            f.write('%x\n' % px[x, y])
prev = im.convert('RGB').resize((W * 4, H * 4), Image.NEAREST)
os.makedirs(os.path.join(ROOT, 'out'), exist_ok=True)
prev.save(os.path.join(ROOT, 'out', 'logo_preview.png'))
print('台标 %dx%d 已生成' % (W, H))
