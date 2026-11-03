#!/usr/bin/env bash
# R12 拷卡后自查：逐个文件和电脑里的原文件比 md5（10-30 发现旧卡数据有单比特翻转，急救语音出电音）
#   用法：bash tools/verify_card.sh <TF 卡盘符目录> [原文件目录]
#     bash tools/verify_card.sh /g                          默认和 out/test_card_r12 比
#     bash tools/verify_card.sh /g out/test_card_r12_shoot  拍摄卡（位置条「待设置」）
#   要先把卡「弹出」再重新插上，再跑本脚本（否则读到的是 Windows 缓存，不是卡上真实数据）。
#   拷卡顺序（扫描器只读根目录第 1 扇区）：格式化 FAT32（分配单元 32KB）后按 PIC1 PIC2 PIC3 PIC4 PIC6 MUSIC GUIDE SAVE 的顺序一个一个拷
cd "$(dirname "$0")/.."
CARD=${1:?用法：bash tools/verify_card.sh /g [out/test_card_r12]}
SRC=${2:-out/test_card_r12}
bad=0
for f in PIC1.BMP PIC2.BMP PIC3.BMP PIC4.BMP PIC6.BMP MUSIC.WAV GUIDE.WAV SAVE.BIN; do
    if [ ! -f "$SRC/$f" ]; then continue; fi
    if [ ! -f "$CARD/$f" ]; then echo "✗ 卡上没有 $f"; bad=1; continue; fi
    a=$(md5sum < "$SRC/$f" | cut -c1-32); b=$(md5sum < "$CARD/$f" | cut -c1-32)
    if [ "$a" = "$b" ]; then echo "✓ $f"; else echo "✗ $f 内容和原文件不一样（卡坏了或没拷完，换卡重拷）"; bad=1; fi
done
extra=$(ls "$CARD" | grep -v -E '^(PIC[1-6]\.BMP|MUSIC\.WAV|GUIDE\.WAV|SAVE\.BIN|System Volume Information)$' || true)
[ -n "$extra" ] && echo "提示：卡上还有别的文件（建议删掉，免得占根目录前 16 项）：$extra"
# SAVE.BIN 会被板子改写（设置 / 位置条），上过板之后不一样是正常的
[ $bad = 0 ] && echo "== 全部一致，可以上板 ==" || echo "== 有问题，见上面 ✗ =="
exit $bad
