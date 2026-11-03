#!/usr/bin/env bash
# 命令行编译：综合 -> 布局布线 -> 生成 bit，并做时序验收
# 用法（Git Bash，在工程根目录，或双击 编译.bat）：
#   bash tools/build.sh                 编译，bit 放到 out/<git 版本>.bit
#   bash tools/build.sh v0.18-beat      同上，另外复制一份 out/v0.18-beat.bit（好记的名字，交付 / 上板用这个）
#   SIM=1 bash tools/build.sh v0.18     先跑三套仿真回归（默认 / 缺 PIC3 / 真实转场），全部 PASS 才编译（多约 15 分钟）
#   SEEDS="5 41" bash tools/build.sh    指定布局种子
#   PAR=2 bash tools/build.sh           同时跑几个种子（默认 4；每个约 1.2GB 内存、1.5 个核，内存紧时调小）
#
# 产物：out/<git 版本>.bit  ← 上板只下载这个文件
#   TD GUI 里点编译会覆盖 src/td_project/..._Runs/，但不会碰 out/，所以 out/ 里的 bit 一定是验收过的。
#
# 时序验收：每个时钟域内部（From == To）的 setup 余量都必须 >= 0，hold 也必须 >= 0。
#   官方 SDRAM 写 FIFO（frame_fifo_write.into_burst）和 bmp_read 头校验路径本身只剩约 0.1ns 余量，
#   布局稍有变化就会变负，所以这里依次尝试 SEEDS 里的布局种子，直到通过为止。
#   跨时钟域的负余量（异步 FIFO、同步器、复位释放）不在验收范围，SDC 整理后再收紧。
set -euo pipefail

TD_BIN=${TD_BIN:-/c/Anlogic/TD_6.2.1_Engineer_6.2.168.116/bin}
SEEDS=${SEEDS:-"113 2 7 5 9 13 21 34 63 101 3 17 41 77 88 151"}
PAR=${PAR:-4}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PRJ=lab_ex5_i2s_v1.0
TDP=$ROOT/src/td_project
RUNS=$TDP/${PRJ}_Runs
OUT=$ROOT/out

