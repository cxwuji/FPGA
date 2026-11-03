# R8-5a / R8-5b：bmp_scaler 的逐位参考模型 + 仿真向量生成
#   python -I tools/scaler_ref.py sim/scaler_cases [用例名 ...]   生成各分辨率测试 BMP（.hex 字节）和期望输出（.exp）
# 算法必须和 src/user_source/hdl_source/SD/bmp_scaler.v 一致：
#   尺寸：倍数 s = min(OW/W, OH/H, 3)
#     W<=OW 且 H<=OH 且 3W<=OW 且 3H<=OH：3 倍；否则 W*OH >= H*OW 宽贴满（ho = H*OW//W）；否则高贴满（wo = W*OH//H）；居中 (OW-wo)//2 / (OH-ho)//2
#   缩小 / 原尺寸（面积平均）：原图第 x 列 -> 输出列 x*wo//W，第 y 行（文件顺序）-> y*ho//H；格内和 * round(65536/n) + 32768 >> 16，封顶 255
#   放大（双线性，R8-5b）：步长 st = (S << 16) // D；输出第 d 个 -> p = st//2 - 32768 + d*st（Q16，文件顺序）；
#     p < 0 取 i = 0、f = 0，否则 i = p >> 16、f = (p >> 8) & 255；邻点 i1 = min(i + 1, S - 1)
#     top = a*256 + fx*(b-a)，bot = c*256 + fx*(d-c)，out = (top*256 + fy*(bot-top) + 32768) >> 16
#   输出顺序：文件顺序第 k 行；正高度（自下而上）窗口行 [OH-y0-ho, OH-y0)，负高度（自上而下）[y0, y0+ho)，窗口外黑色
import os
import sys
import numpy as np

OW, OH = 640, 480


