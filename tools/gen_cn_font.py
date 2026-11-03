# R1.5b 中文 OSD：界面文字表 -> 16x16 点阵字库 + Verilog 文字宏
#   用法（仓库根目录）：python -I tools/gen_cn_font.py
#   输出：
#     src/user_source/hdl_source/display/cn_font16.hex   字库（16384 行，每行 1 字节 = 半字宽 8 点的一行，最高位在左）
#     src/user_source/hdl_source/include/ui_text.vh      `define T_xxx {8'h..}，每个汉字占 2 个字节（编码, 8'h7F）
#     src/user_source/hdl_source/io/text_rom.hex         R8-0b 文字 ROM（4096 字节）：每行一段 24 格模板（字幕 64 格）+ 词表
#     src/user_source/hdl_source/include/text_ids.vh     `define X_xxx = 模板在 ROM 里的起始地址，XW_Enn = 效果名词表地址
#     out/cn_font_preview.png                             所有文字按 ROM 解码渲染出来，人工检查用
# 编码（R8-1b 起最多 384 个汉字）：0x20~0x7C = ASCII（半宽 8x16）；第 k 个汉字 = {8'h80 | k[6:0], 标记}，
#   标记 8'h7F / 7E / 7D = 第 0 / 1 / 2 页（每页 128 字）。写入文字 RAM 时转成 11 位 {右半, 页[1:0], 码}。
# 字库地址 = {idx[9:0], row[3:0]}：ASCII idx = 码值；汉字 k 左半 idx = 页基址 + 2*(k%128)，右半再 +1，
#   页基址：第 0 页 512、第 1 页 768、第 2 页 256（R8-1b：用上原来空着的 256~511，不加 BRAM）
import os
import sys
from PIL import Image, ImageDraw, ImageFont

try:
    sys.stdout.reconfigure(encoding='utf-8')
except AttributeError:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HDL = os.path.join(ROOT, 'src', 'user_source', 'hdl_source')
FONT = os.environ.get('CN_FONT', 'C:/Windows/Fonts/simsun.ttc')

# 名字: (文字, 宽度（半宽格数）, 对齐 l/c)
T = {}
def w(name, text, width=None, align='l'):
    T[name] = (text, width, align)

# ---- 状态栏（左上，常驻）----
w('S_AUTO', '轮播'); w('S_MUSIC', '音乐'); w('S_BRI', '亮度'); w('S_CON', '对比度')
w('ON', '开'); w('OFF', '关')
# ---- 菜单第 1 行 ----
w('M_SETUP', '设置:')
w('PG_TRANS', '转场', 10); w('PG_LAYER', '图层-', 5); w('PG_VIEW', '画面与声音', 10)
# ---- 菜单第 2 行：项目名（9 格）----
for n, t in [('EFFECT', '效果'), ('SPEED', '速度'), ('MODE', '模式'), ('DEMO', '演示'),
             ('SEL', '选择'), ('SHOW', '显示'), ('X', '横坐标'), ('Y', '纵坐标'), ('ALPHA', '透明度'),
             ('ORDER', '层序'), ('MOTION', '运动'), ('RESET', '复位'),
             ('SX', '横向缩放'), ('SY', '纵向缩放'), ('MIRROR', '镜像'), ('FLIP', '翻转'), ('PANX', '横移'),
             ('PANY', '纵移'), ('KB', '推拉摇移'), ('VIZ', '可视化'), ('VOL', '音量'), ('AVT', '音画测试')]:
    w('I_' + n, t, 9)
# ---- 取值（15 格）----
w('V_ON', '开', 15); w('V_OFF', '关', 15); w('V_RUN', '按K3执行', 15)
for i, t in enumerate(['淡入淡出', '右擦除', '左擦除', '下擦除', '上擦除', '圆形扩散', '圆形收缩', '菱形',
                       '横百叶窗', '竖百叶窗', '棋盘格', '随机溶解', '马赛克', '硬切', '向左推移', '向上推移']):   # R12c 14 / 15
    w('E%02d' % i, t, 12)
w('V_FIXED', '固定', 15); w('V_RANDOM', '随机', 15); w('V_CYCLE', '轮换', 15)
for n, t in [('LOGO', '台标'), ('SUB', '字幕'), ('PIP', '画中画'), ('WAVE', '波形')]:
    w('L_' + n, t, 6)
