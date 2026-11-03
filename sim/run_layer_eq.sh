#!/bin/bash
# R12b 图层合成改版对照（新 3 级 vs v0.48-r12a 的 4 级原版，逐像素比较），约 15 分钟：bash sim/run_layer_eq.sh
cd "$(dirname "$0")/.."
export PATH=/f/intelFPGA/iverilog/bin:$PATH
S=src/user_source/hdl_source
# 旧版从 git 标签取；没有 git 历史（发布包）时直接用 sim/layer_compositor_old.v
if git rev-parse -q --verify v0.48-r12a >/dev/null 2>&1; then
    git show v0.48-r12a:$S/display/layer_compositor.v | sed 's/^module layer_compositor (/module layer_compositor_old (/' > sim/layer_compositor_old.v || exit 1
fi
[ -f sim/layer_compositor_old.v ] || { echo '缺 sim/layer_compositor_old.v'; exit 1; }
iverilog -g2005 -Isrc/td_project -o sim/tb_layer_eq.vvp sim/tb_layer_eq.v $S/display/layer_compositor.v sim/layer_compositor_old.v $S/display/audio_spectrum.v || exit 1
vvp -n sim/tb_layer_eq.vvp
