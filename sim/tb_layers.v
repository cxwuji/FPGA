`timescale 1ns/1ps
// R3 图层合成自检：page_menu_ctrl（字幕文字写口）+ layer_compositor + cn_text_overlay（借字库第二读口），真实 640x480 时序。
// 测试台独立算每个像素的期望值（台标 ROM / 字库 / 频谱柱高 + 同样的合成公式），整帧逐像素比对：
//   L0 默认：台标 100% 叠在右上；字幕条显示，含第 1 页汉字（检查页号编码）
//   L1 透明度：台标 50%、字幕 80%，逐像素按 16 级 alpha 混合
//   L3 选中框：图层页菜单打开时选中层外的黄色虚线框
//   L4 运动：台标弹跳每帧横移 2 点、竖移 1 点；字幕滚动每帧文字左移 2 点（同时整帧逐像素正确）
//   L9 片内字幕颜色（R8-2 显示页）：字色换成黄色，整帧逐像素
//   L8 频谱（R8-3）：1 kHz 正弦 -> 最高柱在 1 kHz 那根；整帧逐像素（彩虹柱 / 白顶帽 / 柱外透明，按 DUT 的柱高独立算）
//   L2 层序（R12b 重写：原来用画中画）：台标 / 字幕 / 频谱三层叠在一起（透明度各不相同），换 3 种层序（每层在最下 / 中间 / 最上各一次，
//      图层 2 占的那一档放在不同位置），整帧逐像素（R12b 合成改成 3 级、按层序排槽）
//   L8 关：wave_en = 0 时频谱层不画（R10 起 viz 端口不用，开关只看 wave_en），台标 / 字幕照常
//   L5 急救 / 未打开显示：所有图层隐藏
//   去掉的：原 L2 台标 / 画中画层序、L5 画中画抽样（R8-4b 删画中画）；L6 示波器（R8-2 删）；L7 音量表（R10 删波形 / 音量表）
//   串口字幕点阵另有 tb_uart_sub 逐像素检查，这里不重复。
// 运行（仓库根目录）：bash sim/run_layers.sh
`define TEXT_ROM_HEX "src/user_source/hdl_source/io/text_rom.hex"
`define CN_FONT_HEX "src/user_source/hdl_source/display/cn_font16.hex"
`define LOGO_HEX "src/user_source/hdl_source/display/logo_rom.hex"
module tb_layers;
`include "../user_source/hdl_source/include/spectrum_tables.vh"
reg sd_clk = 1'b0;  always #5  sd_clk  = ~sd_clk;
reg pix_clk = 1'b0; always #20 pix_clk = ~pix_clk;
reg rst_n = 1'b0;

wire we; wire [7:0] wa; wire [10:0] wd;
page_menu_ctrl #(.CLKS_PER_MS(100)) u_menu (
    .clk(sd_clk), .rst_n(rst_n), .enable_in(1'b0), .page_in(2'd0),
    .k2_click_in(1'b0), .k2_hold_in(1'b0), .k3_n(1'b1), .k4_n(1'b1),
    .setup_on(1'b0), .raw_page(2'd0), .auto_on(1'b0), .music_on(1'b0),
    .bri_in(8'd255), .con_in(8'd128), .thumb_in(1'b0), .cur_idx_in(3'd4), .img_cnt_in(3'd4),
    .cpr_st_in(3'd0), .cpr_302_in(1'b0), .cpr_breath_in(1'b0), .cpr_cyc_in(5'd0),
    .cpr_tmr_in(16'd0), .cpr_cmp_in(16'd0), .cpr_aed_in(16'd0), .cpr_aseen_in(1'b0),
    .next_hint(1'b0), .prev_hint(1'b0), .eff_hint(1'b0), .eff_hint_id(4'd0),
    .fault_code(4'd0), .fault_arg(3'd0), .tfok_hint(1'b0), .fault_show(),
    .sat_in(2'd2), .scol_in(3'd0), .int_in(3'd0), .sub_tog(1'b0),
    .sub_upd(1'b0), .sub_rst(1'b0), .sub_show(1'b0), .sub_mot(2'd0),
    .visible(), .hint_show(), .hint_leave(), .txt_we(we), .txt_addr(wa), .txt_data(wd),
    .vol_gain(), .vw_viz(), .fx_effect(), .fx_speed(), .fx_mode(), .fx_demo(), .fx_preview(),
    .ly_sel(), .ly_show(), .ly_x(), .ly_y(), .ly_alpha(), .ly_z(), .ly_motion(),
    .vw_sx(), .vw_sy(), .vw_mirror(), .vw_flip(), .vw_panx(), .vw_pany(),
    .vw_kenburns(), .vw_volume(),
    // R8~R12 新增端口：本测试不用，全部接 0（悬空 = z，曾让下面 cn_text_overlay 的正中黄框出 X）
    .ms_tick_in(1'b0), .stat_tog(1'b0), .cur_wh_in(22'd0), .cpr_ssec_in(7'd0), .cpr_brs_in(4'd0), .cpr_swap_in(1'b0),
    .cpr_intro_in(1'b0), .cpr_full_in(1'b0), .cpr_grp_in(8'd0), .cpr_voice_in(2'd0), .viz_tog(1'b0), .demo_hint(1'b0), .demo_id(3'd0),
    .fault_tot(3'd0), .save_ld(1'b0), .save_in(48'd0), .fac_rst(1'b0), .wfail_hint(1'b0), .last_hint(1'b0), .last_in(32'd0),
    .stat_on(), .menu_disp(), .note_show()
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

reg img = 0;
wire [23:0] bg = img ? {vc[7:0], 8'h40, hc[7:0]} : {hc[7:0], vc[7:0], 8'h5a};

// 图层参数（直接驱动；sd_card_clk 域）
reg        en = 0, selen = 0;
reg [1:0]  sel = 0;
reg [3:0]  show = 4'b0011;
reg [2:0]  scol = 3'd0;                // R8-2 片内字幕颜色
reg [27:0] lx = {7'd8, 7'd60, 7'd0, 7'd66};
reg [23:0] ly = {6'd50, 6'd6, 6'd55, 6'd7};
reg [15:0] la = {4'd10, 4'd10, 4'd10, 4'd10};
reg [7:0]  lz = {2'd0, 2'd1, 2'd2, 2'd3};
reg [7:0]  lm = 8'd0;
reg        cap_en = 0;
reg        wave_en = 0;
reg [2:0]  viz = 3'd1;
reg        pcm_v = 0;
reg signed [15:0] pcm_s = 0;
integer    pdiv = 0, pn = 0;
integer    amp = 25600;
integer    sint [0:47];                // 1 kHz @ 48 kHz 一个周期，×10000（先算好表，比每个样本调 $sin 快得多）
integer    ti;
initial for (ti = 0; ti < 48; ti = ti + 1) sint[ti] = $rtoi(10000.0 * $sin(6.2831853 * ti / 48.0));
always @(posedge pix_clk) begin
    pcm_v <= 1'b0;
    if (pdiv == 520) begin
        pdiv <= 0; pcm_v <= 1'b1; pn <= (pn == 47) ? 0 : pn + 1;
        pcm_s <= amp * sint[pn] / 10000;
    end else pdiv <= pdiv + 1;
end
reg [2:0]  idx = 0;

wire [23:0] lay_rgb, rgb;
wire [13:0] fba; wire [7:0] fbq;
layer_compositor dut (
    .clk(pix_clk), .rst_n(rst_n), .vsync(vs), .de(de), .pixel_x(video_x), .rgb_in(bg), .rgb_out(lay_rgb),
    .enable_async(en), .sel_en_async(selen), .sel_async(sel), .show_async(show), .x_async(lx), .y_async(ly),
    .alpha_async(la), .z_async(lz), .motion_async(lm),
    .wave_en(wave_en), .viz(viz), .pcm_valid(pcm_v), .pcm(pcm_s), .cap_en(cap_en), .img_idx(idx),
    .wclk(sd_clk), .we(we), .waddr(wa), .wdata(wd),
    .bm_we(1'b0), .bm_addr(10'd0), .bm_data(8'd0), .sub_ovr_async(1'b0), .sub_all_async(1'b0),
    .sub_pic_async(3'd0), .sub_color_async(3'd0), .sub_speed_async(2'd1), .sub_col_async(scol), .fb_addr(fba), .fb_q(fbq)
);
cn_text_overlay u_cn (
    .clk(pix_clk), .rst_n(rst_n), .vsync(vs), .de(de), .rgb_in(lay_rgb), .pixel_x(video_x),
    .wclk(sd_clk), .we(1'b0), .waddr(8'd0), .wdata(11'd0),
    .menu_vis_async(1'b0), .hint_show_async(1'b0), .hint_leave_async(1'b0), .cpr_async(1'b0), .note_show_async(1'b0), .fault_show_async(1'b0),
    .stat_on_async(1'b0), .menu_disp_async(1'b0),     // R8-2b：状态栏关（另有 tb_menu_osd 检查）
    .fb_addr(fba), .fb_q(fbq), .rgb_out(rgb)
);

// ---------------- 期望像素 ----------------
reg [7:0] rom [0:16383];  initial $readmemh(`CN_FONT_HEX, rom);
reg [1:0] logo [0:3839];  initial $readmemh(`LOGO_HEX, logo);
reg [10:0] stm [0:63];
always @(posedge sd_clk) if (we && wa[7:6] == 2'b10) stm[wa[5:0]] <= wd;

function glyph; input [10:0] t; input integer row, col;
    reg [9:0] id; reg [7:0] r;
    begin
        id = t[7] ? {~t[9], t[9] | t[8], t[6:0], t[10]} : {3'b000, t[6:0]};
        r = rom[{id, row[3:0]}]; glyph = r[7 - col];
    end
endfunction
function integer a16; input integer v;
    case (v) 0: a16 = 0; 1: a16 = 2; 2: a16 = 3; 3: a16 = 5; 4: a16 = 6; 5: a16 = 8; 6: a16 = 10; 7: a16 = 11; 8: a16 = 13; 9: a16 = 14; default: a16 = 16; endcase
endfunction

// 本帧参数快照（DUT 帧边界锁存后的值）
integer fpx [0:3], fpy [0:3], fsc;
reg [3:0] f_show; reg [15:0] f_a; reg [7:0] f_z, f_m; reg f_en, f_selen; reg [1:0] f_sel; reg [27:0] f_x; reg [2:0] f_scol;
function [23:0] pal; input [2:0] c;
    case (c)
        3'd0: pal = 24'hffffff;  3'd1: pal = 24'hffd800;  3'd2: pal = 24'hff3030;  3'd3: pal = 24'h30e040;
        3'd4: pal = 24'h30e0e0;  3'd5: pal = 24'hff9020;  3'd6: pal = 24'hff70c0;  default: pal = 24'h4080ff;
    endcase
endfunction
integer W [0:3], H [0:3];
initial begin W[0] = 96; H[0] = 40; W[1] = 640; H[1] = 24; W[2] = 132; H[2] = 100; W[3] = 528; H[3] = 64; end

integer errors = 0, bad = 0, nhit [0:3], ncap, nov, nframe;
reg checking = 0;
integer x, y, i, j, L, A, rx, ry, sb, stx, sty, T, fx0, fx1, fy0, fy1, seg;
reg [3:0] hit; reg [23:0] col [0:3]; reg [23:0] C, e, rs, bgs; reg fr;
always @(posedge pix_clk) begin
    if (checking && de) begin
        x = hc; y = vc; rs = rgb; bgs = bg;
        hit = 0;
        for (i = 0; i < 4; i = i + 1) col[i] = 0;
        // 台标
        rx = x - fpx[0]; ry = y - fpy[0];
        if (rx >= 0 && rx < 96 && ry >= 0 && ry < 40 && logo[ry * 96 + rx] != 0) begin
            hit[0] = 1; col[0] = (logo[ry * 96 + rx] == 1) ? 24'hd81e28 : (logo[ry * 96 + rx] == 2) ? 24'hffffff : 24'h7a0e14;
        end
        // 字幕
        ry = y - fpy[1];
        if (ry >= 0 && ry < 24) begin
            hit[1] = 1;
            sb = (f_m[3:2] == 2) ? 640 - fsc : f_x[13:7] * 8;
            stx = x - sb; sty = ry - 4;
            col[1] = (stx >= 0 && stx < 512 && sty >= 0 && sty < 16 && glyph(stm[stx / 8], sty, stx % 8)) ? pal(f_scol) : 24'h000000;
        end
        // 频谱（R10 起图层 3 只画频谱，开关看 wave_en；viz 不用）：32 根柱每根 16 列（14 列柱 + 2 列缝），柱从底往上 hd 行，
        // 顶帽 2 行在 63 - cp 和上一行（cp = 0 不画），柱外透明；柱高按 DUT 当前的 hd / cp 取（场消隐里才更新）
        rx = x - fpx[3]; ry = y - fpy[3];
        if (wave_en && rx >= 0 && rx < 512 && ry >= 0 && ry < 64 && rx % 16 < 14) begin
            seg = rx / 16;
            if (dut.u_spec.cp[seg] != 0 && (ry == 63 - dut.u_spec.cp[seg] || ry == 62 - dut.u_spec.cp[seg])) begin
                hit[3] = 1; col[3] = 24'hffffff;
                if (f_show[3] && f_en) ncap = ncap + 1;
            end else if (ry + dut.u_spec.hd[seg] >= 64) begin
                hit[3] = 1; col[3] = spec_color(seg);
            end
        end
        hit = hit & f_show & {4{f_en}};
        if (hit[0] && hit[1] && hit[3]) nov = nov + 1;
        C = 0; T = 256;
        for (j = 0; j < 4; j = j + 1) begin
            L = 0; for (i = 0; i < 4; i = i + 1) if (f_z[i*2 +: 2] == j) L = i;
            if (hit[L]) begin
                A = a16(f_a[L*4 +: 4]);
                nhit[L] = nhit[L] + 1;
                C = {bl(C[23:16], col[L][23:16], A), bl(C[15:8], col[L][15:8], A), bl(C[7:0], col[L][7:0], A)};
                T = (T * (16 - A)) >> 4;
            end
        end
        // 选中框
        fx0 = (f_sel == 1) ? 0 : fpx[f_sel] - 2;  fx1 = (f_sel == 1) ? 639 : fpx[f_sel] + W[f_sel] + 1;
        fy0 = fpy[f_sel] - 2;  fy1 = fpy[f_sel] + H[f_sel] + 1;
        fr = f_selen && f_en && f_show[f_sel] && (x[2] ^ y[2]) &&
             (((x == fx0 || x == fx1) && y >= fy0 && y <= fy1) || ((y == fy0 || y == fy1) && x >= fx0 && x <= fx1));
        if (fr) begin C = 24'hffd040; T = 0; end
        if (T == 256) e = bgs;
        else e = {sat(((bgs[23:16] * T + 128) >> 8) + C[23:16]), sat(((bgs[15:8] * T + 128) >> 8) + C[15:8]), sat(((bgs[7:0] * T + 128) >> 8) + C[7:0])};
        if (x >= 4 && x < 208 && y >= 4 && y < 48) e = rs;        // 左上角状态栏框（cn_text_overlay 常驻，另有 tb_menu_osd 检查）
        if (rs !== e) begin
            if (bad < 4) $display("    像素 (%0d,%0d) = %h，期望 %h（hit=%b）", x, y, rs, e, hit);
            bad = bad + 1;
        end
    end
end

function [7:0] bl; input integer c, k, a; integer t; begin t = (c * (16 - a) + k * a + 8) >> 4; bl = t[7:0]; end endfunction
function [7:0] sat; input integer v; sat = (v > 255) ? 8'hff : v[7:0]; endfunction

task next_frame_start; begin @(posedge pix_clk); while (!(vc == 0 && hc == 0)) @(posedge pix_clk); end endtask
task snap_params;
    begin
        for (i = 0; i < 4; i = i + 1) begin fpx[i] = dut.px[i]; fpy[i] = dut.py[i]; end
        fsc = dut.scroll; f_show = dut.show_f; f_a = dut.alpha_f; f_z = dut.z_f; f_m = dut.mot_f; f_en = dut.en_f;
        f_selen = dut.selen_f; f_sel = dut.sel_f; f_x = dut.x_f; f_scol = scol;
    end
endtask
task frame_check(input [1023:0] what, input integer need0, input integer need1, input integer need3);
    begin
        next_frame_start; snap_params;
        bad = 0; nhit[0] = 0; nhit[1] = 0; nhit[2] = 0; nhit[3] = 0; ncap = 0; nov = 0; checking = 1;
        @(posedge pix_clk); while (!(vc == 480 && hc == 0)) @(posedge pix_clk);
        checking = 0;
        if (bad == 0 && nhit[0] >= need0 && nhit[1] >= need1 && nhit[3] >= need3)
            $display("  ok   %0s（图层像素 台标 %0d / 字幕 %0d / 频谱 %0d（顶帽 %0d），三层重叠 %0d）", what, nhit[0], nhit[1], nhit[3], ncap, nov);
        else begin
            $display("  FAIL %0s：错 %0d 像素，图层像素 台标 %0d / 字幕 %0d / 频谱 %0d", what, bad, nhit[0], nhit[1], nhit[3]);
            errors = errors + 1;
        end
    end
endtask
task check(input ok, input [1023:0] what);
    begin if (ok) $display("  ok   %0s", what); else begin $display("  FAIL %0s", what); errors = errors + 1; end end
endtask

integer p0x, p0y, s0, k;
initial begin
    #200 rst_n = 1'b1;
    repeat (2) next_frame_start;
    frame_check("L0 layers disabled (not displaying): frame untouched", 0, 0, 0);
    en = 1;
    repeat (2) next_frame_start;
    frame_check("L0 logo 100% + subtitle bar (page-1 Chinese glyphs), pixel-exact", 2000, 10000, 0);
    k = 0; for (i = 0; i < 64; i = i + 1) if (stm[i][9:8] == 2'd1) k = k + 1;
    check(k > 0, "L0 subtitle uses page-1 glyph codes (font > 128 chars)");
    k = 0; for (i = 0; i < 64; i = i + 1) if (stm[i][9:8] == 2'd2) k = k + 1;
    check(k > 0, "L0 subtitle (PIC5) uses page-2 glyph codes (R8-1b: font > 256 chars, glyphs at 256~511)");
    la = {4'd10, 4'd10, 4'd8, 4'd5};
    repeat (2) next_frame_start;
    frame_check("L1 alpha: logo 50%, subtitle 80%, pixel-exact mix", 2000, 10000, 0);
    // R8-4b：画中画（图层 2）已删；层序 L2 改到频谱之后用台标 / 字幕 / 频谱三层重写
    show = 4'b0011; la = {4'd10, 4'd10, 4'd10, 4'd10};
    selen = 1; sel = 2'd0;
    repeat (2) next_frame_start;
    frame_check("L3 selection frame around logo (dashed), pixel-exact", 1000, 10000, 0);
    selen = 0; show = 4'b0011;
    lm = {2'd0, 2'd0, 2'd2, 2'd1};                       // 台标弹跳，字幕滚动
    repeat (2) next_frame_start;
    p0x = dut.px[0]; p0y = dut.py[0]; s0 = dut.scroll;
    next_frame_start; next_frame_start; next_frame_start;
    check(dut.px[0] - p0x == 6 && dut.py[0] - p0y == 3 && dut.scroll - s0 == 6, "L4 bounce +2/+1 px per frame, scroll +2 px per frame");
    frame_check("L4 moving frame still pixel-exact", 1000, 10000, 0);
    // ---- R8-2：片内字幕颜色 ----
    scol = 3'd1;
    repeat (2) next_frame_start;
    check(dut.scol_f == 3'd1, "L9 on-chip subtitle colour input reaches the compositor");
    frame_check("L9 on-chip subtitle in yellow, pixel-exact", 1000, 10000, 0);
    scol = 3'd0;
    // ---- R8-3：频谱（只开频谱层；R10 起开关看 wave_en，viz 不用，这里照顶层给 2）----
    // 1 kHz 正弦从上电起一直在喂，audio_spectrum 每帧都算（升直接跟上），到这里柱高早就稳定了
    lm = 8'd0; show = 4'b1000; wave_en = 1; viz = 3'd2;
    repeat (2) next_frame_start;
    k = 0; for (i = 0; i < 32; i = i + 1) if (dut.u_spec.hd[i] > dut.u_spec.hd[k]) k = i;
    check(k == 9 && dut.u_spec.hd[9] >= 40, "L8 1 kHz tone -> tallest spectrum bar is the 1 kHz bar (9)");
    frame_check("L8 spectrum 32 rainbow bars + white caps, transparent elsewhere, pixel-exact", 0, 0, 1000);
    check(ncap >= 100, "L8 white caps (2 rows above each bar) drawn");
    // ---- L2 层序（R12b 重写）：台标 (128,424) 80%、字幕条 y 440~463 50%、频谱 (64,400) 70% 叠在一起 ----
    //   台标盖住第 4~9 根柱（第 9 根 = 1 kHz 最高），三层都有像素的地方逐像素检查合成先后；
    //   3 种层序让每层在最下 / 中间 / 最上各一次，图层 2（不画）占的那一档分别在最上 / 第 2 档 / 最下
    show = 4'b1011; lx[6:0] = 7'd16; ly[5:0] = 6'd53; ly[11:6] = 6'd55;
    la = {4'd7, 4'd10, 4'd5, 4'd8};
    lz = {2'd0, 2'd3, 2'd1, 2'd2};                       // 频谱 0、字幕 1、台标 2、图层 2 占 3
    repeat (2) next_frame_start;
    frame_check("L2 z-order spectrum < subtitle < logo (overlapping, alpha 70/50/80%), pixel-exact", 1000, 10000, 1000);
    check(nov >= 200, "L2 three layers overlap (spectrum + subtitle + logo on the same pixels)");
    lz = {2'd3, 2'd2, 2'd0, 2'd1};                       // 字幕 0、台标 1、图层 2 占 2、频谱 3
    repeat (2) next_frame_start;
    frame_check("L2 z-order subtitle < logo < spectrum, pixel-exact", 1000, 10000, 1000);
    lz = {2'd2, 2'd0, 2'd3, 2'd1};                       // 图层 2 占 0、台标 1、频谱 2、字幕 3
    repeat (2) next_frame_start;
    frame_check("L2 z-order logo < spectrum < subtitle, pixel-exact", 1000, 10000, 1000);
    // ---- L8 关：wave_en = 0 -> 频谱层不画（柱高照算），台标 / 字幕照常 ----
    wave_en = 0;
    repeat (2) next_frame_start;
    frame_check("L8 wave_en = 0: spectrum layer hidden, logo / subtitle unchanged, pixel-exact", 1000, 10000, 0);
    check(nhit[3] == 0 && dut.u_spec.hd[9] >= 40, "L8 wave_en = 0: no spectrum pixel although bars are still computed");
    // ---- L5：急救 / 未打开显示 -> 所有图层隐藏（频谱也开着）----
    wave_en = 1;
    en = 0;
    repeat (2) next_frame_start;
    frame_check("L5 CPR / display off: all layers hidden", 0, 0, 0);
    $display("RESULT: %0s（%0d 个失败）", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
end
initial begin #3_000_000_000; $display("RESULT: FAIL（超时）"); $finish; end
endmodule
