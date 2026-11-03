# R7b：生成急救专用图占位 BMP（R8-1a 起文件名是 PIC6.BMP），640x480 24bit，按场景文档 4.1 的固定网格画 6 格并标编号，
# 用户的 image2 素材到之前先拿它上板对位置（急救覆盖、高亮框坐标）。
# 用法：python -I tools/make_pic5_placeholder.py 输出.bmp
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 640, 480
FONT = 'C:/Windows/Fonts/simsun.ttc'
# (名字, 说明, 左上, 右下, 底色)，坐标与 doc/作品场景与使用说明.md 4.1 一致
CELLS = [('L1', '手位', (0, 48), (319, 227), (120, 30, 30)),
         ('L2', '姿势与节奏', (0, 228), (319, 407), (90, 20, 20)),
         ('R1', '开电源', (320, 48), (479, 227), (20, 70, 40)),
         ('R2', '贴电极片', (480, 48), (639, 227), (20, 55, 70)),
         ('R3', '所有人离开', (320, 228), (479, 407), (70, 60, 10)),
         ('R4', '按电击键', (480, 228), (639, 407), (60, 20, 70))]

out = sys.argv[1]
im = Image.new('RGB', (W, H), (16, 16, 16))
d = ImageDraw.Draw(im)
f_big = ImageFont.truetype(FONT, 40)
f_s = ImageFont.truetype(FONT, 20)
d.rectangle([0, 0, W - 1, 47], fill=(40, 40, 40))
d.text((8, 14), 'PIC6 急救图占位 顶栏（OSD）y=0~47', fill=(200, 200, 200), font=f_s)
for name, txt, (x0, y0), (x1, y1), bg in CELLS:
    d.rectangle([x0, y0, x1, y1], fill=bg, outline=(255, 255, 255))
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    d.text((cx, cy - 22), name, fill=(255, 255, 0), font=f_big, anchor='mm')
    d.text((cx, cy + 18), txt, fill=(255, 255, 255), font=f_s, anchor='mm')
    d.text((x0 + 4, y0 + 4), '(%d,%d)' % (x0, y0), fill=(180, 180, 180), font=f_s)
d.rectangle([0, 408, W - 1, H - 1], fill=(40, 40, 40))
d.text((8, 436), 'PIC6 急救图占位 底栏（字幕）y=408~479', fill=(200, 200, 200), font=f_s)
d.polygon([(0, 0), (30, 0), (0, 30)], fill=(255, 0, 0))   # 左上角方向标记
im.save(out, 'BMP')
print('ok', out)
