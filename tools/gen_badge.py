# R9 民法典 184 条角标图层（和台标同原理：片内 ROM 存 4 色点阵，FPGA 实时叠加在急救画面上，不画进 PIC6）
#   用法（仓库根目录）：python -I tools/gen_badge.py [角标截图.png]
#   输出：src/user_source/hdl_source/display/badge_rom.hex（512 x 24 = 12288 行，每行 1 位 = 有墨（字 / 天平），行优先；
#           每行按 512 点存，硬件地址 = {行[4:0], 列[8:0]}，不用乘法）。R9 省 BRAM：只存 1 位，颜色和胶囊形状由硬件算：
#           墨在列 < ICON_END 是橙色天平、否则深青字；没墨的点在胶囊里是米黄、外面透明（胶囊两端圆角用每行的缩进表 badge_tab.vh）
#         src/user_source/hdl_source/include/badge_tab.vh（脉动 8 档：每档的宽 / 高 / 左上角 / 1/倍数，emg_overlay 用）
#         out/badge_preview.png（深色底 / 急救画面上 1.0 倍和 1.15 倍）
# 用户 10-26 要求：截图外面那圈浅蓝背景不要 —— 只保留米黄胶囊本身，胶囊外一律透明（0）。
# 调色板（layer_compositor 里写死）：0 透明 / 1 米黄底 FBF2D0 / 2 深青字 0E4F5C / 3 橙色天平 E85A2A
import os
import sys
from PIL import Image, ImageDraw

try:
    sys.stdout.reconfigure(encoding='utf-8')
except AttributeError:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HDL = os.path.join(ROOT, 'src', 'user_source', 'hdl_source')
args = [a for a in sys.argv[1:] if not a.startswith('--')]
SHOT = '--shot' in sys.argv                                 # --shot：整张截图缩小（字会糊）；默认：天平用截图，文字用黑体 16 点阵重排（清晰）
SRC = args[0] if args else os.path.join(ROOT, 'out', 'cards', 'ref', 'badge_184.png')
TEXT = '《民法典》第184条：紧急救助，依法免责'
FONT = os.environ.get('BADGE_FONT', 'C:/Windows/Fonts/simsun.ttc')   # 宋体 16 点阵（和 OSD 字库同一套，16 点下最清楚）
H = 24
PAL = [(0, 0, 0), (0xFB, 0xF2, 0xD0), (0x0E, 0x4F, 0x5C), (0xE8, 0x5A, 0x2A)]

src = Image.open(SRC).convert('RGB')
bg = src.getpixel((2, 2))                                  # 截图四角 = 外面的浅蓝背景
def is_bg(p):
    return sum(abs(p[i] - bg[i]) for i in range(3)) < 24
