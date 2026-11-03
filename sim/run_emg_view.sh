#!/bin/bash
# R9 急救画面截图（PIC6 + emg_overlay + cn_text_overlay），约 10 分钟：bash sim/run_emg_view.sh
cd "$(dirname "$0")/.."
export PATH=/f/intelFPGA/iverilog/bin:$PATH
S=src/user_source/hdl_source
iverilog -g2005 -Isrc/td_project -o sim/tb_emg_view.vvp sim/tb_emg_view.v $S/io/page_menu_ctrl.v $S/io/text_rom.v $S/io/key_repeat.v $S/reset_sync.v \
    $S/display/cn_text_overlay.v $S/display/emg_overlay.v || exit 1
vvp -n sim/tb_emg_view.vvp
