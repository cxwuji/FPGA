#!/bin/bash
# R8-3 频谱自检：bash sim/run_spectrum.sh
cd "$(dirname "$0")/.."
export PATH=/f/intelFPGA/iverilog/bin:$PATH
S=src/user_source/hdl_source
iverilog -g2005 -Isrc/td_project -o sim/tb_spectrum.vvp sim/tb_spectrum.v $S/display/audio_spectrum.v || exit 1
vvp -n sim/tb_spectrum.vvp