# 胶囊外接框：每行 / 每列有一半以上不是背景色
sw, sh = src.size
rows = [y for y in range(sh) if sum(not is_bg(src.getpixel((x, y))) for x in range(0, sw, 2)) > sw // 4]
cols = [x for x in range(sw) if sum(not is_bg(src.getpixel((x, y))) for y in range(sh)) > sh // 2]
box = (cols[0], rows[0], cols[-1] + 1, rows[-1] + 1)
pill = src.crop(box)
print('截图 %dx%d，背景 %s，胶囊 %s' % (sw, sh, bg, box))

from PIL import ImageFont
font = ImageFont.truetype(FONT, 16)
tw = round(font.getlength(TEXT))
ICON = 18                                                   # 天平图标 18x18（截图左侧，取到第一个深青字之前）
W = 256 if SHOT else (12 + ICON + 6 + tw + 1 + 12 + 3) // 4 * 4
S = 4                                                       # 胶囊形状 4 倍画再缩小，边缘更圆
def px_ok(mk, x, y):
    return mk.getpixel((x, y)) >= 160
m = Image.new('L', (W * S, H * S), 0)
ImageDraw.Draw(m).rounded_rectangle((0, 0, W * S - 1, H * S - 1), radius=H * S // 2, fill=255)
mask = m.resize((W, H), Image.LANCZOS)
sm = pill.resize((W, H), Image.LANCZOS)
idx = Image.new('P', (W, H))
idx.putpalette([c for p in PAL for c in p] + [0] * 756)
for y in range(H):
    for x in range(W):
        if mask.getpixel((x, y)) < 160:                     # 胶囊外（含圆角外）= 透明
            k = 0
        else:
            p = sm.getpixel((x, y))
            k = min((1, 2, 3), key=lambda i: sum((p[j] - PAL[i][j]) ** 2 for j in range(3)))
        idx.putpixel((x, y), k)
if not SHOT:
    # 底色全米黄，左边贴截图里的天平（只取橙色像素），文字用黑体 16 点阵不抗锯齿直接画（和 OSD 一样清楚）
    for y in range(H):
        for x in range(W):
            if px_ok(mask, x, y): idx.putpixel((x, y), 1)
    org = lambda q: q[0] > 190 and q[1] < 170 and q[2] < 140      # 截图里天平的橙色
    pts = [(x, y) for y in range(pill.height) for x in range(pill.height * 2) if org(pill.getpixel((x, y)))]
    ib = (min(p[0] for p in pts), min(p[1] for p in pts), max(p[0] for p in pts) + 1, max(p[1] for p in pts) + 1)
    icm = Image.new('L', pill.size, 0)
    for x, y in pts: icm.putpixel((x, y), 255)
    sc = ICON / max(ib[2] - ib[0], ib[3] - ib[1])
    iw, ih = round((ib[2] - ib[0]) * sc), round((ib[3] - ib[1]) * sc)
    ic = icm.crop(ib).resize((iw, ih), Image.LANCZOS)
    for y in range(ih):
        for x in range(iw):
            if ic.getpixel((x, y)) > 90: idx.putpixel((12 + x, (H - ih) // 2 + y), 3)
    tm = Image.new('1', (W, H), 0)
    for dx in (0, 1):                                       # 错开 1 点再画一遍 = 加粗（接近截图里的粗体）
        ImageDraw.Draw(tm).text((12 + ICON + 6 + dx, (H - 16) // 2), TEXT, font=font, fill=1)
    for y in range(H):
        for x in range(W):
            if tm.getpixel((x, y)) and px_ok(mask, x, y): idx.putpixel((x, y), 2)

px = idx.load()
ICON_END = 12 + ICON + 3                                    # 列 < ICON_END 的墨 = 天平（橙）
for y in range(H):
    for x in range(W):
        if (px[x, y] == 3) != (px[x, y] in (2, 3) and x < ICON_END):
            sys.exit('天平 / 文字的颜色不能只按列区分（%d,%d）' % (x, y))
with open(os.path.join(HDL, 'display', 'badge_rom.hex'), 'w', newline='\n') as f:
    for y in range(H):
        for x in range(512):
            f.write('%x\n' % (1 if x < W and px[x, y] in (2, 3) else 0))
# 胶囊每行左右缩进（圆角）：第 y 行列 >= ins[y] 且 < W - ins[y] 才在胶囊里（和上面 mask 一致）
ins = []
for y in range(H):
    xs = [x for x in range(W) if mask.getpixel((x, y)) >= 160]
    ins.append(xs[0] if xs else W // 2)
    assert not xs or xs[-1] == W - 1 - xs[0], (y, xs[0], xs[-1])
# 脉动 8 档：倍数 1.00 ~ 1.15，中心 (320, 409)；inv = 4096 / 倍数（Q12，硬件逐点累加取整 = 最近邻缩放）
CX, CY = 320, 409
tab = ['// 自动生成：python -I tools/gen_badge.py（不要手改）。emg_overlay 每帧按脉动档位 lvl 取：左边 - 1 / 右边 + 1 / 上 / 下 + 1 / Q12 步长；',
       '// 下面 ins_of = 胶囊第 y 行左右缩进（圆角），B_W = 原图宽，B_ICON = 天平所在列（列 < B_ICON 的墨是橙色）',
       'case (lvl)']
for L in range(8):
    s = 1 + 0.15 * L / 7
    bw, bh = round(W * s), round(H * s)
    inv = round(4096 / s)
    x0, y0 = CX - bw // 2, CY - bh // 2
    tab.append("    3'd%d: begin t_xm1 <= 10'd%d; t_x1 <= 10'd%d; t_y0 <= 10'd%d; t_y1 <= 10'd%d; t_inv <= 13'd%d; end   // x%.3f %dx%d"
               % (L, x0 - 1, x0 + bw, y0, y0 + bh, inv, s, bw, bh))
tab.append('endcase')
tabi = ['localparam [9:0] B_W = 10\'d%d;' % W, 'localparam [9:0] B_ICON = 10\'d%d;' % ICON_END,
        'function [4:0] ins_of;', '    input [4:0] r;', '    case (r)']
tabi += ["        5'd%d: ins_of = 5'd%d;" % (y, v) for y, v in enumerate(ins)]
tabi += ["        default: ins_of = 5'd31;", '    endcase', 'endfunction']
with open(os.path.join(HDL, 'include', 'badge_shape.vh'), 'w', encoding='utf-8', newline='\n') as f:
    f.write('// 自动生成：python -I tools/gen_badge.py（不要手改）。角标常数和胶囊每行缩进（emg_overlay 模块内 include）\n' + '\n'.join(tabi) + '\n')
with open(os.path.join(HDL, 'include', 'badge_tab.vh'), 'w', encoding='utf-8', newline='\n') as f:
    f.write('\n'.join(tab) + '\n')

# 预览：深灰底（看透明边）+ 急救画面底部（PIC6 板上版）各放 1.0 / 1.15 倍
rgba = Image.new('RGBA', (W, H))
for y in range(H):
    for x in range(W):
        k = px[x, y]
        rgba.putpixel((x, y), (0, 0, 0, 0) if k == 0 else PAL[k] + (255,))
pv = Image.new('RGB', (W * 2 + 120, 150), (40, 40, 40))
base_p = os.path.join(ROOT, 'out', 'cards', 'gen4', 'FINAL_640.png')
base = Image.open(base_p).convert('RGB').crop((320 - W // 2 - 30, 380, 320 + W // 2 + 30, 440)) if os.path.exists(base_p) else None
for i, s in enumerate((1.0, 1.15)):
    b = rgba.resize((round(W * s), round(H * s)), Image.NEAREST)
    pv.paste(b, (10 + i * (W + 40) - (b.width - W) // 2, 10), b)
    if base:
        t = base.copy(); t.paste(b, ((t.width - b.width) // 2, (t.height - b.height) // 2), b)
        pv.paste(t.resize((W + 30, 60)), (5 + i * (W + 40), 70))
pv = pv.resize((pv.width * 2, pv.height * 2), Image.NEAREST)
pv.save(os.path.join(ROOT, 'out', 'badge_preview%s.png' % ('_shot' if SHOT else '')))
print('角标 %dx%d 已生成（%d 位）' % (W, H, W * H * 2))
