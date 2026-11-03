@echo off
chcp 65001 >nul
rem 双击运行：编译工程并做时序验收，合格的 bit 输出到 out\ 目录
rem 运行前请先关闭 TD 图形界面（它开着同一个工程时会和编译抢文件，导致卡住）
cd /d "%~dp0"
echo 给这次的 bit 起个名字（例如 v0.18-beat，直接回车 = 只用 git 版本号命名）：
set /p NAME=名字：
echo 编译前先跑仿真回归吗？（多约 15 分钟）
set /p RUNSIM=输入 y 跑仿真，直接回车跳过：
set SIM=0
if /i "%RUNSIM%"=="y" set SIM=1
"F:/Program Files/Git/bin/bash.exe" tools/build.sh %NAME%
echo.
echo ===== 编译结束，按任意键关闭窗口 =====
pause >nul
