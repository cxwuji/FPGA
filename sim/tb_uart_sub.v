`timescale 1ns/1ps
// R8-1c 串口换字幕自检：uart_subtitle + page_menu_ctrl + layer_compositor + cn_text_overlay（借字库第二读口），真实 640x480 时序、
// 真实 115200 波特率（每位 8680 ns）。测试台自己记下发出去的点阵，独立算字幕条（y 440~463 整行）每个像素的期望值逐像素比对：
//   U1 上电：片内字幕（PIC1）白字，滚动每帧 2 点
//   U2 CMD 01（静止 / 黄 / 全部图）：回 OK、提示条「字幕已更新」、菜单里字幕层运动 = 静止，点阵逐像素 + 黄色
//   U3 CMD 01（滚动 / 速度 4 / 红 / 只替换当前图）：每帧 4 点、逐像素；换到别的图 -> 片内字幕白字每帧 2 点；换回来又是替换字幕
//   U4 校验错：回 ER，字幕回到片内默认
//   U5 传到一半断了：10 ms 后回 ER，字幕回到片内默认
//   U6 先替换成功，再 CMD 02 恢复：回 OK、提示条「已恢复默认字幕」、白字每帧 2 点
//   U7 电脑脚本 tools/uart_subtitle.py 真实生成的帧（sim/uart_frame_u7.hex：黄 / 滚动 / 速度 3 / 全部图）原样发送，逐像素
// 运行（仓库根目录）：bash sim/run_uart_sub.sh
`define TEXT_ROM_HEX "src/user_source/hdl_source/io/text_rom.hex"
`define CN_FONT_HEX "src/user_source/hdl_source/display/cn_font16.hex"
`define LOGO_HEX "src/user_source/hdl_source/display/logo_rom.hex"
module tb_uart_sub;
reg sd_clk = 1'b0;  always #5  sd_clk  = ~sd_clk;
reg stog = 1'b0;                                       // R8-2b：播放模式 K3 单击（字幕开 / 关），上电字幕关
reg pix_clk = 1'b0; always #20 pix_clk = ~pix_clk;
reg rst_n = 1'b0;

reg  [2:0] idx = 3'd0;               // 当前图（两个时钟域都直接用，测试台里换图时整帧对齐）
reg        rx = 1'b1;
wire       tx;
wire       bm_we, s_ovr, s_all, ev_upd, ev_rst, ev_show;
wire [9:0] bm_a;
wire [7:0] bm_d;
wire [2:0] s_pic, s_col;
wire [1:0] s_spd, ev_mot;
uart_subtitle u_uart (
    .clk(sd_clk), .rst_n(rst_n), .rx_in(rx), .tx_out(tx), .cur_pic(idx),
    .bm_we(bm_we), .bm_addr(bm_a), .bm_data(bm_d),
    .sub_ovr(s_ovr), .sub_all(s_all), .sub_pic(s_pic), .sub_color(s_col), .sub_speed(s_spd),
    .ev_upd(ev_upd), .ev_rst(ev_rst), .ev_show(ev_show), .ev_mot(ev_mot)
);

