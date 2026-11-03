#!/bin/bash
# R1.5b 中文 OSD 自检：bash sim/run_menu_osd.sh
cd "$(dirname "$0")/.."
export PATH=/f/intelFPGA/iverilog/bin:$PATH
S=src/user_source/hdl_source
iverilog -g2005 -Isrc/td_project -o sim/tb_menu_osd.vvp sim/tb_menu_osd.v $S/io/page_menu_ctrl.v $S/io/text_rom.v $S/io/key_repeat.v $S/reset_sync.v \
    $S/display/cn_text_overlay.v || exit 1
vvp -n sim/tb_menu_osd.vvp