w('V_BOUNCE', '弹跳', 15); w('V_SCROLL', '滚动', 15)
w('V_WAVE', '波形', 15); w('V_BAR', '频谱', 15); w('V_METER', '音量表', 15)      # R8-2：示波器删掉
w('U_TIMES', '倍'); w('U_TRANS', '转场')
# ---- R8-2 显示页（SW1 开、页 00）：菜单框常驻按键表 + 当前值；色彩 / 字幕颜色名放进变量字节 V3~V8 ----
w('D_COLOR', '色彩'); w('D_SUB', '字幕'); w('D_SEC', '秒'); w('D_SCOL', '字幕颜色'); w('D_INT', '轮播间隔')
w('D_GAP', '间隔')                                              # R8-2b 状态栏第三行
w('R_SRC', '原图'); w('R_DN', '缩小', 6); w('R_UP', '放大', 6); w('R_EQ', '原尺寸', 6)   # R8-5c 状态栏第四行
for i, t in enumerate(['黑白', '淡', '标准', '鲜艳']):          # 饱和度 0 / 0.5 / 1 / 1.5
    w('SAT%d' % i, t, 4)
for i, t in enumerate(['白', '黄', '红', '绿', '青', '橙', '粉', '蓝']):
    w('SC%d' % i, t, 2)
# ---- 图层：字幕条（64 格；以后可由电脑串口改写）----
# R8-1b：每张轮播图一条，换图自动换；电脑串口可替换（R8-1c）。改字后重新运行本脚本再编译
# R11：轮播 4 张（小米 / 产品讲解 / 最近 AED / 黄金四分钟，「AED 是什么」删掉）；字幕在 64 格里居中（原来左对齐，看着偏左）；地点改成新黄条
# R12：用户 10-30 要求作品简介当第一张、小米广告第二张（TF 卡 PIC1 / PIC2 对调）
for i, t in enumerate(['智能急救指导多媒体屏：平时播广告，有人倒地一键变身急救员',
                       '小米 18 Pro 新品上市：多一面，万千可能',
                       '最近的 AED 在一楼大厅服务中心，紧急时请立即去取',
                       '黄金四分钟：4 分钟内开始心肺复苏，救活率可达 50%']):
    w('SUB%d' % (i + 1), t, 64, 'c')
# ---- 中间提示条（24 格居中，2 倍字）----
for n, t in [('AUTO_ON', '自动轮播 开启'), ('AUTO_OFF', '自动轮播 关闭'),
             ('MUS_ON', '背景音乐 开启'), ('MUS_OFF', '背景音乐 关闭'),
             ('SET_ON', '设置模式 开启'), ('SET_OFF', '设置模式 关闭'),
             ('SW1', '请先打开 SW1 进入设置'),
             ('BRI1', '亮度 1'), ('BRI2', '亮度 2'), ('BRI3', '亮度 3'), ('BRI4', '亮度 4'),
             ('CON1', '对比度 1'), ('CON2', '对比度 2'), ('CON3', '对比度 3'), ('CON4', '对比度 4'),
             ('NEXT', '下一张'), ('PREV', '上一张'), ('THUMB', '缩略图'), ('FULL', '全屏显示'), ('PLAY', '显示设置'),
             ('TRANS', '转场设置'), ('LAYER', '图层设置'), ('VIEW', '画面与声音设置'),
             ('SUB0', '字幕 关闭'), ('SUB1', '字幕 开启'), ('STAT0', '状态栏 关闭'), ('STAT1', '状态栏 开启'),
             ('VIZ0', '频谱 关闭'), ('VIZ1', '频谱 开启')]:                 # R10 显示页 K1 长按 1~3 秒
    w('H_' + n, t, 24, 'c')
w('H_TFOK', 'TF 卡已恢复', 24, 'c')
w('H_SUBOK', '字幕已更新', 24, 'c')               # R8-1c 电脑串口换字幕
w('H_SUBRST', '已恢复默认字幕', 24, 'c')
w('H_FRST', '已恢复默认设置', 24, 'c')            # R8-4b 显示页 K1 长按 3 秒
w('H_WFAIL', '设置写入失败', 24, 'c')              # R8-4b 存档写卡失败（本次开机不再写）
w('H_LAST0', '上次急救')                           # R8-4b 开机提示「上次急救05:32 按压0312次」
# R8-4b 资源：删画中画 / 推拉摇移，演示 8 -> 6 个节目
DEMO = ['转场特效', '台标弹跳', '字幕滚动', '镜像翻转', '音量表', '频谱']
for i, t in enumerate(DEMO):
    w('D%d' % i, '演示 %d/%d  %s' % (i + 1, len(DEMO), t), 24, 'c')
