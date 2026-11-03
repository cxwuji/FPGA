# R8-6 正式图片：候选 PNG -> TF 卡 PIC1~6.BMP（6 种分辨率兼当缩放测试集）+ preview.png（用 scaler_ref 算板上效果）
#   python -I tools/make_cards.py out/cards/final
import importlib.util
import os
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

_spec = importlib.util.spec_from_file_location('scaler_ref', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'scaler_ref.py'))
ref = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ref)

C = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'out', 'cards', '候选')
CARDS = [('PIC1_小米_A.png', 1280, 720),          # 16:9 缩小，上下黑边
         ('新_产品讲解_扁平_A.png', 1920, 1080),   # 16:9 缩小 1/3
         ('新_最近AED_扁平_A.png', 1024, 768),     # 4:3 缩小铺满
         ('新_AED是什么_扁平_A.png', 800, 600),    # 4:3 缩小铺满
         ('PIC5_黄金四分钟_A.png', 480, 360),      # 4:3 双线性放大 4/3
         ('PIC6_详细版乙_640x480.png', 640, 480)]  # 急救图原尺寸（R9 详细版，内容 y 84~394，见 doc/R9_急救改版方案.md）
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
font = ImageFont.load_default(size=22)
preview = Image.new('RGB', (650 * 3, 520 * 2), (34, 34, 34))
for n, (src, w, h) in enumerate(CARDS):
    im = Image.open(os.path.join(C, src)).convert('RGB').resize((w, h), Image.LANCZOS)
    fo = np.asarray(im)[::-1]                      # 正高度 BMP 自下而上
    path = os.path.join(out, f'PIC{n + 1}.BMP')
    with open(path, 'wb') as f:
        f.write(ref.bmp_bytes(np.ascontiguousarray(fo), False))
    o, geo = ref.scale(fo, False)
    x, y = (n % 3) * 650 + 5, (n // 3) * 520 + 5
    preview.paste(Image.fromarray(np.ascontiguousarray(o[::-1])), (x, y + 35))
    ImageDraw.Draw(preview).text((x, y + 5), f'PIC{n + 1}  {w}x{h}  {geo}', fill=(255, 210, 0), font=font)
    print(f'PIC{n + 1}.BMP <- {src} {w}x{h} {os.path.getsize(path)} bytes -> {geo}')
preview.save(os.path.join(out, 'preview.png'))
