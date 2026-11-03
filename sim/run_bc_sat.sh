#!/bin/bash
# R8-2 色彩（饱和度）自检：bash sim/run_bc_sat.sh
cd "$(dirname "$0")/.."
export PATH=/f/intelFPGA/iverilog/bin:$PATH
S=src/user_source/hdl_source
iverilog -g2005 -o sim/tb_bc_sat.vvp sim/tb_bc_sat.v $S/display/brightness_contrast_adjust.v || exit 1
vvp -n sim/tb_bc_sat.vvp
