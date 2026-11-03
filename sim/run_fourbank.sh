#!/bin/bash
# 第8课 四 bank 帧缓存仿真：bash sim/run_fourbank.sh [MISSING3 | MISSING6 | FADE16 | NOCARD | TOPDOWN]
cd "$(dirname "$0")/.."
export PATH=/f/intelFPGA/iverilog/bin:$PATH
S=src/user_source/hdl_source
iverilog -g2005 -Isrc/td_project ${1:+-D$1} -o sim/tb_fourbank${1:+_$1}.vvp sim/tb_fourbank.v sim/tb_fourbank_sd.v \
    $S/SD/sd_card_bmp.v $S/SD/bmp_read.v $S/SD/bmp_scaler.v $S/SD/key_click_hold.v \
    $S/SD/fat32_volume_scanner.v $S/SD/fat32_file_streamer.v $S/SD/sd_sector_adapter.v \
    $S/reset_sync.v $S/sync_2ff.v $S/memory/*.v $S/audio/cue_tone_gen.v \
    $S/display/thumbnail_layout.v $S/display/brightness_contrast_adjust.v \
    $S/io/thumbnail_controller.v \
    $S/io/ui_key_router.v $S/io/cpr_flow_ctrl.v $S/io/guide_seq.v $S/io/switch_debounce.v $S/io/key_repeat.v $S/io/page_menu_ctrl.v $S/io/text_rom.v $S/io/tf_fault_monitor.v || exit 1
vvp -n sim/tb_fourbank${1:+_$1}.vvp
