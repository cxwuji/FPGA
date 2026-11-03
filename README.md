# 救在身边——急救指导多媒体屏

基于安路 **EG4S20BG256（HX4S20C 开发板）** 的 HDMI 多媒体播放系统，2026 全国大学生嵌入式芯片与系统设计竞赛 FPGA 赛道 · 安路选题一作品。
全部功能由 FPGA 逻辑实现，不使用任何处理器或软核。

平时它是商场 AED 旁的一块广告屏：从 TF 卡读取 BMP 图片和 WAV 音乐，经片内 SDRAM 帧缓存输出 640×480 HDMI 画面和 48 kHz 声音。
有人突发心脏骤停时，路人按下急救键（K4），屏幕立即变成急救指导：按「判断呼救 → 心肺复苏 → 使用 AED → 交接 120」分步引导，
硬件以 110 次/分打节拍并语音逐次报数，叠加 AED 位置条和《民法典》第 184 条免责提示。

## 功能

| 类别 | 内容 |
|---|---|
| 基础 | TF 卡 FAT32 扫描、BMP 解析、SDRAM 帧缓存、640×480 HDMI 输出；按键翻图 / 自动轮播（1~15 秒 6 档）；48 kHz / 16 位 WAV 经 HDMI 播放，无缝循环、音量斜坡；Flash 固化上电自动运行 |
| 扩展 1 图层与字幕 | 台标 / 字幕 / 频谱三图层，11 档透明度、层序、弹跳 / 滚动；自建 16×16 中文字库（336 个汉字）OSD；电脑经串口下发任意中文字幕 |
| 扩展 2 转场 | 16 种（淡入淡出、四向擦除、圆形扩散 / 收缩、菱形、横 / 竖百叶窗、棋盘格、随机溶解、马赛克、硬切、**向左 / 向上无黑场推移**），8 档速度，固定 / 随机 / 轮换 |
| 扩展 3 缩放 | 8×8~1920×1920 任意分辨率加载时缩放到 640×480：缩小面积平均、放大双线性；实时横 / 纵缩放 0.25~4 倍、镜像、翻转、平移 |
| 扩展 4 调节与 OSD | 亮度 / 对比度 / 色彩 / 字幕颜色实时调节，状态栏显示；设置带校验写回 TF 卡 SAVE.BIN，掉电不丢 |
| 扩展 5 音频可视化 | 512 点定点 FFT，32 柱 mel 刻度频谱，快升慢落 + 顶帽 |
| 急救指导 | 四步流程、110 次/分无累计误差节拍、43 段语音排程、人工呼吸提示音、每 2 分钟换人提示、AED 位置条（串口写入并保存）、交接页 |
| 可靠性 | 扇区 CRC16 校验 + 出错重读、TF 卡热插拔自动恢复、中文故障提示、无卡也能急救 |

资源（布局布线后）：LUT 16276 / 19600（83.0%），寄存器 56.8%，BRAM9K 56 / 64，DSP 24 / 29；5 个时钟域内部时序余量全部为正。

## 目录

```
bit/            直接下载用的 bit 文件（v0.51-r12d）
tf_card/        TF 卡文件：PIC1~4.BMP 轮播、PIC6.BMP 急救图、GUIDE.WAV 急救语音、SAVE.BIN 设置（MUSIC.WAV 未公开，见 MUSIC_说明.txt）
src/td_project/ TD 6.2.1 工程（lab_ex5_i2s_v1.0.al）与 PLL IP
src/user_source/
  constraints_source/   管脚 pin.adc、时序 timing.sdc
  hdl_source/           Verilog 源码（顶层 top_tf_hdmi_audio.v）
    SD/        TF 卡 SPI 读写、扇区重放缓冲、FAT32、BMP 解析与缩放、加载调度
    memory/    帧加载 / 读帧器、写 CDC、视频管线、转场引擎
    display/   图层合成、FFT 频谱、中文 OSD、急救叠加、亮度对比度
    io/        按键路由、设置菜单与文字生成、急救流程、语音排程、串口、故障监测
    audio/     WAV 流播放、提示音合成
    hdmi_audio/ HDMI 数据岛（音频采样包 / ACR / InfoFrame）与 TMDS 编码
    include/   SDRAM 控制器（官方加密 IP）、文字 / 字库宏、频谱表
    IP/        PLL、异步 FIFO（TD IP 生成）
sim/            iverilog 测试平台（tb_*.v）与运行脚本（run_*.sh）
tools/          编译脚本 build.sh、字库 / 存档 / 音频 / 串口等电脑端工具
doc/            技术文档
编译.bat        双击编译（调用 tools/build.sh）
```

## 快速上手

1. **下载程序**：TD 6.2.1 → Tools → Download → Add `bit/v0.51-r12d.bit` → JTAG（临时）或 PROGRAM FLASH（固化，上电自动运行）。
2. **做 TF 卡**：格式化为 FAT32（分配单元 32 KB），**按顺序**拷入 `tf_card/` 里的文件：
   `PIC1.BMP → PIC2.BMP → PIC3.BMP → PIC4.BMP → PIC6.BMP → MUSIC.WAV → GUIDE.WAV → SAVE.BIN`
   （扫描器只看根目录前 16 项，WAV 必须连续存放，所以要先格式化再按顺序拷；拷完可以用 `bash tools/verify_card.sh /盘符 tf_card` 比对 md5。）
3. **接线**：HDMI 线接板子 **HDMI_B** 口到带喇叭的显示器 / 电视；Type-C 口供电（同时是 CH340 串口）。
4. 上电：屏幕正中黄框「正在读取图片 n/5」，几秒后开始显示。SW4 拨上播放背景音乐。