prepare_run() {   # 由 .al 生成 run 目录下的 .prj（路径相对 run 目录再深两级）
    local r=$1 tpl=${2:-$1}   # tpl = tools/td_flow 下用哪份 settings.cfg（phy_2~4 都用 phy_1 的）
    # 只清空目录内容：目录本身被别的进程当作当前目录时删不掉（会报 Device or resource busy）
    rm -rf "${RUNS:?}/$r"/* "${RUNS:?}/$r"/.[!.]* 2>/dev/null || true
    mkdir -p "$RUNS/$r"
    cp "$ROOT/tools/td_flow/$tpl/settings.cfg" "$RUNS/$r/"
    cp "$TD_BIN/../doc/scripts/DefaultFlow.tcl" "$RUNS/$r/$PRJ.tcl"
    # route 自带的 hold 修复在 slice 占用 > 90% 时会自动跳过（R7c-1 起 91.7%，每个种子都剩几 ps hold 违例），
    # 所以 route 之后显式再跑一次 fix_hold；final_timing.rpt 是 route 里出的（fix_hold 之前），验收改看 _pr.timing
    sed -i 's/^  route$/  route\n  fix_hold/' "$RUNS/$r/$PRJ.tcl"
    sed -e 's|<Project Version="3" Minor="2" Path="[^"]*">|<Project Version="3" Minor="2" RunTime="">|' \
        -e 's|Path="\.\./|Path="../../../|g' \
        -e 's|Path="al_ip/|Path="../../al_ip/|g' \
        "$TDP/$PRJ.al" > "$RUNS/$r/$PRJ.prj"
}

run_step() {   # 第 2 个参数 = soft：出错只返回 1（布局布线某个种子失败 / TD 崩溃时换下一个种子）
    local r=$1 soft=${2:-}
    # stdin 接 /dev/null：td_commands_prompt 跑完脚本后会停在 "td >" 等键盘输入，
    # 双击 编译.bat 时有控制台，不这样做它就永远不退出
    (cd "$RUNS/$r" && "$TD_BIN/td_commands_prompt.exe" "$PRJ.tcl" < /dev/null > console.log 2>&1) || {
        echo "   TD 异常退出（可能崩溃），见 $RUNS/$r/console.log"; grep -m 5 ERROR "$RUNS/$r/console.log" || true
        rm -f "$TDP"/minidump-*.dmp 2>/dev/null
        [ -n "$soft" ] && return 1; exit 1; }
    if grep -q "ERROR" "$RUNS/$r/console.log"; then
        grep -m 5 ERROR "$RUNS/$r/console.log" | sed 's/^/   /'
        [ -n "$soft" ] && return 1; exit 1
    fi
    return 0
}

# 输出每个“时钟域内部”路径组的最差 setup 余量（ns），负数的排在前面
intra_slack() {
    awk '/^Path Group/{f=$4; t=$6} /^Slack *:/{s=$3; sub("ns","",s); if (f==t && f!="") { if(!(f in w) || s+0<w[f]+0) w[f]=s } }
         END{for(k in w) printf "%s %s\n", w[k], k}' "$1" | sort -g
}

NAME=${1:-}
T0=$(date +%s)

if tasklist 2>/dev/null | grep -qi "^td.exe"; then
    echo "!! TD 图形界面开着，请先关掉它再编译（两边会抢同一批文件，编译会卡住）"
    exit 1
fi
# 上次编译中断留下的命令行进程会占住文件
if tasklist 2>/dev/null | grep -qi "^td_commands_prompt"; then
    echo "== 清理上次残留的 td_commands_prompt 进程"
    taskkill //F //IM td_commands_prompt.exe > /dev/null 2>&1 || true
fi

if [ "${SIM:-0}" = "1" ]; then
    echo "== 仿真回归（默认 / MISSING3 / FADE16 / NOCARD，约 15 分钟）"
    for m in "" MISSING3 FADE16 NOCARD; do
        res=$(bash "$ROOT/sim/run_fourbank.sh" $m 2>&1 | grep "RESULT" || true)
        echo "   ${m:-默认}：${res:-（没有输出，编译仿真失败）}"
        case "$res" in *PASS*) ;; *) echo "!! 仿真没通过，不编译"; exit 1;; esac
    done
    res=$(bash "$ROOT/sim/run_menu_osd.sh" 2>&1 | grep "RESULT" || true)
    echo "   OSD 菜单：${res:-（没有输出，编译仿真失败）}"
    case "$res" in *PASS*) ;; *) echo "!! 仿真没通过，不编译"; exit 1;; esac
    res=$(bash "$ROOT/sim/run_transition.sh" 2>&1 | grep "RESULT" || true)
    echo "   转场引擎：${res:-（没有输出，编译仿真失败）}"
    case "$res" in *PASS*) ;; *) echo "!! 仿真没通过，不编译"; exit 1;; esac
    res=$(bash "$ROOT/sim/run_layers.sh" 2>&1 | grep "RESULT" || true)
    echo "   图层合成：${res:-（没有输出，编译仿真失败）}"
    case "$res" in *PASS*) ;; *) echo "!! 仿真没通过，不编译"; exit 1;; esac
    res=$(bash "$ROOT/sim/run_wav_loop.sh" 2>&1 | grep "RESULT" || true)
    echo "   WAV 循环 / 暂停：${res:-（没有输出，编译仿真失败）}"
    case "$res" in *PASS*) ;; *) echo "!! 仿真没通过，不编译"; exit 1;; esac
fi

echo "== syn_1（综合，约 1~2 分钟）"
prepare_run syn_1
# R8-5c：综合映射改面积优先（TD 官方策略 AreaOptimizeHigh 里的 map_mode=area_prior），LUT 86.6% -> 79.1%。
#   SYN_PARAMS="" bash tools/build.sh x 可以退回 TD 默认映射
SYN_PARAMS=${SYN_PARAMS-"gate map_mode area_prior"}
# R8-4b：布局布线额外参数（TD 官方 phy 策略，见 TD 安装目录 doc/strategies/official_strategy_ph1.json），例：
#   PHY_EXTRA="place effort high place logic_level_opt on ..." bash tools/build.sh x
PHY_EXTRA=${PHY_EXTRA-""}
[ -n "$SYN_PARAMS" ] && echo "set synWildParams {$SYN_PARAMS}" >> "$RUNS/syn_1/settings.cfg"
run_step syn_1

# 一个种子跑在 $RUNS/$d（phy_1~phy_N 并排，parent 都是 ../syn_1），结果写进 $d/result：
#   PASS|FAIL|ERR <最差 setup ns> <时钟域> <hold ps>
run_seed() {
    local d=$1 seed=$2 rpt worst hold tag
    prepare_run "$d" phy_1
    echo "set phyWildParams {place seed $seed place opt_timing high route opt_timing high $PHY_EXTRA}" >> "$RUNS/$d/settings.cfg"
    if ! run_step "$d" soft > "$RUNS/$d/step.log" 2>&1; then
        echo "ERR - - -" > "$RUNS/$d/result.tmp"; mv "$RUNS/$d/result.tmp" "$RUNS/$d/result"; return 0
    fi
    rpt=$RUNS/$d/${PRJ}_pr.timing
    worst=$(intra_slack "$rpt" | head -1)
    hold=$(sed -n 's/^Hold *: WNS *\(-\{0,1\}[0-9]*\)ps.*/\1/p' "$RUNS/$d/console.log" | tail -1)
    tag=FAIL
    awk -v w="${worst%% *}" -v h="$hold" 'BEGIN{exit !((w+0)>=0 && (h+0)>=0)}' && tag=PASS
    mkdir -p "$OUT/seeds" && cp "$rpt" "$OUT/seeds/seed$seed.timing.rpt" 2>/dev/null || true   # 每个种子的报告留着，方便看是哪条路径
    echo "$tag ${worst%% *} ${worst#* } $hold" > "$RUNS/$d/result.tmp"
    mv "$RUNS/$d/result.tmp" "$RUNS/$d/result"
}

