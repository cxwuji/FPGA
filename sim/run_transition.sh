#!/bin/bash
# R2 转场引擎自检：bash sim/run_transition.sh
cd "$(dirname "$0")/.."
export PATH=/f/intelFPGA/iverilog/bin:$PATH
S=src/user_source/hdl_source
iverilog -g2005 -o sim/tb_transition.vvp sim/tb_transition.v $S/memory/transition_engine.v || exit 1
vvp -n sim/tb_transition.vvp
