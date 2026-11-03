`timescale 1ns/1ps
// R1.5b 中文 OSD 自检：page_menu_ctrl（文字 -> 文字 RAM 写口）→ cn_text_overlay（像素）。
// 用真实 640x480@60 时序（800x525）渲染整帧，用同一个 cn_font16.hex 独立算期望像素，逐像素检查：
//   状态栏 / 菜单 / 提示条三个框内的字、边框、压暗底色，框外原样不变。
//   O0 播放页：只有状态栏；O1 设置模式 + 转场页：状态栏 + 菜单 + 提示条「转场设置」；
//   O2 提示条上滑淡出途中（逐像素按 alpha 混合检查）；O3 关设置模式后菜单 / 提示条消失只剩状态栏。
// R8-2b：O0a 上电状态栏关；K3 长按（stat_tog）后状态栏 3 行（第三行文字 RAM 192~215）；O1b 显示页菜单两行都白色；
//   O6 急救中（cpr_async）状态栏强制显示、只有 2 行。
// 运行（仓库根目录）：bash sim/run_menu_osd.sh
`define TEXT_ROM_HEX "src/user_source/hdl_source/io/text_rom.hex"
`define CN_FONT_HEX "src/user_source/hdl_source/display/cn_font16.hex"
module tb_menu_osd;
reg sd_clk = 1'b0;  always #5  sd_clk  = ~sd_clk;    // 100MHz
reg pix_clk = 1'b0; always #20 pix_clk = ~pix_clk;   // 25MHz
reg rst_n = 1'b0;

reg [1:0] page = 2'd0;
reg setup = 1'b0;
reg [3:0] fcode = 4'd0;
reg stog = 1'b0, cpr = 1'b0;
wire stat_on, menu_disp;
wire fshow;
wire visible, hint_show, hint_leave, we;
wire [7:0] wa;
wire [10:0] wd;
// 时间缩短：1ms = 100 拍（1us）；一帧约 16.8ms 仿真时间 = 16800 "ms"
page_menu_ctrl #(.CLKS_PER_MS(100), .SHOW_MS(150000), .HINT_MS(40000), .LEAVE_MS(110000)) u_menu (
    .clk(sd_clk), .rst_n(rst_n), .enable_in(1'b1), .page_in(setup ? page : 2'd0),
    .k2_click_in(1'b0), .k2_hold_in(1'b0), .k3_n(1'b1), .k4_n(1'b1),
    .setup_on(setup), .raw_page(page), .auto_on(1'b0), .music_on(1'b1),
    .bri_in(8'd255), .con_in(8'd128), .thumb_in(1'b0), .cur_idx_in(3'd2), .img_cnt_in(3'd4),
    .cpr_st_in(3'd0), .cpr_302_in(1'b0), .cpr_breath_in(1'b0), .cpr_cyc_in(5'd0),
    .cpr_tmr_in(16'd0), .cpr_cmp_in(16'd0), .cpr_aed_in(16'd0), .cpr_aseen_in(1'b0),
    .next_hint(1'b0), .prev_hint(1'b0), .eff_hint(1'b0), .eff_hint_id(4'd0),
    .fault_code(fcode), .fault_arg(2'd0), .tfok_hint(1'b0), .fault_show(fshow),
    .sat_in(2'd2), .scol_in(3'd0), .int_in(3'd0), .sub_tog(1'b0), .stat_tog(stog),
    .sub_upd(1'b0), .sub_rst(1'b0), .sub_show(1'b0), .sub_mot(2'd0),
    .visible(visible), .stat_on(stat_on), .menu_disp(menu_disp), .hint_show(hint_show), .hint_leave(hint_leave),
    .txt_we(we), .txt_addr(wa), .txt_data(wd),
    .vol_gain(), .vw_viz(),
    .fx_effect(), .fx_speed(), .fx_mode(), .fx_demo(), .fx_preview(),
    .ly_show(), .ly_x(), .ly_y(), .ly_alpha(), .ly_z(), .ly_motion(),
    .vw_sx(), .vw_sy(), .vw_mirror(), .vw_flip(), .vw_panx(), .vw_pany(),
    .vw_kenburns(), .vw_volume()
);

// 640x480@60：H 640/16/96/48，V 480/10/2/33；hs/vs 低有效
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

wire [23:0] bg = {hc[7:0], vc[7:0], 8'h5a};
wire [23:0] rgb;
cn_text_overlay dut (
    .clk(pix_clk), .rst_n(rst_n), .vsync(vs), .de(de), .rgb_in(bg), .pixel_x(video_x),
    .wclk(sd_clk), .we(we), .waddr(wa), .wdata(wd),
    .menu_vis_async(visible), .hint_show_async(hint_show), .hint_leave_async(hint_leave), .cpr_async(cpr), .fault_show_async(fshow),
    .stat_on_async(stat_on), .menu_disp_async(menu_disp),
    .fb_addr(14'd0), .fb_q(),
    .rgb_out(rgb)
);

// ---------------- 期望像素（独立实现：字库 + 文字 RAM 镜像）----------------
reg [7:0] rom [0:16383];
initial $readmemh(`CN_FONT_HEX, rom);
reg [10:0] tm [0:255];
always @(posedge sd_clk) if (we && wa[7:6] != 2'b10) tm[wa] <= wd;

function [23:0] dimf; input [23:0] c;
    dimf = {2'b00, c[23:18], 2'b00, c[15:10], 2'b00, c[7:2]} + 24'h101830;
endfunction
function lit_at;          // 第 a 个字、字内第 row 行第 col 点
    input integer a, row, col;
    reg [10:0] t; reg [9:0] idx; reg [7:0] r;
    begin
        t = tm[a];
        idx = t[7] ? {~t[9], t[9] | t[8], t[6:0], t[10]} : {3'b000, t[6:0]};
        r = rom[{idx, row[3:0]}];
        lit_at = r[7 - col];
    end
endfunction
function [7:0] mixc; input [7:0] t, b; input integer a;
    integer d; begin d = t - b; mixc = b + ((d * a) >>> 4); end
endfunction

integer errors = 0, bad = 0, lit_s = 0, lit_m = 0, lit_h = 0;
reg checking = 0;
reg exp_menu = 0, exp_hint = 0, exp_fault = 0;
reg exp_stat = 0, exp_disp = 0, exp_cpr = 0;
integer sh;
integer lit_f = 0;
integer exp_fr = 0;
integer k_on, k_off;
integer x, y, tx, ty, hy0, a;
reg [23:0] e, rs, bgs, t;
always @(posedge pix_clk) begin
    if (checking && de) begin
        x = hc; y = vc; rs = rgb; bgs = bg;
        e = bgs;
        hy0 = 120 - 3 * exp_fr;
        sh = exp_cpr ? 62 : 62;                     // 状态栏框高：R9 急救中 3 行（第三行 = 本部分按键）
        if (exp_fault && x >= 116 && x < 116 + 408 && y >= 218 && y < 218 + 44) begin
            tx = x - 128; ty = y - 224;
            if (tx >= 0 && tx < 384 && ty >= 0 && ty < 32 && lit_at(224 + tx / 16, ty / 2, (tx % 16) / 2)) begin
                e = 24'hffffff; lit_f = lit_f + 1;
            end else if (x == 116 || x == 116 + 407 || y == 218 || y == 218 + 43) e = 24'hff4040;
            else e = {1'b1, bgs[23:17], 3'b000, bgs[15:11], 3'b000, bgs[7:3]};
        end else if (exp_hint && x >= 116 && x < 116 + 408 && y >= hy0 && y < hy0 + 44) begin
            tx = x - 128; ty = y - (hy0 + 6);
            if (tx >= 0 && tx < 384 && ty >= 0 && ty < 32 && lit_at(96 + tx / 16, ty / 2, (tx % 16) / 2)) begin
                t = 24'hffffff; lit_h = lit_h + 1;
            end else if (x == 116 || x == 116 + 407 || y == hy0 || y == hy0 + 43) t = 24'hffd040;
            else t = dimf(bgs);
            a = 16 - exp_fr;
            e = {mixc(t[23:16], bgs[23:16], a), mixc(t[15:8], bgs[15:8], a), mixc(t[7:0], bgs[7:0], a)};
        end else if (exp_menu && x >= 432 && x < 432 + 204 && y >= 4 && y < 48) begin
            tx = x - 438; ty = y - 9;
            if (tx >= 0 && tx < 192 && ty >= 0 && ty < 34 && (ty < 16 || ty >= 18) &&
                lit_at(48 + (ty >= 18 ? 24 : 0) + tx / 8, ty >= 18 ? ty - 18 : ty, tx % 8)) begin
                e = (ty >= 18 || exp_disp) ? 24'hffffff : 24'hffd040; lit_m = lit_m + 1;
            end else if (x == 432 || x == 432 + 203 || y == 4 || y == 47) e = 24'hffd040;
            else e = dimf(bgs);
        end else if (exp_stat && x >= 4 && x < 4 + 204 && y >= 4 && y < 4 + sh) begin
            tx = x - 10; ty = y - 9;
            if (tx >= 0 && tx < 192 && ty >= 0 && ty < sh - 10 && (ty < 16 || (ty >= 18 && ty < 34) || ty >= 36) &&
                lit_at((ty >= 36 ? 192 : ty >= 18 ? 24 : 0) + tx / 8, ty >= 36 ? ty - 36 : ty >= 18 ? ty - 18 : ty, tx % 8)) begin
                e = 24'hffffff; lit_s = lit_s + 1;
            end else if (x == 4 || x == 4 + 203 || y == 4 || y == 4 + sh - 1) e = 24'h40c0ff;
            else e = dimf(bgs);
        end
        if (rs !== e) begin
            if (bad < 4) $display("    像素 (%0d,%0d) = %h，期望 %h", x, y, rs, e);
            bad = bad + 1;
        end
    end
end

task next_frame_start;
    begin @(posedge pix_clk); while (!(vc == 0 && hc == 0)) @(posedge pix_clk); end
endtask
task frame_check(input m, input h, input [511:0] what);
    begin
        next_frame_start;
        bad = 0; lit_s = 0; lit_m = 0; lit_h = 0; exp_menu = m; exp_hint = h; exp_fr = dut.hint_fr; checking = 1;
        @(posedge pix_clk); while (!(vc == 480 && hc == 0)) @(posedge pix_clk);
        checking = 0;
        if (bad == 0 && (!exp_stat || lit_s > 300) && (exp_stat || lit_s == 0) && (!m || lit_m > 300) && (!h || lit_h > 100))
            $display("  ok   %0s（淡出帧 %0d；亮点 状态栏 %0d / 菜单 %0d / 提示 %0d）", what, exp_fr, lit_s, lit_m, lit_h);
        else begin
            $display("  FAIL %0s：错 %0d 像素，亮点 %0d/%0d/%0d", what, bad, lit_s, lit_m, lit_h);
            errors = errors + 1;
        end
    end
endtask

initial begin
    #200 rst_n = 1'b1;
    // 注意：hint_show / hint_leave 是同一计数器的两个组合输出，交接那一刻有 delta 毛刺，必须在时钟沿上采样，不能直接 wait
    @(posedge sd_clk); while (!hint_show) @(posedge sd_clk);
    @(posedge sd_clk); while (hint_show || hint_leave) @(posedge sd_clk);              // 上电 music_on=1 会弹一次「背景音乐 开启」（板上 enable 晚于拨码，不会弹）
    repeat (2) next_frame_start;
    frame_check(0, 0, "O0a power-on: status bar off (R8-2b), nothing drawn");
    @(posedge sd_clk); stog = 1'b1; @(posedge sd_clk); stog = 1'b0;      // 播放模式 K3 长按
    @(posedge sd_clk); while (!hint_show) @(posedge sd_clk);
    if (!stat_on || u_menu.hint != 6'd35) begin $display("  FAIL O0b stat_tog -> stat_on=%0d hint=%0d", stat_on, u_menu.hint); errors = errors + 1; end
    exp_stat = 1'b1;
    repeat (2) next_frame_start;
    frame_check(0, 1, "O0b K3 hold: hint + 3-row status bar");
    @(posedge sd_clk); while (hint_show || hint_leave) @(posedge sd_clk);
    repeat (2) next_frame_start;
    frame_check(0, 0, "O0 play page: 3-row status bar, pixel-exact");
    setup = 1'b1; page = 2'd0;                     // R8-2b：显示页，菜单两行都白色
    repeat (2) next_frame_start;
    exp_disp = 1'b1;
    frame_check(1, 1, "O1b setup + DISPLAY page: menu both rows white, pixel-exact");
    if (!menu_disp) begin $display("  FAIL O1b menu_disp=0"); errors = errors + 1; end
    exp_disp = 1'b0;
    page = 2'd1;                                   // 设置模式 + 转场页
    repeat (2) next_frame_start;
    frame_check(1, 1, "O1 setup + TRANS: status + menu + hint (2x), pixel-exact");
    if (dut.hint_fr != 0) begin $display("  FAIL O1 hint should not be fading yet"); errors = errors + 1; end
    @(posedge sd_clk); while (!hint_leave) @(posedge sd_clk);
    repeat (5) next_frame_start;
    frame_check(1, 1, "O2 hint sliding up / fading, pixel-exact alpha mix");
    if (dut.hint_fr < 3) begin $display("  FAIL O2 fade frame %0d < 3", dut.hint_fr); errors = errors + 1; end
    @(posedge sd_clk); while (hint_leave) @(posedge sd_clk);
    setup = 1'b0;                                  // R2：菜单在设置模式里常驻，关 SW1 才消失（会弹「设置模式 关闭」）
    @(posedge sd_clk); while (!hint_show) @(posedge sd_clk);
    @(posedge sd_clk); while (hint_show || hint_leave || visible) @(posedge sd_clk);
    repeat (2) next_frame_start;
    frame_check(0, 0, "O3 SW1 off: menu + hint gone, status bar stays");
    // O4：故障条（读取失败），闪烁：亮的帧逐像素检查，灭的帧和没有故障一样
    fcode = 4'd4;
    repeat (3) next_frame_start;
    k_on = 0; k_off = 0;
    repeat (70) begin
        next_frame_start; @(posedge pix_clk);
        bad = 0; lit_s = 0; lit_f = 0; exp_menu = 0; exp_hint = 0; exp_fault = dut.f_on; exp_fr = 0; checking = 1;
        @(posedge pix_clk); while (!(vc == 480 && hc == 0)) @(posedge pix_clk);
        checking = 0;
        if (bad != 0 || (exp_fault && lit_f < 300)) begin
            $display("  FAIL O4 fault banner frame (on=%0d)：错 %0d 像素，亮点 %0d", exp_fault, bad, lit_f); errors = errors + 1;
        end
        if (exp_fault) k_on = k_on + 1; else k_off = k_off + 1;
    end
    exp_fault = 0;
    if (k_on >= 40 && k_off >= 15) $display("  ok   O4 fault banner 「TF 卡读取失败」 blinks (%0d on / %0d off frames), every frame pixel-exact", k_on, k_off);
    else begin $display("  FAIL O4 blink %0d on / %0d off", k_on, k_off); errors = errors + 1; end
    fcode = 4'd0;
    repeat (3) next_frame_start;
    frame_check(0, 0, "O5 fault cleared: banner gone");
    // O6：状态栏关着时进急救 -> 强制显示，只有 2 行（这里只给 cn_text_overlay 急救电平，文字仍是平时的前两行）
    @(posedge sd_clk); stog = 1'b1; @(posedge sd_clk); stog = 1'b0;
    @(posedge sd_clk); while (!hint_show) @(posedge sd_clk);
    @(posedge sd_clk); while (hint_show || hint_leave) @(posedge sd_clk);
    exp_stat = 1'b0;
    repeat (2) next_frame_start;
    frame_check(0, 0, "O6a K3 hold again -> status bar off");
    cpr = 1'b1;  exp_stat = 1'b1;  exp_cpr = 1'b1;
    repeat (2) next_frame_start;
    frame_check(0, 0, "O6 CPR: status bar forced on, 3 rows (R9), pixel-exact");
    $display("RESULT: %0s（%0d 个失败）", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
end
initial begin #4_000_000_000; $display("RESULT: FAIL（超时）"); $finish; end   // R8-2b 多了 3 次提示条，约 2.3 秒
endmodule
