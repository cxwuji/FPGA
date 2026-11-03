#!/bin/bash
# R12d HDMI 音频时钟再生包（ACR）字节顺序自检：bash sim/run_acr.sh
cd "$(dirname "$0")/.."
export PATH=/f/intelFPGA/iverilog/bin:$PATH
S=src/user_source/hdl_source
iverilog -g2005 -o sim/tb_acr.vvp sim/tb_acr.v $S/hdmi_audio/hdmi_audio_acr_packetizer.v $S/hdmi_audio/hdmi_bch8.v || exit 1
vvp -n sim/tb_acr.vvp