# ---- 正中故障条（24 格居中，2 倍字，闪烁）----
for n, t in [('NOCARD', '未检测到 TF 卡，请插好'), ('FORMAT', 'TF 卡格式错误，需 FAT32'),
             ('NOPIC', 'TF 卡里没有 PIC1-4.BMP'), ('LOST', 'TF 卡读取失败，请检查'),
             ('BADIMG', '图片格式错误，需 640x480'), ('NOMUSIC', '没有背景音乐 MUSIC.WAV'),
             ('CRC', 'TF 卡读取不稳定')]:
    w('F_' + n, t, 24, 'c')
for i in range(1, 5):                              # R11：轮播 4 张
    w('F_MISS%d' % i, '缺少图片 PIC%d.BMP' % i, 24, 'c')
    w('F_BAD%d' % i, '图片 PIC%d 读取失败' % i, 24, 'c')
w('F_MISS6', '缺少急救图 PIC6.BMP', 24, 'c')     # R8-1a：急救专用图（bank5）
w('F_MISSW', '缺少图片'); w('F_PICW', '图片'); w('F_RDFW', '读取失败')   # R9：缺图 / 读图失败合成一段模板，图号用变量 V14
w('F_BAD6', '急救图 PIC6 读取失败', 24, 'c')
# R11 急救正中黄框（借故障条这一行，cn_text_overlay 按 note 画黄色、不闪）
w('F_NK3', '准备好后按K3开始按压', 24, 'c')
w('F_NSW', '到了两分钟，建议换人', 24, 'c')
w('F_LOADW', '正在读取图片')                     # R12 开机读图黄框「正在读取图片 n/m」（模板 F_LOAD，n = V14、m = V13）
# ---- R9 急救（doc/R9_急救改版方案.md，字幕版本 5：底栏口令带图上编号 + 右上框两行要点）----
#   左上状态栏 3 行：计时 + 语音状态 / 30:2 第几组 + 按压次数 / 本部分按键；右上框：要点 2 行；底栏（2 倍字）：口令
w('C_PAST', '晕倒已过'); w('C_PURE', '单纯按压'); w('C_COMP', '按压'); w('C_TIMES', '次')
w('C_END', '急救结束'); w('C_BEATS', '按压节拍'); w('C_AED1', 'AED 第'); w('C_AED2', '送到')
w('C_NOAED', 'AED 未送到', 24)
w('C_V1', '语音开'); w('C_V0', '语音关'); w('C_VN', '无语音'); w('C_GRP1', '第'); w('C_GRP2', '组')
for n, t in [('1', 'K3开始按压 长按K4取消'), ('2', 'AED到按K3 长按K4交接'), ('3', '要按压时按K3 长按K4交接'),
             ('E', '长按K4 回到广告')]:
    w('C_K' + n, t, 24)
for n, a, b in [('1Z', '确认周围环境安全', '安全了再靠近患者'), ('1D', '让患者平躺硬地上', '跪在患者身体一侧'),
                ('1A', '双手拍他双肩', '大声喊：你怎么了'), ('1B', '看胸口5～10秒', '不起伏=没呼吸'),
                ('1C', '开免提跟120说', '报上面黄条的位置'), ('2I', '两乳头连线中点', '双手交叠 掌根用力'),
                ('2R', '电击后马上按压', '别等AED提示'), ('2C', '深5～6厘米', '每下让胸口回弹'),
                ('BR', '捏鼻包嘴', '每口1秒 看胸口起'), ('SW', '换人别停超10秒', '新的人跟着数'),
                ('3A', '开机 跟语音做', '贴片位置看图'), ('3B', '分析电击时', '所有人离开患者')]:
    w('C_T%sa' % n, a, 24); w('C_T%sb' % n, b, 24)
