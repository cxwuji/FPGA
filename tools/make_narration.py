# 视频旁白（doc/拍摄懒人手册.md）：edge-tts 云扬（zh-CN-YunyangNeural，新闻播报男声，和板上急救语音的晓晓女声区分开）
#   用法（仓库根目录，要联网）：PYTHONUTF8=1 python tools/make_narration.py [N03_E1转场 ...]（只重新合成列出的段，其余读现有 mp3 算时长）
#   输出 out/拍摄包/配音/Nxx_名字.mp3 + 配音清单.txt（每段时长 + 字幕文字，剪映「识别字幕」认错字时照这个改）
import asyncio
import os
import sys
import time

import miniaudio

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'out', '拍摄包', '配音')
VOICE = 'zh-CN-YunyangNeural'
RATE = '+8%'

# (文件名, 朗读文字, 屏幕字幕文字)：朗读文字里把符号写成读法（×→乘、kHz→千赫），字幕保留原样
N = [
    ('N01_开场', '本作品名为，救在身边，急救指导多媒体屏：基于安路EG4S20 FPGA的商场广告屏，平时轮播广告，有人心脏骤停时，一键变成急救指导屏。',
     '本作品名为《救在身边——急救指导多媒体屏》：基于安路 EG4S20 FPGA 的商场广告屏，平时轮播广告，有人心脏骤停时，一键变成急救指导屏。'),
    ('N02_基础功能', '先看基础功能。程序固化在Flash，上电自动运行，从TF卡读取BMP图片，经SDRAM帧缓存，输出640乘480的HDMI画面；按键切换上一张、下一张，也可以自动轮播；背景音乐以48千赫、16位从TF卡流式读取，经HDMI同步输出。',
     '先看基础功能。程序固化在 Flash，上电自动运行，从 TF 卡读取 BMP 图片，经 SDRAM 帧缓存，输出 640×480 的 HDMI 画面；按键切换上一张、下一张，也可以自动轮播；背景音乐以 48 kHz、16 位从 TF 卡流式读取，经 HDMI 同步输出。'),
    ('N03_E1转场', '扩展功能一：16种转场特效，含两种无黑场推移，8档速度可调。',
     '扩展功能一：16 种转场特效，含 2 种无黑场推移，8 档速度可调。'),
    ('N04_E2频谱', '扩展二：512点定点FFT，实时显示音乐频谱。',
     '扩展二：512 点定点 FFT，实时显示音乐频谱。'),
    ('N05_E3图层字幕', '扩展三：台标、字幕、频谱多图层叠加，透明度和运动方式可调；电脑还能通过串口，下发任意字幕。',
     '扩展三：台标、字幕、频谱多图层叠加，透明度和运动方式可调；电脑还能通过串口，下发任意字幕。'),
    ('N06_E4缩放', '扩展四：任意分辨率的图片，加载时自适应缩放，缩小用面积平均，放大用双线性插值；还能实时缩放、镜像和翻转。',
     '扩展四：任意分辨率的图片，加载时自适应缩放，缩小用面积平均，放大用双线性插值；还能实时缩放、镜像和翻转。'),
    ('N07_E5画质', '扩展五：亮度、对比度、色彩实时调节，中文OSD同步显示。',
     '扩展五：亮度、对比度、色彩实时调节，中文 OSD 同步显示。'),
    ('N08_E6缩略图', '扩展六：2乘2缩略图选图。',
     '扩展六：2×2 缩略图选图。'),
    ('N09_E7位置条', '扩展七：急救时显示的AED位置条，由电脑串口写入，并存进TF卡。',
     '扩展七：急救时显示的 AED 位置条，由电脑串口写入，并存进 TF 卡。'),
    ('N10_E8掉电保存', '扩展八：设置和位置都掉电保存，断电重启后保持不变。',
     '扩展八：设置和位置都掉电保存，断电重启后保持不变。'),
    ('N11_主题日常', '下面是完整的使用场景。平时，它是商场里的一块广告屏。',
     '下面是完整的使用场景。平时，它是商场里的一块广告屏。'),
    ('N12_主题交接', '急救人员赶到后，长按急救键进入交接页，晕倒时长和按压次数一目了然；再长按一次，屏幕恢复广告。',
     '急救人员赶到后，长按急救键进入交接页，晕倒时长和按压次数一目了然；再长按一次，屏幕恢复广告。'),
    ('N13_结尾亮点', '总结：本作品不用处理器，全部由FPGA逻辑实现；亮点是逐拍语音的急救指导、自适应高质量缩放和定点FFT频谱。',
     '总结：本作品不用处理器，全部由 FPGA 逻辑实现；亮点是逐拍语音的急救指导、自适应高质量缩放和定点 FFT 频谱。'),
    ('N14_结尾资源', 'LUT占用百分之83.7，BRAM 56块，各时钟域时序全部收敛。',
     'LUT 占用 83.7%，BRAM 56 块，各时钟域时序全部收敛。'),
    ('N15_结尾可靠性', '读卡带CRC校验重读，TF卡拔出插回自动恢复，适合人员密集的公共场所。',
     '读卡带 CRC 校验重读，TF 卡拔出插回自动恢复，适合人员密集的公共场所。'),
]


async def _tts(text):
    import edge_tts
    b = b''
    async for ch in edge_tts.Communicate(text, VOICE, rate=RATE).stream():
        if ch['type'] == 'audio':
            b += ch['data']
    return b


def tts(text):
    for k in range(5):
        try:
            b = asyncio.run(_tts(text))
            if b:
                return b
        except Exception as e:
            print('  联网失败（第 %d 次）：%s' % (k + 1, e))
        time.sleep(2 + 3 * k)
    sys.exit('edge-tts 合成失败，检查网络后重跑')


os.makedirs(OUT, exist_ok=True)
lines = ['段  时长    文件 / 字幕文字']
total = 0.0
only = sys.argv[1:]
for name, say, show in N:
    path = os.path.join(OUT, name + '.mp3')
    if only and name not in only:
        mp3 = open(path, 'rb').read()
    else:
        mp3 = tts(say)
        open(path, 'wb').write(mp3)
    dur = miniaudio.decode(mp3).duration
    total += dur
    lines.append('%-14s %5.1f 秒  %s' % (name, dur, show))
    print(lines[-1])
lines.append('合计 %.1f 秒（音色 %s，语速 %s）' % (total, VOICE, RATE))
open(os.path.join(OUT, '配音清单.txt'), 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print(lines[-1])
