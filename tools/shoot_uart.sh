#!/usr/bin/env bash
# 拍摄日串口助手（doc/拍摄步骤_v0.51.md）：拍的时候只按回车，不用敲命令。板子 Type-C 串口口要插在电脑上。
#   bash tools/shoot_uart.sh          按顺序 4 步，每步按回车发送：
#                                       [1/4] 换字幕（黄色、静止、居中）  [2/4] 撤销第 1 步
#                                       [3/4] 改急救位置条（板子写进 TF 卡）  [4/4] 位置条复位成「待设置」
#   bash tools/shoot_uart.sh 3        只发第 3 步（重拍某一条时用，1~4 都可以）
#   bash tools/shoot_uart.sh wait     = 只发第 4 步（旧用法）
#   bash tools/shoot_uart.sh pack     不发送，生成给通用串口助手用的 out/拍摄包/串口指令.txt + 串口指令/*.bin
#   找不到串口时：PORT=COM5 bash tools/shoot_uart.sh
# 第 2 步 = 板子「恢复片内字幕」命令（CMD 02）：只撤掉串口点阵，字幕层的 显示 / 运动 不动。
#   所以第 1 步故意发「显示 + 静止」：只要发之前字幕是开着的（K3 单击打开，默认就是静止），
#   第 2 步之后板子就和没发过第 1 步完全一样。第 1 步要是发「滚动」，第 2 步之后片内字幕会接着滚动，撤不干净。
cd "$(dirname "$0")/.."
P=(); [ -n "${PORT:-}" ] && P=(--port "$PORT")
SUB="今日店庆 全场八折   AED 在一楼大厅服务中心"
LOC="当前位置：XX商场二楼手机店  AED：一楼大厅服务中心"
WAIT="当前位置：待设置      AED：待设置"

# 每一步：标题 | 屏幕现象 | uart_subtitle.py 参数
T1="换字幕（黄色、静止、居中，所有图）"; S1="提示「字幕已更新」，底部变成居中的黄字「${SUB}」（发之前先 K3 把字幕打开）"
T2="撤销第 1 步";                       S2="提示「已恢复默认字幕」，底部变回发第 1 步之前的白色片内字幕，和没发过一样"
T3="改急救位置条（写进 TF 卡）";    S3="急救中顶部黄条立刻变成「${LOC}」，断电不丢（平时看不到黄条，要按 K4 进急救才看得到）"
T4="急救位置条复位成「待设置」";    S4="急救中顶部黄条变回「当前位置：待设置  AED：待设置」，也写进 TF 卡"
args() {
    case $1 in
        1) A=(--text "$SUB" --color 黄 --motion 静止 --center) ;;
        2) A=(--restore) ;;
        3) A=(--loc "$LOC") ;;
        4) A=(--loc "$WAIT") ;;
    esac
}
title() { eval "echo \"\$T$1\""; }
scene() { eval "echo \"\$S$1\""; }

send() { PYTHONIOENCODING=utf-8 python -I tools/uart_subtitle.py "$@" "${P[@]}" || { echo "   ✗ 没发成功：检查 Type-C 线、板子是否在运行，再按回车重试"; return 1; }; }
step() {   # 按回车发，发失败可以再按回车重发，输入 n 跳过
    local n=$1 hint=$2; args "$n"
    echo
    echo "[$n/4] $(title "$n")"
    echo "      应出现：$(scene "$n")"
    [ -n "$hint" ] && echo "      什么时候按：$hint"
    while true; do
        read -r -p "      回车 = 发送，n = 跳过 > " k
        [ "$k" = n ] && return
        send "${A[@]}" && return
    done
}

case "${1:-}" in
    1|2|3|4)
        args "$1"; echo "[$1/4] $(title "$1")"; send "${A[@]}"; exit ;;
    wait)
        args 4; echo "[4/4] $(title 4)"; send "${A[@]}"; exit ;;
    pack)
        D=out/拍摄包/串口指令; F=out/拍摄包/串口指令.txt
        mkdir -p "$D"; rm -f "$D"/*.bin "$D"/*.hex.txt
        names=("" "1_换字幕" "2_恢复片内字幕" "3_改位置条" "4_位置条复位")
        {
            printf '\xef\xbb\xbf'
            echo "拍摄用串口指令（v0.51，$(date +%Y-%m-%d) 生成；板子 Type-C 串口口插电脑）"
            echo "================================================================"
            echo "串口助手设置：波特率 115200，数据位 8，停止位 1，无校验；"
            echo "              发送方式选「HEX 发送」，不要勾「加回车换行」/「自动发送」。"
            echo "用法：按顺序发 1 → 2 → 3 → 4。把某一条 ===== 之间的整段 HEX 全选复制，粘贴到发送框，点发送。"
            echo "      板子收到正确的一帧会回 OK（接收区显示 4F 4B 或 OK），错了回 ER，重发一次即可。"
            echo "发不出去 / 没回 OK：检查 COM 口选的是 CH340（USB-SERIAL CH340），等板子出画面后再发。"
            echo "也可以用「发送文件」：同目录 串口指令/ 下的 .bin 文件，效果一样。"
        } > "$F"
        for n in 1 2 3 4; do
            args "$n"; base="$D/${names[$n]}"
            PYTHONIOENCODING=utf-8 python -I tools/uart_subtitle.py "${A[@]}" --hex "$base.hex.txt" > /dev/null || exit 1
            PYTHONIOENCODING=utf-8 python -I tools/uart_subtitle.py "${A[@]}" --bin "$base.bin" > /dev/null || exit 1
            {
                echo
                echo "----------------------------------------------------------------"
                echo "【$n】$(title "$n")"
                echo "     现象：$(scene "$n")"
                echo "====="
                cat "$base.hex.txt"; echo
                echo "====="
            } >> "$F"
        done
        echo "已生成 $F 和 $D/"; ls "$D"; exit ;;
esac

echo "== 拍摄串口助手：4 步，每一步按回车发送 =="
step 1 "Take 2 第 14 步（第 13 步 K3 把字幕打开之后）"
step 2 "Take 2 第 14b 步（黄字停 5 秒之后）"
step 3 "Take 3 第 3 步（K4 进急救、看到「待设置」黄条之后）"
step 4 "Take 4、Take 5 都拍完以后再按（Take 4 主题演示要用真实位置；不想复位就 n）"
echo
echo "== 完成 =="