wire we; wire [7:0] wa; wire [10:0] wd;
wire [3:0] ly_show; wire [27:0] ly_x; wire [23:0] ly_y; wire [15:0] ly_alpha; wire [7:0] ly_z, ly_motion;
page_menu_ctrl #(.CLKS_PER_MS(100)) u_menu (
    .clk(sd_clk), .rst_n(rst_n), .enable_in(1'b1), .page_in(2'd0),
    .k2_click_in(1'b0), .k2_hold_in(1'b0), .k3_n(1'b1), .k4_n(1'b1),
    .setup_on(1'b0), .raw_page(2'd0), .auto_on(1'b0), .music_on(1'b0),
    .bri_in(8'd255), .con_in(8'd128), .thumb_in(1'b0), .cur_idx_in(idx), .img_cnt_in(3'd5),
    .cpr_st_in(3'd0), .cpr_302_in(1'b0), .cpr_breath_in(1'b0), .cpr_cyc_in(5'd0),
    .cpr_tmr_in(16'd0), .cpr_cmp_in(16'd0), .cpr_aed_in(16'd0), .cpr_aseen_in(1'b0),
    .next_hint(1'b0), .prev_hint(1'b0), .eff_hint(1'b0), .eff_hint_id(4'd0), .demo_hint(1'b0), .demo_id(3'd0),
    .fault_code(4'd0), .fault_arg(3'd0), .tfok_hint(1'b0), .fault_show(),
    .sat_in(2'd2), .scol_in(3'd0), .int_in(3'd0), .sub_tog(stog),
    .sub_upd(ev_upd), .sub_rst(ev_rst), .sub_show(ev_show), .sub_mot(ev_mot),
    .visible(), .hint_show(), .hint_leave(), .txt_we(we), .txt_addr(wa), .txt_data(wd),
    .vol_gain(), .vw_viz(), .fx_effect(), .fx_speed(), .fx_mode(), .fx_demo(), .fx_preview(),
    .ly_sel(), .ly_show(ly_show), .ly_x(ly_x), .ly_y(ly_y), .ly_alpha(ly_alpha), .ly_z(ly_z), .ly_motion(ly_motion),
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
wire [23:0] bg = {hc[7:0], vc[7:0], 8'h5a};

wire [23:0] lay_rgb, rgb;
wire [13:0] fba; wire [7:0] fbq;
layer_compositor dut (
    .clk(pix_clk), .rst_n(rst_n), .vsync(vs), .de(de), .pixel_x(video_x), .rgb_in(bg), .rgb_out(lay_rgb),
    .enable_async(1'b1), .sel_en_async(1'b0), .sel_async(2'd0), .show_async(ly_show & 4'b0010), .x_async(ly_x), .y_async(ly_y),
    .alpha_async(ly_alpha), .z_async(ly_z), .motion_async(ly_motion),
    .wave_en(1'b0), .viz(3'd1), .pcm_valid(1'b0), .pcm(16'sd0), .cap_en(1'b0), .img_idx(idx),
    .wclk(sd_clk), .we(we), .waddr(wa), .wdata(wd),
    .bm_we(bm_we), .bm_addr(bm_a), .bm_data(bm_d), .sub_ovr_async(s_ovr), .sub_all_async(s_all),
    .sub_pic_async(s_pic), .sub_color_async(s_col), .sub_speed_async(s_spd), .sub_col_async(3'd0),
    .fb_addr(fba), .fb_q(fbq)
);
cn_text_overlay u_cn (
    .clk(pix_clk), .rst_n(rst_n), .vsync(vs), .de(de), .rgb_in(lay_rgb), .pixel_x(video_x),
    .wclk(sd_clk), .we(1'b0), .waddr(8'd0), .wdata(11'd0),
    .menu_vis_async(1'b0), .hint_show_async(1'b0), .hint_leave_async(1'b0), .cpr_async(1'b0), .fault_show_async(1'b0),
    .stat_on_async(1'b0), .menu_disp_async(1'b0),     // R8-2b：状态栏关（另有 tb_menu_osd 检查）
    .fb_addr(fba), .fb_q(fbq), .rgb_out(rgb)
);

// ---------------- 串口：发 / 收 ----------------
localparam integer BIT_NS = 8680;
task send_byte(input [7:0] b);
    integer k;
    begin
        rx = 1'b0; #(BIT_NS);
        for (k = 0; k < 8; k = k + 1) begin rx = b[k]; #(BIT_NS); end
        rx = 1'b1; #(BIT_NS);
    end
endtask
reg [7:0] bmp [0:1023];               // 测试台记下的点阵（期望值从这里算，不读 DUT 的 RAM）
reg [7:0] cs;
integer   n;
// 发一帧：cmd 01 带点阵；ndat < 1024 = 传到一半断开；bad = 故意把校验和弄错
task send_frame(input [7:0] cmd, input [7:0] p1, input [7:0] p2, input integer ndat, input bad);
    begin
        send_byte(8'ha5); send_byte(8'h5a); send_byte(cmd); send_byte(p1); send_byte(p2);
        cs = cmd + p1 + p2;
        if (cmd == 8'h01)
            for (n = 0; n < ndat; n = n + 1) begin send_byte(bmp[n]); cs = cs + bmp[n]; end
        if (ndat == 1024 || cmd != 8'h01) send_byte(bad ? cs ^ 8'h01 : cs);
    end
endtask
reg [8*8-1:0] reply = 0;              // 最近收到的字节（右边是最新）
integer       nrep = 0;
reg [7:0]     tb_;
integer       q;
always begin
    @(negedge tx);
    #(BIT_NS / 2);
    for (q = 0; q < 8; q = q + 1) begin #(BIT_NS); tb_[q] = tx; end
    #(BIT_NS);
    if (tx !== 1'b1) $display("    TX 停止位错");
    reply = {reply[55:0], tb_}; nrep = nrep + 1;
end
task wait_reply(input [15:0] want, input [1023:0] what);   // 等 4 字节 "XX\r\n"
    integer t0;
    begin
        t0 = nrep;
        fork : wr
            begin while (nrep < t0 + 4) @(posedge sd_clk); disable wr; end
            begin #20_000_000; disable wr; end
        join
        check(nrep >= t0 + 4 && reply[31:0] == {want, 16'h0d0a}, what);
    end
endtask

// ---------------- 期望像素（字幕条那几行）----------------
reg [7:0] rom [0:16383];  initial $readmemh(`CN_FONT_HEX, rom);
reg [10:0] stm [0:63];
always @(posedge sd_clk) if (we && wa[7:6] == 2'b10) stm[wa[5:0]] <= wd;
function glyph; input [10:0] t; input integer row, col;
    reg [9:0] id; reg [7:0] r;
    begin
        id = t[7] ? {~t[9], t[9] | t[8], t[6:0], t[10]} : {3'b000, t[6:0]};
        r = rom[{id, row[3:0]}]; glyph = r[7 - col];
    end
endfunction
function [23:0] pal; input [2:0] c;
    case (c)
        3'd0: pal = 24'hffffff;  3'd1: pal = 24'hffd800;  3'd2: pal = 24'hff3030;  3'd3: pal = 24'h30e040;
        3'd4: pal = 24'h30e0e0;  3'd5: pal = 24'hff9020;  3'd6: pal = 24'hff70c0;  default: pal = 24'h4080ff;
    endcase
endfunction
function integer a16; input integer v;
    case (v) 0: a16 = 0; 1: a16 = 2; 2: a16 = 3; 3: a16 = 5; 4: a16 = 6; 5: a16 = 8; 6: a16 = 10; 7: a16 = 11; 8: a16 = 13; 9: a16 = 14; default: a16 = 16; endcase
endfunction
function [7:0] bl; input integer c, k, a; integer t; begin t = (c * (16 - a) + k * a + 8) >> 4; bl = t[7:0]; end endfunction
function [7:0] sat; input integer v; sat = (v > 255) ? 8'hff : v[7:0]; endfunction

integer errors = 0, bad = 0, nlit = 0;
reg     checking = 0;
reg     e_ovr;                         // 本帧期望：用替换点阵
reg [2:0] e_col;
integer fpy, fsc, fx, A, T, x, y, ry, sb, stx, sty;
reg [7:0] fm;
reg [23:0] C, e, col, bgs;
reg lit;
always @(posedge pix_clk) begin
    if (checking && de) begin
        x = hc; y = vc; bgs = bg;
        ry = y - fpy;
        if (ry >= 0 && ry < 24) begin
            sb = (fm[3:2] == 2) ? 640 - fsc : fx * 8;
            stx = x - sb; sty = ry - 4;
            lit = 0;
            if (stx >= 0 && stx < 512 && sty >= 0 && sty < 16)
                lit = e_ovr ? bmp[sty * 64 + stx / 8][7 - stx % 8] : glyph(stm[stx / 8], sty, stx % 8);
            col = lit ? pal(e_ovr ? e_col : 3'd0) : 24'h000000;
            if (lit) nlit = nlit + 1;
            A = a16(ly_alpha[7:4]);
            C = {bl(0, col[23:16], A), bl(0, col[15:8], A), bl(0, col[7:0], A)};
            T = (256 * (16 - A)) >> 4;
            e = {sat(((bgs[23:16] * T + 128) >> 8) + C[23:16]), sat(((bgs[15:8] * T + 128) >> 8) + C[15:8]),
                 sat(((bgs[7:0] * T + 128) >> 8) + C[7:0])};
            if (lay_rgb !== e) begin
                if (bad < 4) $display("    像素 (%0d,%0d) = %h，期望 %h", x, y, lay_rgb, e);
                bad = bad + 1;
            end
        end
    end
end
task next_frame_start; begin @(posedge pix_clk); while (!(vc == 0 && hc == 0)) @(posedge pix_clk); end endtask
task frame_check(input ovr, input [2:0] c, input [1023:0] what);
    begin
        next_frame_start;
        fpy = dut.py[1]; fsc = dut.scroll; fm = dut.mot_f; fx = dut.x_f[13:7];
        e_ovr = ovr; e_col = c; bad = 0; nlit = 0; checking = 1;
        @(posedge pix_clk); while (!(vc == 480 && hc == 0)) @(posedge pix_clk);
        checking = 0;
        if (bad == 0 && nlit > 0 && dut.sub_on == ovr)          // 滚动时文字可能只有一部分在屏幕里，亮点数不定
            $display("  ok   %0s（字幕亮点 %0d）", what, nlit);
        else begin
            $display("  FAIL %0s：错 %0d 像素，亮点 %0d，sub_on=%b", what, bad, nlit, dut.sub_on);
            errors = errors + 1;
        end
    end
endtask
task check(input ok, input [1023:0] what);
    begin if (ok) $display("  ok   %0s", what); else begin $display("  FAIL %0s", what); errors = errors + 1; end end
endtask
task scroll_step(input integer want, input [1023:0] what);
    integer s0;
    begin
        next_frame_start; s0 = dut.scroll;
        next_frame_start; next_frame_start; next_frame_start;
        check(dut.scroll - s0 == 3 * want || dut.scroll < s0, what);
    end
endtask
task set_idx(input [2:0] v);           // 在帧边界换图（和板上 active_index 一样只在帧边界变）
    begin next_frame_start; idx = v; repeat (3) next_frame_start; end
endtask

integer i;
initial begin
    for (i = 0; i < 1024; i = i + 1) bmp[i] = (i * 37 + (i >> 6) * 11) ^ 8'h5a;   // 每一位都有 0 有 1
    #200 rst_n = 1'b1;
    repeat (3) next_frame_start;
    if (ly_show[1]) begin $display("  FAIL U0 power-up subtitle should be off (R8-2b)"); errors = errors + 1; end
    else $display("  ok   U0 power-up: subtitle off (R8-2b)");
    @(posedge sd_clk); stog = 1'b1; @(posedge sd_clk); stog = 1'b0;      // 播放模式 K3 单击：字幕开
    repeat (3) next_frame_start;
    frame_check(0, 3'd0, "U1 K3 -> on-chip subtitle (PIC1), white, pixel-exact");
    scroll_step(2, "U1 on-chip subtitle scrolls 2 px / frame");

    // U2：静止、黄色、全部图（P1 = {速度-1=1, 全部=1, 运动=0, 显示=1}）
    send_frame(8'h01, 8'b00_01_1_00_1, 8'd1, 1024, 0);
    wait_reply("OK", "U2 frame accepted: board replies OK");
    check(s_ovr && s_all && s_col == 3'd1 && u_menu.hint == 5'd27, "U2 override on, all pictures, yellow; hint = subtitle updated");
    @(posedge sd_clk);
    check(ly_motion[3:2] == 2'd0 && ly_show[1], "U2 menu: subtitle layer motion = static, shown");
    repeat (3) next_frame_start;
    frame_check(1, 3'd1, "U2 uploaded 512x16 bitmap, yellow, static, pixel-exact");
    set_idx(3'd2);
    frame_check(1, 3'd1, "U2 scope = all: other picture also uses uploaded subtitle");
    set_idx(3'd0);

    // U3：滚动、速度 4、红色、只替换当前图（P1 = {速度-1=3, 全部=0, 运动=2, 显示=1}）
    for (i = 0; i < 1024; i = i + 1) bmp[i] = ~((i * 53) ^ (i >> 3));
    send_frame(8'h01, 8'b00_11_0_10_1, 8'd2, 1024, 0);
    wait_reply("OK", "U3 frame accepted: board replies OK");
    repeat (3) next_frame_start;
    check(ly_motion[3:2] == 2'd2 && !s_all && s_pic == 3'd0, "U3 menu motion = scroll; scope = only picture 1");
    scroll_step(4, "U3 speed 4: scroll 4 px / frame");
    frame_check(1, 3'd2, "U3 scrolling uploaded subtitle, red, pixel-exact");
    set_idx(3'd1);
    frame_check(0, 3'd0, "U3 other picture: back to its on-chip subtitle (PIC2), white");
    scroll_step(2, "U3 other picture: on-chip subtitle 2 px / frame");
    set_idx(3'd0);
    frame_check(1, 3'd2, "U3 back to picture 1: uploaded subtitle again");

    // U4：校验错
    send_frame(8'h01, 8'b00_01_1_10_1, 8'd3, 1024, 1);
    wait_reply("ER", "U4 bad checksum: board replies ER");
    check(!s_ovr, "U4 bad checksum: override off");
    repeat (3) next_frame_start;
    frame_check(0, 3'd0, "U4 bad checksum: on-chip subtitle, white");

    // U5：传到一半断开（再等 10 ms 超时）
    send_frame(8'h01, 8'b00_01_1_10_1, 8'd3, 100, 0);
    wait_reply("ER", "U5 frame cut off: board replies ER after 10 ms gap");
    check(!s_ovr && u_uart.st == 3'd0, "U5 cut off: override off, parser back to idle");

    // U6：先替换成功，再恢复默认
    send_frame(8'h01, 8'b00_00_1_10_1, 8'd6, 1024, 0);
    wait_reply("OK", "U6 upload again: OK");
    repeat (3) next_frame_start;
    frame_check(1, 3'd6, "U6 uploaded subtitle, pink, speed 1, pixel-exact");
    scroll_step(1, "U6 speed 1: scroll 1 px / frame");
    send_frame(8'h02, 8'd0, 8'd0, 0, 0);
    wait_reply("OK", "U6 restore: OK");
    check(!s_ovr && s_col == 3'd0 && s_spd == 2'd1 && u_menu.hint == 5'd28, "U6 restore: override off, white, speed 2; hint = default restored");
    repeat (3) next_frame_start;
    frame_check(0, 3'd0, "U6 restored on-chip subtitle, white, pixel-exact");
    scroll_step(2, "U6 restored: 2 px / frame");


    // U7：电脑脚本生成的帧
    for (i = 0; i < 1030; i = i + 1) send_byte(pkt[i]);
    for (i = 0; i < 1024; i = i + 1) bmp[i] = pkt[5 + i];
    wait_reply("OK", "U7 frame from tools/uart_subtitle.py accepted: OK");
    repeat (3) next_frame_start;
    check(s_all && s_col == 3'd1 && s_spd == 2'd2 && ly_motion[3:2] == 2'd2 && ly_show[1], "U7 script P1/P2 decoded: all, yellow, speed 3, scroll, shown");
    scroll_step(3, "U7 speed 3: scroll 3 px / frame");
    frame_check(1, 3'd1, "U7 script-rendered text, pixel-exact");

    $display("RESULT: %0s（%0d 个失败）", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
end
reg [7:0] pkt [0:1029];
initial $readmemh("sim/uart_frame_u7.hex", pkt);
initial begin #3_000_000_000; $display("RESULT: FAIL（超时）"); $finish; end
endmodule
