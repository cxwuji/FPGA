#!/bin/bash
# R7c-1 提示音（节拍音 / 按键音）自检：bash sim/run_cue_tone.sh
cd "$(dirname "$0")/.."
export PATH=/f/intelFPGA/iverilog/bin:$PATH
S=src/user_source/hdl_source
iverilog -g2005 -o sim/tb_cue_tone.vvp sim/tb_cue_tone.v $S/audio/cue_tone_gen.v || exit 1
vvp -n sim/tb_cue_tone.vvp
