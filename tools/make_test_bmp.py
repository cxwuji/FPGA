# 生成 5 张 640x480 24bit 验证用 BMP（R8-1a：PIC1~5 轮播）：编号、方向标记、R/G/B/W 色条、1px 边框、灰度渐变
import sys, os
from PIL import Image, ImageDraw, ImageFont

out = sys.argv[1]
W, H = 640, 480
bg = [(0, 0, 80), (60, 0, 60), (0, 60, 40), (70, 40, 0), (0, 50, 70)]
font_big = ImageFont.load_default(size=200)
font_s = ImageFont.load_default(size=28)
for n in range(5):
    im = Image.new('RGB', (W, H), bg[n])
    d = ImageDraw.Draw(im)
    # 色条：红 绿 蓝 白（用来验证 RGB 通道没接反）
    for i, c in enumerate([(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)]):
        d.rectangle([20 + i * 150, 330, 20 + i * 150 + 139, 400], fill=c)
        d.text((20 + i * 150 + 55, 405), "RGBW"[i], fill=(255, 255, 255), font=font_s)
    # 灰度渐变（验证没有花点、条纹）
    for x in range(W):
        v = x * 255 // (W - 1)
        d.line([(x, 445), (x, 470)], fill=(v, v, v))
    # 大编号 + 左上角方向标记（验证顺序、上下/左右没翻）
    d.text((230, 60), str(n + 1), fill=(255, 255, 0), font=font_big)
    d.polygon([(4, 4), (90, 4), (4, 90)], fill=(255, 0, 0))
    d.text((100, 10), "TOP-LEFT", fill=(255, 255, 255), font=font_s)
    # 最外圈 1 像素白框（验证首行/首列像素没丢、没错位）
    d.rectangle([0, 0, W - 1, H - 1], outline=(255, 255, 255))
    im.save(os.path.join(out, f"PIC{n + 1}.BMP"), 'BMP')
print("ok")
