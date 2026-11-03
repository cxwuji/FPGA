#!/bin/bash
# R9 急救语音排程自检（cpr_flow_ctrl + guide_seq），约 10 秒：bash sim/run_guide.sh
cd "$(dirname "$0")/.."
export PATH=/f/intelFPGA/iverilog/bin:$PATH
S=src/user_source/hdl_source
iverilog -g2005 -o sim/tb_guide.vvp sim/tb_guide.v $S/io/cpr_flow_ctrl.v $S/io/guide_seq.v || exit 1
vvp -n sim/tb_guide.vvp