for n, t in [('1Z', '①这里有人晕倒了'), ('1A', '②拍双肩 大声喊'), ('1C', '④打120 取AED'), ('1D', '下面进行CPR按压+人工呼吸'),
             ('2I', '①按压 两乳头中间'), ('2S', '①开始按压'), ('2R', '①继续按压'), ('BE', '①继续准备按压'),
             ('3A', 'AED优先 照图做'), ('3B', '听AED语音 别碰患者'), ('END', '请向 120 医生交接')]:
    w('H_C_' + n, t, 24, 'c')
w('B_LOOK', '③看胸口起伏'); w('B_PRESS', '①胸外按压'); w('B_BREATH', '③人工呼吸')

def cells(t):
    return sum(1 if ord(c) < 0x80 else 2 for c in t)


# 半宽字符只能用 0x20~0x7C：0x7D~0x7F 是汉字页标记（R9：ASCII '~' 被当成第 1 页标记，显示成乱字）
for _n, (_t, _w, _a) in T.items():
    _bad = [c for c in _t if 0x7d <= ord(c) < 0x80]
    if _bad:
        sys.exit('%s 里有不能用的半宽字符 %r（请换成全角）' % (_n, _bad))


chars = []
# 字幕（SUBn）里的字最后分配：界面文字的字号不随字幕改动而变，字幕新字落在后面的页里
for name, (t, width, align) in sorted(T.items(), key=lambda kv: kv[0].startswith('SUB') and kv[0] != 'SUB'):
    for c in t:
        if ord(c) >= 0x80 and c not in chars:
            chars.append(c)
if len(chars) > 384:
    sys.exit('汉字 %d 个，超过 384' % len(chars))

font = ImageFont.truetype(FONT, 16)


def glyph(ch, wd):
    im = Image.new('1', (wd, 16), 0)
    d = ImageDraw.Draw(im)
    d.fontmode = '1'
    d.text((0, 0), ch, font=font, fill=1)
    return im


rom = [0] * 16384
def put(idx, im, x0):
    for r in range(16):
        b = 0
        for c in range(8):
            if im.getpixel((x0 + c, r)):
                b |= 0x80 >> c
        rom[idx * 16 + r] = b

def cidx(k, half):
    return (512, 768, 256)[k >> 7] + 2 * (k & 127) + half


for code in range(0x20, 0x7d):
    put(code, glyph(chr(code), 8), 0)
for k, ch in enumerate(chars):
    im = glyph(ch, 16)
    put(cidx(k, 0), im, 0)
    put(cidx(k, 1), im, 8)

with open(os.path.join(HDL, 'display', 'cn_font16.hex'), 'w', newline='\n') as f:
    for b in rom:
        f.write('%02x\n' % b)


def encode(t):
    out = []
    for c in t:
        if ord(c) < 0x80:
            out.append(ord(c))
        else:
            k = chars.index(c)
            out += [0x80 | (k & 127), 0x7f - (k >> 7)]
    return out


lines = ['// 自动生成：python -I tools/gen_cn_font.py（不要手改）',
         '// 汉字 = {编码 8\'h80+k, 8\'h7F}；宽度单位 = 半宽格（8 点）',
         '`ifndef UI_TEXT_VH', '`define UI_TEXT_VH']
pv = []
MB = {}
for name, (t, width, align) in T.items():
    n = cells(t)
    if width is None:
        width = n
    if n > width:
        sys.exit('%s 太长：%d > %d' % (name, n, width))
    pad = width - n
    left = pad // 2 if align == 'c' else 0
    b = [0x20] * left + encode(t) + [0x20] * (pad - left)
    lines.append('`define T_%-10s {%s}   // %d 格 "%s"' % (name, ','.join("8'h%02x" % x for x in b), width, t))
    pv.append(b)
    MB[name] = b
lines.append('`endif')
with open(os.path.join(HDL, 'include', 'ui_text.vh'), 'w', encoding='utf-8', newline='\n') as f:
    f.write('\n'.join(lines) + '\n')

# ---- R8-0b 文字 ROM：page_menu_ctrl 每行只选"用哪段模板"，字节从 ROM 读出 ----
# 模板字节 >= 0x20 原样输出；0x01~0x0F = 变量字节 Vn（数字 / 时间，page_menu_ctrl 里算好）；
# 0x10~0x1F = 本行词的第 n 个字节（词表：14 个效果名，每个 12 字节，菜单「效果」项和提示条「转场 xx」用）
def m(name): return MB[name]
def s(t): return [ord(c) for c in t]
def sp(n): return [0x20] * n
def v(n): return [n]
def wd(n): return [0x10 + i for i in range(n)]
TPL = []
def tp(name, *parts, length=24):
    bb = sum(parts, [])
    if len(bb) != length:
        sys.exit('模板 %s 长度 %d != %d' % (name, len(bb), length))
    TPL.append((name, bb))