### 按键

| 键 | 播放模式（SW1 拨下） | 设置模式（SW1 拨上） | 急救中 |
|---|---|---|---|
| K1 | 单击：自动轮播开 / 关；按住 1 秒：频谱开 / 关 | 显示页：亮度，按住 3 秒恢复默认；转场页：预览当前效果 | 单击：重播本步；按住 1 秒：语音静音 |
| K2 | 单击：下一张；按住 1 秒：上一张 | 显示页：对比度；其余页：下一项 / 上一项 | 30:2 ⇄ 单纯按压 |
| K3 | 单击：字幕开 / 关；按住 1 秒：状态栏开 / 关 | 显示页：色彩；其余页：加 / 执行 | 下一步 |
| K4 | 单击：**进入急救**；按住 1 秒：2×2 缩略图 | 显示页：字幕颜色，按住 1 秒轮播间隔；其余页：减 | 按住 2 秒：取消 / 交接 / 回广告 |

拨码：SW1 = 设置模式；SW3 SW2 = 页（00 显示 / 01 转场 / 10 图层 / 11 画面与声音）；SW4 = 背景音乐。

## 更换素材

- **背景音乐**：任意 WAV（8/16/24/32 位、任意采样率和声道）转换成板子要的 48 kHz / 16 位 / 单声道，
  `python -I tools/make_music_wav.py 你的音乐.wav MUSIC.WAV [最长秒数]`，
  MP3 等格式先用任意软件导出成 WAV。替换 TF 卡上的 MUSIC.WAV 时要重新格式化、按上面的顺序重拷（文件必须连续存放）。
- **图片**：24 位 BMP，宽高 8~1920，任意分辨率都会自动缩放居中；文件名 PIC1~PIC4.BMP（轮播）、PIC6.BMP（急救图，三栏版面）。
- **字幕**：板上片内字幕在 `tools/gen_cn_font.py` 的 SUB1~SUB4 里改，`python -I tools/gen_cn_font.py` 重新生成后编译；
  不改程序的话用串口：`python -I tools/uart_subtitle.py --text "今日店庆 全场八折" --color 黄 --motion 滚动`
  （`--restore` 恢复片内字幕；`--loc "当前位置：…  AED：…"` 改急救位置条并存进 TF 卡；`--hex` 生成给通用串口助手的 HEX）。
- **设置文件**：`python -I tools/make_save.py --show SAVE.BIN` 查看，`python -I tools/make_save.py SAVE.BIN bri=2 con=3 sat=3 vol=4 …` 生成（不带选项 = 上电默认值）。
- **急救语音**：`python -I tools/make_guide_wav.py GUIDE.WAV`（edge-tts 合成 43 段，`--offline` 用 Windows 自带 TTS）。

## 编译

需要 TD 6.2.1（默认装在 `C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116`，装在别处时用 `TD_BIN=/d/…/bin bash tools/build.sh` 指定）和 Git Bash。
**先关掉 TD 图形界面**，在工程根目录运行：

```bash
bash tools/build.sh v0.51          # 综合 + 多种子并行布局布线 + 时序自动验收，通过后输出 out/v0.51.bit
SEEDS="7 2" bash tools/build.sh    # 指定布局种子
```

也可以双击 `编译.bat`。验收条件：每个时钟域内部 setup / hold 余量都 ≥ 0（时序较紧，脚本会依次试多个种子）。

## 仿真

需要 Icarus Verilog（`iverilog` / `vvp` 在 PATH 里）。在工程根目录：

| 脚本 | 内容 |
|---|---|
| `bash sim/run_fourbank.sh [MISSING3 / MISSING6 / NOCARD / FADE16 / TOPDOWN / SAVE / SAVEBAD]` | 系统级：SD 卡与 FAT32 模型 → 加载 → SDRAM → 视频管线逐像素；切图、缩略图、急救流程、菜单、拔卡恢复、存档读写 |
| `bash sim/run_bmp_scaler.sh` | 20 种分辨率与 Python 参考模型逐像素对照（先 `python -I tools/scaler_ref.py` 生成用例） |
| `bash sim/run_transition.sh` | 16 种转场 |
| `bash sim/run_layers.sh` / `run_layer_eq.sh` | 图层合成整帧逐像素 / 新旧版本等价 |
| `bash sim/run_menu_osd.sh` / `run_emg_view.sh` | 中文 OSD、急救画面整帧（截图 sim/*.ppm） |
| `bash sim/run_spectrum.sh` | FFT 频谱（与浮点 DFT 对照） |
| `bash sim/run_uart_sub.sh` | 串口字幕（真实 115200 波特率） |
| `bash sim/run_guide.sh` / `run_cue_tone.sh` | 急救时间轴与语音排程 / 提示音 |
| `bash sim/run_wav_loop.sh` / `run_bc_sat.sh` / `run_acr.sh` | WAV 循环、色彩调节、HDMI ACR 包 |

每个脚本最后打印 `RESULT: PASS` / `FAIL`。系统级仿真较慢（MAIN 数小时），可以多个变体并行跑。

## 说明

- SD 卡 SPI 读写、HDMI 10:1 串化在安路官方例程基础上修改；SDRAM 控制器（`include/sdr_*.enc.v`）、PLL、异步 FIFO 为安路官方 IP。
- 背景音乐 MUSIC.WAV 仅用于演示，版权归原作者；急救语音由 TTS 合成。
