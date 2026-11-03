#!/bin/bash
# R3 Í¼²ãºÏ³É×Ô¼ì£ºbash sim/run_layers.sh
cd "$(dirname "$0")/.."
export PATH=/f/intelFPGA/iverilog/bin:$PATH
S=src/user_source/hdl_source
iverilog -g2005 -Isrc/td_project -o sim/tb_layers.vvp sim/tb_layers.v $S/display/layer_compositor.v $S/display/audio_spectrum.v $S/display/cn_text_overlay.v     $S/io/page_menu_ctrl.v $S/io/text_rom.v $S/io/key_repeat.v $S/reset_sync.v || exit 1
vvp -n sim/tb_layers.vvp
