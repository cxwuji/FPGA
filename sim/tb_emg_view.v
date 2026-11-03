`timescale 1ns/1ps
// R9 急救画面截图：真实 PIC6（sim/emg_bg.hex，由 out/cards/final/PIC6.BMP 转出）-> emg_overlay（进度框 / 位置条 / 民法典角标）
//   -> cn_text_overlay（状态栏 / 右上要点 / 底栏口令，文字由 page_menu_ctrl 按急救状态生成），640x480@60 真实时序整帧输出 PPM。
//   E1 ① 9 秒 看胸口倒数 3   E2 ② 按压 17/30（角标脉动最大）   E3 ② 人工呼吸 1/2   E4 ② 人工呼吸 + 两分钟换人（正中黄框）   E5 ③ AED   E6 交接页
//   R11：E7 ① 0 秒 这里有人晕倒了   E8 ① 25 秒 下面进行CPR + 正中黄框「准备好后按K3开始按压」   E9 ② 9 秒 开始按压
//   R12：E4 计时 02:00 换人；E10 ③ AED 时 04:00 换人（正中黄框）；E11 开机读图黄框「正在读取图片 2/5」（待机，不是红色故障条）
//   另外做几项自动检查：进度框在对的栏、位置条有黄字、角标脉动时变大、交接页没有进度框、正中黄框只在 E4 / E8 出现。
// 运行（仓库根目录）：bash sim/run_emg_view.sh（截图 sim/emg_*.ppm，tools 里转 png 看）
`define TEXT_ROM_HEX "src/user_source/hdl_source/io/text_rom.hex"
`define CN_FONT_HEX "src/user_source/hdl_source/display/cn_font16.hex"
`define BADGE_HEX "src/user_source/hdl_source/display/badge_rom.hex"
`define LOC_HEX "src/user_source/hdl_source/display/loc_default.hex"
module tb_emg_view;
reg sd_clk = 1'b0;  always #5  sd_clk  = ~sd_clk;    // 100MHz
reg pix_clk = 1'b0; always #20 pix_clk = ~pix_clk;   // 25MHz
reg rst_n = 1'b0;
// 急救状态（直接给 page_menu_ctrl，等于 cpr_flow_ctrl 的输出）
reg [2:0]  st = 3'd0;
reg [3:0]  brs = 4'd0;
reg [6:0]  ssec = 7'd0;
reg        swp = 0, intro = 0, full = 0, br = 0, m302 = 1, aseen = 0;
reg [4:0]  cyc = 5'd0;
reg [7:0]  grp = 8'h01;
reg [15:0] tmr = 16'h0000, cmp = 16'h0000, aedt = 16'h0000;
reg [1:0]  part = 2'd0;
reg [3:0]  fc = 4'd0;
reg [2:0]  fa = 3'd0, ft = 3'd0;
reg        beat_tg = 1'b0;
wire act = (st != 3'd0);
wire stat_on, menu_disp, fshow, nshow, visible, hint_show, hint_leave, we;
wire [7:0] wa;
wire [10:0] wd;
page_menu_ctrl #(.CLKS_PER_MS(100)) u_menu (
    .clk(sd_clk), .rst_n(rst_n), .enable_in(!act), .page_in(2'd0),
    .k2_click_in(1'b0), .k2_hold_in(1'b0), .k3_n(1'b1), .k4_n(1'b1),
    .setup_on(1'b0), .raw_page(2'd0), .auto_on(1'b0), .music_on(1'b0),
    .bri_in(8'd255), .con_in(8'd128), .thumb_in(1'b0), .cur_idx_in(3'd0), .cur_wh_in(22'd0), .img_cnt_in(3'd5),
    .cpr_st_in(st), .cpr_302_in(m302), .cpr_breath_in(br), .cpr_cyc_in(cyc),
    .cpr_ssec_in(ssec), .cpr_brs_in(brs), .cpr_swap_in(swp), .cpr_intro_in(intro), .cpr_full_in(full),
    .cpr_grp_in(grp), .cpr_voice_in(2'b00),
    .cpr_tmr_in(tmr), .cpr_cmp_in(cmp), .cpr_aed_in(aedt), .cpr_aseen_in(aseen),
    .next_hint(1'b0), .prev_hint(1'b0), .eff_hint(1'b0), .eff_hint_id(4'd0), .demo_hint(1'b0), .demo_id(3'd0),
    .fault_code(fc), .fault_arg(fa), .fault_tot(ft), .tfok_hint(1'b0), .fault_show(fshow), .note_show(nshow),
    .sat_in(2'd2), .scol_in(3'd0), .int_in(3'd1), .sub_tog(1'b0), .stat_tog(1'b0),
    .sub_upd(1'b0), .sub_rst(1'b0), .sub_show(1'b0), .sub_mot(2'd0),
    .save_ld(1'b0), .save_in(48'd0), .fac_rst(1'b0), .wfail_hint(1'b0), .last_hint(1'b0), .last_in(32'd0),
    .visible(visible), .stat_on(stat_on), .menu_disp(menu_disp), .hint_show(hint_show), .hint_leave(hint_leave),
    .txt_we(we), .txt_addr(wa), .txt_data(wd),
    .vol_gain(), .vw_viz(),
    .fx_effect(), .fx_speed(), .fx_mode(), .fx_demo(), .fx_preview(),
    .ly_sel(), .ly_show(), .ly_x(), .ly_y(), .ly_alpha(), .ly_z(), .ly_motion(),
    .vw_sx(), .vw_sy(), .vw_mirror(), .vw_flip(), .vw_panx(), .vw_pany(),
    .vw_kenburns(), .vw_volume()
);
// 640x480@60
reg [9:0] hc = 0, vc = 0;
always @(posedge pix_clk) begin
    if (hc == 799) begin hc <= 0; vc <= (vc == 524) ? 0 : vc + 1; end
    else hc <= hc + 1;
end
wire de = (hc < 640) && (vc < 480);
wire vs = !((vc >= 490) && (vc < 492));
reg de_d = 0; reg [9:0] hcnt = 0;
wire de_rise = de & ~de_d;
wire [9:0] video_x = de_rise ? 10'd0 : hcnt;
always @(posedge pix_clk) begin
    de_d <= de;
    if (de_rise) hcnt <= 10'd1; else if (hcnt == 10'd799) hcnt <= 10'd0; else hcnt <= hcnt + 10'd1;
end
reg [23:0] bgm [0:307199];
initial $readmemh("sim/emg_bg.hex", bgm);
wire [23:0] bg = de ? bgm[vc * 640 + hc] : 24'd0;
wire [23:0] e_rgb, rgb;
emg_overlay u_emg (
    .clk(pix_clk), .rst_n(rst_n), .vsync(vs), .de(de), .pixel_x(video_x), .rgb_in(bg), .rgb_out(e_rgb),
    .en_async(act), .part_async(part), .beat_tog(beat_tg),
    .wclk(sd_clk), .loc_we(1'b0), .loc_addr(10'd0), .loc_data(8'd0), .loc_ra(10'd0), .loc_q()
);
cn_text_overlay u_cn (
    .clk(pix_clk), .rst_n(rst_n), .vsync(vs), .de(de), .rgb_in(e_rgb), .pixel_x(video_x),
    .wclk(sd_clk), .we(we), .waddr(wa), .wdata(wd),
    .menu_vis_async(visible), .hint_show_async(hint_show), .hint_leave_async(hint_leave), .cpr_async(act), .fault_show_async(fshow),
    .stat_on_async(stat_on), .menu_disp_async(menu_disp), .note_show_async(nshow),
    .fb_addr(14'd0), .fb_q(),
    .rgb_out(rgb)
);
// ---- 截图 + 统计 ----
integer fd, errors = 0;
integer n_frame_red, n_frame_out, n_loc_yel, n_note, badge_w, bx_min, bx_max;
reg capture = 0;
function [7:0] nz(input [7:0] v); nz = (v == 8'd0) ? 8'd1 : v; endfunction
always @(posedge pix_clk) begin
    if (capture && de) begin
        $fwrite(fd, "%c%c%c", nz(rgb[23:16]), nz(rgb[15:8]), nz(rgb[7:0]));   // iverilog 的 %c 写不出 0 字节，0 记成 1
        if (e_rgb == 24'hb00000) begin
            if (vc >= 83 && vc <= 394) n_frame_red = n_frame_red + 1;
            if (part == 2'd1 && hc > 192) n_frame_out = n_frame_out + 1;
            if (part == 2'd2 && (hc < 193 || hc > 434)) n_frame_out = n_frame_out + 1;
            if (part == 2'd3 && hc < 434) n_frame_out = n_frame_out + 1;
        end
        if (vc >= 53 && vc < 69 && hc >= 228 && hc < 632 && e_rgb == 24'hffd040) n_loc_yel = n_loc_yel + 1;
        if (vc >= 218 && vc < 262 && hc >= 116 && hc < 524 && rgb == 24'hffd040) n_note = n_note + 1;   // R11 正中黄框（黄边 + 黄字）
        if (vc == 409 && u_emg.r2_b) begin                     // 角标自己的像素（背景里也有同样的深青色，不能按颜色认）
            if (hc < bx_min) bx_min = hc;
            if (hc > bx_max) bx_max = hc;
        end
    end
end
task next_frame_start;
    begin @(posedge pix_clk); while (!(vc == 0 && hc == 0)) @(posedge pix_clk); end
endtask
task shot(input integer n);
    reg [8*24-1:0] fname;
    begin
        next_frame_start;                  // 文字 RAM 每 1024 拍刷新，跨域 + 帧锁存再等一帧
        $sformat(fname, "sim/emg_%0d.ppm", n);
        fd = $fopen(fname, "wb");
        $fwrite(fd, "P6\n640 480\n255\n");
        n_frame_red = 0; n_frame_out = 0; n_loc_yel = 0; n_note = 0; bx_min = 9999; bx_max = 0;
        capture = 1;
        @(posedge pix_clk); while (!(vc == 480 && hc == 0)) @(posedge pix_clk);
        capture = 0;
        $fclose(fd);
        badge_w = bx_max - bx_min + 1;
        $display("  截图 sim/emg_%0d.ppm：进度框红点 %0d（框外 %0d），位置条黄点 %0d，正中黄框黄点 %0d，角标宽 %0d", n, n_frame_red, n_frame_out, n_loc_yel, n_note, badge_w);
    end
endtask
task check(input ok, input [1023:0] what);
    begin
        if (ok) $display("  ok   %0s", what);
        else begin $display("  FAIL %0s", what); errors = errors + 1; end
    end
endtask
task beat; begin @(posedge sd_clk) beat_tg = ~beat_tg; end endtask
integer w_small;
initial begin
    #200 rst_n = 1'b1;
    repeat (2) next_frame_start;
    // E7 ① 0 秒：这里有人晕倒了
    st = 3'd1; part = 2'd1; ssec = 7'd0; tmr = 16'h0000;
    force u_emg.lvl = 3'd0;                         // 角标原大小（不等它自己跳完一轮，省仿真时间）
    shot(7);
    check(n_note == 0, "E7 part 1 at 0 s: no centre note");
    // E1 ① 9 秒：看胸口起伏 3
    ssec = 7'd9; tmr = 16'h0009;
    shot(1);
    release u_emg.lvl;
    check(n_frame_red > 1500 && n_frame_out == 0 && n_loc_yel > 800 && n_note == 0, "E1 part 1: progress frame on column 1 only, location bar text shown");
    w_small = badge_w;
    // E8 ① 25 秒：讲完，正中黄框等 K3
    force u_emg.lvl = 3'd0;
    ssec = 7'd25; tmr = 16'h0025;
    shot(8);
    release u_emg.lvl;
    check(n_note > 1500 && !fshow, "E8 part 1 after 20 s: centre note 准备好后按K3开始按压 (yellow, not the fault bar)");
    // E9 ② 第一次进入 9 秒：开始按压
    st = 3'd2; part = 2'd2; ssec = 7'd9; intro = 1; full = 1; cyc = 5'd0; tmr = 16'h0040;
    shot(9);
    check(n_note == 0, "E9 part 2 intro: centre note gone");
    full = 0;
    // E2 ② 按压第 17 下，节拍刚到（角标最大）
    st = 3'd2; part = 2'd2; ssec = 7'd40; intro = 0; cyc = 5'd17; grp = 8'h03; tmr = 16'h0125; cmp = 16'h0077;
    repeat (2) next_frame_start;
    beat; next_frame_start;                         // 下一帧起 lvl = 4 -> 6 -> 7（最大）
    fd = 0;
    @(posedge pix_clk); while (!(vc == 479 && hc == 0)) @(posedge pix_clk);   // shot 里再等 2 帧：正好落在最大档附近
    shot(2);
    check(n_frame_out == 0 && n_frame_red > 1500, "E2 part 2: progress frame on column 2 only");
    check(badge_w > w_small + 30 && w_small >= 340 && w_small <= 360, "E2 badge pulses bigger on the beat (1.00 -> ~1.15)");
    // E3 人工呼吸第 1 口
    br = 1; brs = 4'd1; cyc = 5'd30; cmp = 16'h0090;
    shot(3);
    check(n_note == 0, "E3 breaths without swap: no centre note");
    // E4 满两分钟：人工呼吸里显示换人
    swp = 1; brs = 4'd6; grp = 8'h05; cmp = 16'h0150; tmr = 16'h0200;
    shot(4);
    check(n_note > 1500, "E4 swap: centre note 到了两分钟，建议换人");
    // E5 ③ AED
    st = 3'd3; part = 2'd3; br = 0; swp = 0; ssec = 7'd1; aseen = 1; aedt = 16'h0230; tmr = 16'h0231; cyc = 5'd0;
    shot(5);
    check(n_frame_out == 0 && n_frame_red > 1500 && n_note == 0, "E5 part 3: progress frame on column 3 only, no centre note");
    // E10 R12：③ AED 分析时到 04:00，也提示换人
    swp = 1; tmr = 16'h0400; ssec = 7'd20;
    shot(10);
    check(n_frame_out == 0 && n_note > 1500, "E10 part 3 at 04:00: centre note 到了两分钟，建议换人 during AED");
    swp = 0;
    // E6 交接页
    st = 3'd4; part = 2'd0; tmr = 16'h0845; cmp = 16'h0512;
    shot(6);
    check(n_frame_red == 0 && n_loc_yel > 800, "E6 summary: no progress frame, location bar still shown");
    // E11 R12：开机读图（待机、还没出图）：正中黄框「正在读取图片 2/5」
    st = 3'd0; part = 2'd0; fc = 4'd14; fa = 3'd1; ft = 3'd5;
    repeat (2) next_frame_start;
    shot(11);
    check(n_note > 1500 && !fshow && nshow, "E11 boot loading: yellow centre note 正在读取图片 2/5 (not the red fault bar)");
    $display("RESULT: %0s（%0d 个失败）", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
end
endmodule