# 每批同时跑 PAR 个种子；有一个通过就杀掉同批其余的，整批都没过再跑下一批
passed=""; pdir=phy_1
set -- $SEEDS
while [ $# -gt 0 ] && [ -z "$passed" ]; do
    batch=()
    while [ $# -gt 0 ] && [ ${#batch[@]} -lt "$PAR" ]; do batch+=("$1"); shift; done
    echo "== 布局布线 + 生成 bit：同时跑种子 ${batch[*]}（约 7~10 分钟，有一个通过就停）"
    pids=()
    for k in "${!batch[@]}"; do
        rm -f "$RUNS/phy_$((k+1))/result"
        run_seed "phy_$((k+1))" "${batch[$k]}" &
        pids+=($!)
    done
    while :; do
        alive=0
        for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
        for k in "${!batch[@]}"; do
            r=$RUNS/phy_$((k+1))/result
            if [ -z "$passed" ] && [ -f "$r" ] && grep -q '^PASS' "$r"; then passed=${batch[$k]}; pdir=phy_$((k+1)); fi
        done
        if [ -n "$passed" ] || [ "$alive" = 0 ]; then break; fi
        sleep 10
    done
    if [ -n "$passed" ] && [ "$alive" = 1 ]; then
        taskkill //F //IM td_commands_prompt.exe > /dev/null 2>&1 || true
    fi
    wait || true
    for k in "${!batch[@]}"; do
        read -r tag w dom h < "$RUNS/phy_$((k+1))/result" 2>/dev/null || { tag=ERR; w=-; dom=-; h=-; }
        if [ "${batch[$k]}" = "$passed" ]; then tag=PASS
        elif [ -n "$passed" ] && [ "$tag" = ERR ]; then tag=停止; fi
        case $tag in
            PASS) echo "   seed ${batch[$k]}：通过，最差 setup ${w}ns（$dom），hold ${h}ps";;
            FAIL) echo "   seed ${batch[$k]}：未通过，最差 setup ${w}ns（$dom），hold ${h}ps";;
            停止) echo "   seed ${batch[$k]}：已有种子通过，提前停掉";;
            *)    echo "   seed ${batch[$k]}：布线失败或 TD 崩溃（见 $RUNS/phy_$((k+1))/console.log）";;
        esac
    done
done

if [ -z "$passed" ]; then
    echo "!! 所有种子都没通过时序验收（SEEDS=$SEEDS），不要上板。phy_1 各时钟域最差余量："
    intra_slack "$RUNS/phy_1/${PRJ}_pr.timing"
    exit 1
fi

echo "== 时序验收通过（seed $passed），各时钟域内部最差 setup 余量（ns）："
intra_slack "$RUNS/$pdir/${PRJ}_pr.timing" | sed 's/^/   /'
echo "== 资源"
grep -E '^#(lut|reg|bram|pll|dsp) ' "$RUNS/$pdir/${PRJ}_phy.area"

# 只有源码 / 约束 / 工程 / 编译模板改了才算 dirty（doc/ 改动不影响 bit）
ver=$(cd "$ROOT" && git describe --tags --always 2>/dev/null || echo nogit)
if [ -n "$(cd "$ROOT" && git status --porcelain -- src tools/td_flow 2>/dev/null)" ]; then
    ver=$ver-dirty
fi
mkdir -p "$OUT"
cp "$RUNS/$pdir/$PRJ.bit" "$OUT/$ver.bit"
cp "$RUNS/$pdir/${PRJ}_pr.timing" "$OUT/$ver.timing.rpt"
echo "seed=$passed" > "$OUT/$ver.info"
dl=$OUT/$ver.bit
if [ -n "$NAME" ]; then
    for e in bit timing.rpt info; do cp "$OUT/$ver.$e" "$OUT/$NAME.$e"; done
    dl=$OUT/$NAME.bit
fi
echo "== 上板请下载：$(cygpath -w "$dl" 2>/dev/null || echo "$dl")"
case "$ver" in *dirty*) echo "   （注意：src/ 有未提交的改动，这个 bit 对应不到某个提交）";; esac
echo "== 用时 $(( ($(date +%s) - T0) / 60 )) 分 $(( ($(date +%s) - T0) % 60 )) 秒"
echo "   TD -> Tools -> Download -> Add 上面的 bit -> JTAG（调试）或 PROGRAM FLASH（固化）"