CTMR = v(1) + v(2) + s(':') + v(3) + v(4)            # 急救：晕倒已过 mm:ss
CCMP = v(5) + v(6) + v(7) + v(8)                     # 按压 nnnn
CAED = v(11) + v(12) + s(':') + v(13) + v(14)        # AED 送到时刻 mm:ss
IDX = v(3) + v(4) + v(5) + v(6) + v(7)               # 菜单项 "  i/N"
# 第 0 行：状态栏 1
for a in (0, 1):
    for mu in (0, 1):
        tp('S1_A%dM%d' % (a, mu), m('S_AUTO'), s(' '), m('ON' if a else 'OFF'), s('    '),
           m('S_MUSIC'), s(' '), m('ON' if mu else 'OFF'), sp(6))
for n in ('V1', 'V0', 'VN'):                          # R9：晕倒已过 03:25  语音开
    tp('S1_C' + n, m('C_PAST'), s(' '), CTMR, s('  '), m('C_' + n), sp(2))
tp('S1_CEND', m('C_END'), sp(16))
# 第 1 行：状态栏 2
tp('S2_N', m('S_BRI'), s(' '), v(1), s('    '), m('S_CON'), s(' '), v(2), sp(6))
tp('S2_C302', s('30:2 '), m('C_GRP1'), v(9), v(10), m('C_GRP2'), s(' '), m('C_COMP'), CCMP, m('C_TIMES'), sp(2))   # 30:2 第03组 按压0087次
tp('S2_CPURE', m('C_PURE'), s(' '), m('C_COMP'), CCMP, m('C_TIMES'), sp(5))
tp('S2_CEND', m('C_PAST'), s(' '), CTMR, sp(10))
# 第 7 行（R8-2b）：状态栏 3「色彩标准 字幕黄 间隔15秒」，变量用 page_menu_ctrl 的 vb7（V1~V4 色彩名、V5 V6 字幕颜色、V7 V8 间隔秒数）
tp('S3_N', m('D_COLOR'), v(1), v(2), v(3), v(4), s(' '), m('D_SUB'), v(5), v(6), s(' '), m('D_GAP'), v(7), v(8), m('D_SEC'))
for n in ('1', '2', '3', 'E'):                         # R9 急救：状态栏第三行 = 本部分按键
    tp('S3_CK' + n, m('C_K' + n))
# 第 8 行（R8-5c）：状态栏 4「原图1920x1080 缩小」，变量用 page_menu_ctrl 的 vb8（V1~V9 = 「宽x高」左对齐补空格）
for n in ('DN', 'UP', 'EQ'):
    tp('S4_' + n, m('R_SRC'), *[v(i) for i in range(1, 10)], s(' '), m('R_' + n), sp(4))
# 第 2 行：菜单 1
# 显示页（R8-2b 只写按键名、K2 K4 同列）：「K1亮度      K2对比度」/「K3色彩      K4字幕/间隔」；当前值看状态栏第三行和提示条
tp('M1_DISP', s('K1'), m('S_BRI'), sp(6), s('K2'), m('S_CON'), sp(4))
tp('M1_TRANS', m('M_SETUP'), m('PG_TRANS'), s('    '), IDX)
for i, n in enumerate(['LOGO', 'SUB', 'PIP', 'WAVE']):
    tp('M1_LAYER%d' % i, m('M_SETUP'), m('PG_LAYER'), m('L_' + n), s('   '), IDX)
tp('M1_VIEW', m('M_SETUP'), m('PG_VIEW'), s('    '), IDX)
tp('M1_CBEATS', m('C_BEATS'), s(' '), CCMP, s(' '), m('C_TIMES'), sp(8))
TIPS = ['1Z', '1A', '1B', '1C', '1D', '2I', '2R', '2C', 'BR', 'SW', '3A', '3B']
for n in TIPS:                                         # R9 右上框要点第 1 行
    tp('M1_CT' + n, m('C_T%sa' % n))
# 第 3 行：菜单 2（项目名 9 格 + 取值 15 格）
def it(name, iname, *val):
    tp('M2_' + name, m('I_' + iname), *val)