def fit_size(w, h, ow=OW, oh=OH):
    if w <= ow and h <= oh and 3 * w <= ow and 3 * h <= oh:
        return 3 * w, 3 * h
    if w * oh >= h * ow:
        return ow, max(1, h * ow // w)
    return max(1, w * oh // h), oh


def recip(n):
    return (65536 + n // 2) // n


def box(src, wo, ho):
    h, w, _ = src.shape
    ox = (np.arange(w) * wo) // w
    oy = (np.arange(h) * ho) // h
    cx = np.bincount(ox, minlength=wo)
    cy = np.bincount(oy, minlength=ho)
    assert cx.max() <= 5 and cy.max() <= 5, (cx.max(), cy.max())
    s = np.zeros((ho, wo, 3), dtype=np.int64)
    np.add.at(s, (oy[:, None], ox[None, :]), src.astype(np.int64))
    n = cy[:, None] * cx[None, :]
    rc = np.vectorize(recip)(n)
    return np.minimum(255, (s * rc[:, :, None] + 32768) >> 16).astype(np.uint8)


def axis(S, D):
    st = (S << 16) // D
    p = st // 2 - 32768 + np.arange(D, dtype=np.int64) * st
    i = np.where(p < 0, 0, p >> 16)
    f = np.where(p < 0, 0, (p >> 8) & 255)
    i1 = np.minimum(i + 1, S - 1)
    assert i.max() <= S - 1
    return i, i1, f


def bilinear(src, wo, ho):
    h, w, _ = src.shape
    s = src.astype(np.int64)
    ix, ix1, fx = axis(w, wo)
    iy, iy1, fy = axis(h, ho)
    a = s[iy][:, ix]
    b = s[iy][:, ix1]
    c = s[iy1][:, ix]
    d = s[iy1][:, ix1]
    fx = fx[None, :, None]
    fy = fy[:, None, None]
    top = a * 256 + fx * (b - a)
    bot = c * 256 + fx * (d - c)
    out = (top * 256 + fy * (bot - top) + 32768) >> 16
    assert out.min() >= 0 and out.max() <= 255
    return out.astype(np.uint8)


def scale(src, td=False, ow=OW, oh=OH):
    """src: (H, W, 3) uint8，行 = 文件顺序。返回 (oh, ow, 3) uint8，行 = 输出顺序（文件顺序）。"""
    h, w, _ = src.shape
    wo, ho = fit_size(w, h, ow, oh)
    up = w <= ow and h <= oh and (wo, ho) != (w, h)
    img = bilinear(src, wo, ho) if up else box(src, wo, ho)
    out = np.zeros((oh, ow, 3), dtype=np.uint8)
    x0 = (ow - wo) // 2
    y0 = (oh - ho) // 2
    kb = y0 if td else oh - y0 - ho
    out[kb:kb + ho, x0:x0 + wo] = img
    return out, (wo, ho, x0, y0, 'up' if up else 'box')


def make_src(w, h, seed):
    """测试图：渐变 + 噪声 + 细线（缩小时面积平均和取点差别很明显）"""
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w]
    img = np.zeros((h, w, 3), dtype=np.int64)
    img[:, :, 0] = x * 255 // max(1, w - 1)
    img[:, :, 1] = y * 255 // max(1, h - 1)
    img[:, :, 2] = ((x // 7 + y // 5) % 2) * 200
    img += rng.integers(0, 40, size=(h, w, 3))
    img[::9, :, :] = 255                     # 细横线
    img[:, ::11, 1] = 0                      # 细竖线
    return np.clip(img, 0, 255).astype(np.uint8)


def bmp_bytes(src_file_order, td=False):
    """24 位 BMP；src 的第 0 行就是文件里的第 0 行（正高度 = 图像最下面一行，td = True 时写负高度 = 最上面一行）"""
    h, w, _ = src_file_order.shape
    row = (w * 3 + 3) // 4 * 4
    pad = row - w * 3
    hdr = bytearray(54)
    size = 54 + row * h
    hdr[0:2] = b'BM'
    hdr[2:6] = size.to_bytes(4, 'little')
    hdr[10:14] = (54).to_bytes(4, 'little')
    hdr[14:18] = (40).to_bytes(4, 'little')
    hdr[18:22] = w.to_bytes(4, 'little')
    hdr[22:26] = ((-h) & 0xffffffff if td else h).to_bytes(4, 'little')
    hdr[26:28] = (1).to_bytes(2, 'little')
    hdr[28:30] = (24).to_bytes(2, 'little')
    hdr[34:38] = (row * h).to_bytes(4, 'little')
    body = bytearray()
    for r in range(h):
        body += src_file_order[r, :, ::-1].tobytes()   # B G R
        body += b'\0' * pad
    return bytes(hdr) + bytes(body)


# (名字, 宽, 高, 负高度)
CASES = [
    ('p640x480', 640, 480, False), ('p1920x1080', 1920, 1080, False), ('p1280x720', 1280, 720, False),
    ('p1024x768', 1024, 768, False), ('p800x600', 800, 600, False), ('p333x250', 333, 250, False),
    ('p1080x1920', 1080, 1920, False), ('p1001x1900', 1001, 1900, False), ('p650x490', 650, 490, False),
    ('p1920x8', 1920, 8, False), ('p8x1920', 8, 1920, False),
    # R8-5b
    ('p320x240', 320, 240, False), ('p160x120', 160, 120, False), ('p240x320', 240, 320, False),
    ('p600x450', 600, 450, False), ('p8x8', 8, 8, False), ('p214x100', 214, 100, False),
    ('n320x240', 320, 240, True), ('n1280x720', 1280, 720, True), ('p640x300', 640, 300, False),
]

if __name__ == '__main__':
    out = sys.argv[1]
    only = sys.argv[2:]
    os.makedirs(out, exist_ok=True)
    for i, (name, w, h, td) in enumerate(CASES):
        if only and name not in only:
            continue
        src = make_src(w, h, i)
        data = bmp_bytes(src, td)
        with open(os.path.join(out, name + '.hex'), 'w') as f:
            f.write('\n'.join('%02x' % b for b in data))
        exp, geo = scale(src, td)
        with open(os.path.join(out, name + '.exp'), 'w') as f:
            flat = exp.reshape(-1, 3)
            f.write('\n'.join('%02x%02x%02x' % tuple(p) for p in flat))
        print(name, len(data), 'bytes; wo ho x0 y0 mode =', geo)
