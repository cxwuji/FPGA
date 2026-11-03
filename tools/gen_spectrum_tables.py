# R8-3 频谱用的常数表 -> src/user_source/hdl_source/include/spectrum_tables.vh（不要手改生成文件）
#   用法（仓库根目录）：python -I tools/gen_spectrum_tables.py
#   spec_cos(k)  k = 0..128：round(32767 * cos(2*pi*k/512))，1/4 周期余弦表（FFT 旋转因子 + Hann 窗共用）
#   spec_edge(i) i = 0..32：第 i 根柱的起始频点（24 kHz / 512 点 = 46.875 Hz 一个频点），按 mel 刻度等分（人耳感知刻度：
#                700 Hz 以上近似对数、以下近似线性；纯对数时 512 点在低频分辨率不够，前一半柱子都挤在 850 Hz 以下），至少 1 个频点宽
#   spec_color(i) i = 0..31：彩虹色（HSL：H 0~300 度，S 0.85，L 0.6，参考 Music-Spectrum-main）
#   这个文件在模块体内 `include（每个用到的模块各 include 一次，所以不加 ifndef 保护）
import colorsys
import math
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'src', 'user_source', 'hdl_source', 'include', 'spectrum_tables.vh')
NBAR, LO, HI = 32, 2, 214              # 频点 2（94 Hz，避开直流漏到的频点 1）~ 213（10.0 kHz）
BIN = 24000 / 512


def mel(f): return 2595 * math.log10(1 + f / 700)
def imel(m): return 700 * (10 ** (m / 2595) - 1)

edges = [LO]
for i in range(1, NBAR + 1):
    e = round(imel(mel(LO * BIN) + (mel(HI * BIN) - mel(LO * BIN)) * i / NBAR) / BIN)
    edges.append(max(e, edges[-1] + 1))
assert edges[-1] == HI, edges

L = ['// 自动生成：python -I tools/gen_spectrum_tables.py（不要手改）',
     '// 分柱（频点 46.875 Hz）：' + ' '.join(str(e) for e in edges),
     'function [15:0] spec_cos;', '    input [7:0] k;', '    case (k)']
for k in range(129):
    L.append("        8'd%d: spec_cos = 16'd%d;" % (k, round(32767 * math.cos(2 * math.pi * k / 512))))
L += ["        default: spec_cos = 16'd0;", '    endcase', 'endfunction',
      'function [7:0] spec_edge;', '    input [5:0] i;', '    case (i)']
for i, e in enumerate(edges):
    L.append("        6'd%d: spec_edge = 8'd%d;" % (i, e))
L += ["        default: spec_edge = 8'd%d;" % HI, '    endcase', 'endfunction',
      'function [23:0] spec_color;', '    input [4:0] i;', '    case (i)']
for i in range(NBAR):
    r, g, b = colorsys.hls_to_rgb(300.0 * i / (NBAR - 1) / 360.0, 0.6, 0.85)
    L.append("        5'd%d: spec_color = 24'h%02x%02x%02x;" % (i, round(r * 255), round(g * 255), round(b * 255)))
L += ["        default: spec_color = 24'hffffff;", '    endcase', 'endfunction']
with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
    f.write('\n'.join(L) + '\n')
print('分柱起始频点：', edges)