tp('M2_DISP', s('K3'), m('D_COLOR'), sp(6), s('K4'), m('D_SUB'), s('/'), m('D_GAP'), sp(1))
it('EFFECT', 'EFFECT', v(8), v(9), s(' '), wd(12))
it('SPEED', 'SPEED', v(8), sp(14))
for i, n in enumerate(['FIXED', 'RANDOM', 'CYCLE']):
    it('MODE%d' % i, 'MODE', m('V_' + n))
# R10 资源：一键演示删掉（M2_DEMOn / H_Dn 模板不再生成）
for i, n in enumerate(['LOGO', 'SUB', 'PIP', 'WAVE']):
    it('SEL%d' % i, 'SEL', m('L_' + n), sp(9))
it('SHOW0', 'SHOW', m('V_OFF')); it('SHOW1', 'SHOW', m('V_ON'))
it('X', 'X', v(8), v(9), v(10), sp(12))
it('Y', 'Y', v(8), v(9), v(10), sp(12))
it('ALPHA', 'ALPHA', v(8), v(9), v(10), s('%'), sp(11))
it('ORDER', 'ORDER', v(8), s('/4'), sp(12))
for i, n in enumerate(['OFF', 'BOUNCE', 'SCROLL']):
    it('MOT%d' % i, 'MOTION', m('V_' + n))
it('LRESET', 'RESET', m('V_RUN'))
it('SX', 'SX', v(8), s('.'), v(9), v(10), s(' '), m('U_TIMES'), sp(8))
it('SY', 'SY', v(8), s('.'), v(9), v(10), s(' '), m('U_TIMES'), sp(8))
for n, iname in [('MIR', 'MIRROR'), ('FLIP', 'FLIP')]:   # R8-4b 删推拉摇移（KB）
    it(n + '0', iname, m('V_OFF')); it(n + '1', iname, m('V_ON'))
it('PANX', 'PANX', v(8), v(9), v(10), v(11), sp(11))
it('PANY', 'PANY', v(8), v(9), v(10), v(11), sp(11))
for i, n in [(0, 'OFF'), (2, 'BAR')]:   # viz 3（示波器）R8-2 删掉；R10 删波形 1 / 音量表 4
    it('VIZ%d' % i, 'VIZ', m('V_' + n))
it('VOL', 'VOL', v(8), v(9), v(10), s('%'), sp(11))
it('VRESET', 'RESET', m('V_RUN'))
for n in TIPS:                                         # R9 右上框要点第 2 行
    tp('M2_CT' + n, m('C_T%sb' % n))
tp('M2_CNOAED', m('C_NOAED'))
tp('M2_CAED', m('C_AED1'), s(' '), CAED, s(' '), m('C_AED2'), sp(7))
# 第 4 行：提示条 / 急救底部短句
tp('H_NONE', sp(24))
# R9 省文字 ROM：亮度 / 对比度提示 4 档合成一段，档位数字用变量 V1 / V2（和 T_H_BRIn / T_H_CONn 逐字节相同）
tp('H_BRI', sp(9), m('S_BRI'), s(' '), v(1), sp(9))
tp('H_CON', sp(8), m('S_CON'), s(' '), v(2), sp(8))
for n in ['AUTO_ON', 'AUTO_OFF', 'MUS_ON', 'MUS_OFF', 'SET_ON', 'SET_OFF', 'SW1',
          'THUMB', 'FULL', 'PLAY', 'TRANS', 'LAYER', 'VIEW', 'NEXT', 'PREV', 'TFOK',
          'SUBOK', 'SUBRST', 'SUB0', 'SUB1', 'STAT0', 'STAT1', 'FRST', 'WFAIL', 'VIZ0', 'VIZ1']:
    tp('H_' + n, m('H_' + n))
tp('H_LAST', m('H_LAST0'), v(3), v(4), s(':'), v(5), v(6), s(' '), m('C_COMP'), v(7), v(8), v(9), v(10), m('C_TIMES'))
tp('H_EFF', s('    '), m('U_TRANS'), s('  '), wd(12), s('  '))
tp('H_SAT', sp(7), m('D_COLOR'), s(' '), v(3), v(4), v(5), v(6), sp(8))               # 色彩 标准
tp('H_SCOL', sp(6), m('D_SCOL'), s(' '), v(7), v(8), sp(7))                          # 字幕颜色 黄
tp('H_INT', sp(5), m('D_INT'), s(' '), v(9), v(10), s(' '), m('D_SEC'), sp(5))       # 轮播间隔 15 秒

