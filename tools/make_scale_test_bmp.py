# R8-5a / R8-5b 上板测试卡：6 张不同分辨率的 24 位 BMP（PIC1~5 轮播，PIC6 急救图位置）+ preview.png（期望效果，用 scaler_ref 算）
#   python -I tools/make_scale_test_bmp.py out/test_card_r85          R8-5a：缩小 / 原尺寸
#   python -I tools/make_scale_test_bmp.py out/test_card_r85b b       R8-5b：放大 / 负高度（PIC5 自上而下存）
# 每张图：外圈 2 像素白框（看边缘有没有丢）、左上红三角（看方向）、中间写原分辨率、
#   底部 1 像素黑白细竖线（缩小时面积平均 = 均匀灰，隔点取样会出粗条纹 / 摩尔纹）、灰度渐变（看有没有花点）
import importlib.util
import os
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

_spec = importlib.util.spec_from_file_location('scaler_ref', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'scaler_ref.py'))
ref = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ref)

SETS = {
    'a': [(1920, 1080, False), (1280, 720, False), (1024, 768, False), (640, 480, False), (1080, 1920, False), (800, 600, False)],
    'b': [(320, 240, False), (333, 250, False), (160, 120, False), (240, 320, False), (800, 600, True), (1920, 1080, False)],
}
BG = [(0, 0, 80), (60, 0, 60), (0, 60, 40), (70, 40, 0), (0, 50, 70), (80, 0, 0)]

out = sys.argv[1]
sizes = SETS[sys.argv[2] if len(sys.argv) > 2 else 'a']
os.makedirs(out, exist_ok=True)
preview = Image.new('RGB', (640 * 3, 480 * 2))
for n, ((w, h, td), bg) in enumerate(zip(sizes, BG)):
    im = Image.new('RGB', (w, h), bg)
    d = ImageDraw.Draw(im)
    u = min(w / 640, h / 480)                      # 按缩放后大小一致来画
    big = ImageFont.load_default(size=max(10, int(120 * u)))
    d.text((w * 0.08, h * 0.12), f"PIC{n + 1}", fill=(255, 255, 0), font=big)
    d.text((w * 0.08, h * 0.45), f"{w} x {h}", fill=(255, 255, 255), font=big)
    if td:
        d.text((w * 0.08, h * 0.66), "TOP-DOWN BMP", fill=(0, 255, 255), font=ImageFont.load_default(size=max(10, int(40 * u))))
    d.polygon([(0, 0), (max(6, int(90 * u)), 0), (0, max(6, int(90 * u)))], fill=(255, 0, 0))
    # 细竖线条带：1 像素黑 1 像素白
    y0, y1 = int(h * 0.78), int(h * 0.86)
    for x in range(0, w, 2):
        d.line([(x, y0), (x, y1)], fill=(255, 255, 255))
        d.line([(x + 1, y0), (x + 1, y1)], fill=(0, 0, 0))
    for x in range(w):
        v = x * 255 // (w - 1)
        d.line([(x, int(h * 0.89)), (x, int(h * 0.95))], fill=(v, v, v))
    d.rectangle([0, 0, w - 1, h - 1], outline=(255, 255, 255), width=2)
    a = np.asarray(im)                              # 行 = 从上到下
    fo = a if td else a[::-1]                       # 文件顺序：正高度自下而上
    path = os.path.join(out, f"PIC{n + 1}.BMP")
    with open(path, 'wb') as f:
        f.write(ref.bmp_bytes(np.ascontiguousarray(fo), td))
    o, geo = ref.scale(fo, td)
    disp = o if td else o[::-1]                     # loader 翻转后 = 显示顺序
    preview.paste(Image.fromarray(np.ascontiguousarray(disp)), ((n % 3) * 640, (n // 3) * 480))
    print(f"PIC{n + 1}.BMP {w}x{h}{' (负高度)' if td else ''} {os.path.getsize(path)} bytes -> {geo}")
preview.save(os.path.join(out, 'preview.png'))
