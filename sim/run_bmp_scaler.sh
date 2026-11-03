#!/bin/bash
# R8-5a 缩放逐像素比对：bash sim/run_bmp_scaler.sh [用例名 ...]（默认全部，用例见 tools/scaler_ref.py 的 CASES）
cd "$(dirname "$0")/.."
export PATH=/f/intelFPGA/iverilog/bin:$PATH
S=src/user_source/hdl_source
python -I tools/scaler_ref.py sim/scaler_cases "$@" > /dev/null || exit 1
iverilog -g2005 -o sim/tb_bmp_scaler.vvp sim/tb_bmp_scaler.v $S/SD/bmp_read.v $S/SD/bmp_scaler.v || exit 1
for f in sim/scaler_cases/*.exp; do
    n=$(basename "$f" .exp)
    if [ $# -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$n"; then continue; fi
    vvp -n sim/tb_bmp_scaler.vvp +CASE=sim/scaler_cases/$n | grep -E "RESULT|MISMATCH"
done