for n in ['1Z', '1A', '1C', '1D', '2I', '2S', '2R', 'BE', '3A', '3B', 'END']:
    tp('H_C_' + n, m('H_C_' + n))
# R9 底栏带数字的三句（居中）：③看胸口起伏 5（倒数）/ ①胸外按压 17/30 / ③人工呼吸 1/2
tp('H_C_1B', sp(5), m('B_LOOK'), s(' '), v(13), sp(5))
tp('H_C_2C', sp(4), m('B_PRESS'), s(' '), v(11), v(12), s('/30'), sp(4))
tp('H_C_BR', sp(5), m('B_BREATH'), s(' '), v(13), s('/2'), sp(5))
# 第 5 行：字幕条（64 格）
for i in range(1, 5):
    tp('SUB%d' % i, m('SUB%d' % i), length=64)
# 第 6 行：故障条
tp('F_NONE', sp(24))
for n in ['NOCARD', 'FORMAT', 'NOPIC', 'LOST', 'BADIMG', 'NOMUSIC', 'CRC', 'MISS6', 'BAD6', 'NK3', 'NSW']:
    tp('F_' + n, m('F_' + n))
tp('F_MISS', sp(3), m('F_MISSW'), s(' PIC'), v(14), s('.BMP'), sp(4))          # 和 T_F_MISSn 逐字节相同
tp('F_BAD', sp(3), m('F_PICW'), s(' PIC'), v(14), s(' '), m('F_RDFW'), sp(3))  # 和 T_F_BADn 逐字节相同
tp('F_LOAD', sp(4), m('F_LOADW'), s(' '), v(14), s('/'), v(13), sp(4))           # R12

trom = []
tl = ['// 自动生成：python -I tools/gen_cn_font.py（不要手改）',
      '// R8-0b 文字 ROM（io/text_rom.hex）里每段模板 / 词的起始地址', '`ifndef TEXT_IDS_VH', '`define TEXT_IDS_VH']
for name, bb in TPL:
    tl.append("`define X_%-10s 13'd%d" % (name, len(trom)))
    trom += bb
for i in range(16):                                   # R12c：14 / 15 推移
    tl.append("`define XW_E%02d      13'd%d" % (i, len(trom)))
    trom += MB['E%02d' % i]
tl.append('`endif')
ROM_N = 4096                                          # R9：合并重复模板后仍在 4096 内（5120 不是 2 的幂，TD 会用 8 块 BRAM）
if len(trom) > ROM_N:
    sys.exit('文字 ROM %d 字节，超过 %d' % (len(trom), ROM_N))
with open(os.path.join(HDL, 'include', 'text_ids.vh'), 'w', encoding='utf-8', newline='\n') as f:
    f.write('\n'.join(tl) + '\n')
with open(os.path.join(HDL, 'io', 'text_rom.hex'), 'w', newline='\n') as f:
    for x in trom + [0x20] * (ROM_N - len(trom)):
        f.write('%02x\n' % x)
print('文字 ROM：模板 %d 段，%d 字节' % (len(TPL), len(trom)))

# 预览：完全按硬件解码（0x7F = 前一字节的右半）
W = max(len(b) for b in pv) * 8
img = Image.new('L', (W, 18 * len(pv)), 40)
for li, b in enumerate(pv):
    for ci, x in enumerate(b):
        if x in (0x7d, 0x7e, 0x7f):
            idx = cidx((b[ci - 1] & 127) + 128 * (0x7f - x), 1)
        elif x >= 0x80:
            idx = cidx((x & 127) + 128 * (0x7f - b[ci + 1]), 0)
        else:
            idx = x
        for r in range(16):
            v = rom[idx * 16 + r]
            for c in range(8):
                if v & (0x80 >> c):
                    img.putpixel((ci * 8 + c, li * 18 + r), 255)
os.makedirs(os.path.join(ROOT, 'out'), exist_ok=True)
img.resize((W * 2, img.height * 2), Image.NEAREST).save(os.path.join(ROOT, 'out', 'cn_font_preview.png'))
print('汉字 %d 个，文字宏 %d 条' % (len(chars), len(T)))
