#!/bin/bash
# R1.5a WAV 循环 + 暂停仿真：bash sim/run_wav_loop.sh
cd "$(dirname "$0")/.."
export PATH=/f/intelFPGA/iverilog/bin:$PATH
S=src/user_source/hdl_source
iverilog -g2005 -o sim/tb_wav_loop.vvp sim/tb_wav_loop.v $S/audio/wav_stream_player.v || exit 1
vvp -n sim/tb_wav_loop.vvp
