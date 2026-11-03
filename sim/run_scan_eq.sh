#!/bin/bash
# R9：扫描器新旧版等价检查。bash sim/run_scan_eq.sh [旧版 git 提交，默认 bd7f1ff]
cd "$(dirname "$0")/.."
export PATH=/f/intelFPGA/iverilog/bin:$PATH
S=src/user_source/hdl_source
OLD=sim/scan_old.v
git show ${1:-bd7f1ff}:$S/SD/fat32_volume_scanner.v | sed 's/^module fat32_volume_scanner\b/module fat32_volume_scanner_old/' > $OLD || exit 1
for v in "" VB; do
    iverilog -g2005 ${v:+-D$v} -o sim/tb_scan_eq.vvp sim/tb_scan_eq.v $S/SD/fat32_volume_scanner.v $OLD || exit 1
    echo "== 变体 ${v:-VA}"
    vvp -n sim/tb_scan_eq.vvp
done
