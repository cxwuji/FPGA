#!/bin/bash
# R8-1c 串口换字幕自检：bash sim/run_uart_sub.sh
cd "$(dirname "$0")/.."
export PATH=/f/intelFPGA/iverilog/bin:$PATH
S=src/user_source/hdl_source
iverilog -g2005 -Isrc/td_project -o sim/tb_uart_sub.vvp sim/tb_uart_sub.v $S/io/uart_subtitle.v $S/display/layer_compositor.v $S/display/audio_spectrum.v $S/display/cn_text_overlay.v \
    $S/io/page_menu_ctrl.v $S/io/text_rom.v $S/io/key_repeat.v $S/reset_sync.v || exit 1
vvp -n sim/tb_uart_sub.vvp
