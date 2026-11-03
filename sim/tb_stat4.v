`timescale 1ns/1ps
// R8-5c 快速检查：状态栏第四行（原图分辨率），把左上 224x96 区域每种情况存成 ppm，人工看图
`define TEXT_ROM_HEX "src/user_source/hdl_source/io/text_rom.hex"
`define CN_FONT_HEX "src/user_source/hdl_source/display/cn_font16.hex"
module tb_stat4;
reg sd_clk = 1'b0;  always #5  sd_clk  = ~sd_clk;    // 100MHz
reg pix_clk = 1'b0; always #20 pix_clk = ~pix_clk;   // 25MHz
reg rst_n = 1'b0;

reg [1:0] page = 2'd0;
reg setup = 1'b0;
reg [3:0] fcode = 4'd0;
reg stog = 1'b0, cpr = 1'b0;
reg [2:0]  cst = 3'd0;                               // 急救状态（R11：7A 删掉，急救中状态栏固定 3 行）
reg [21:0] wh = 22'd0;
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
    .bri_in(8'd255), .con_in(8'd128), .thumb_in(1'b0), .cur_idx_in(3'd2), .cur_wh_in(wh), .img_cnt_in(3'd4),
    .cpr_st_in(cst), .cpr_302_in(1'b0), .cpr_breath_in(1'b0), .cpr_cyc_in(5'd0), .viz_tog(1'b0),
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
    .menu_vis_async(visible), .hint_show_async(hint_show), .hint_leave_async(hint_leave), .cpr_async(cpr), .note_show_async(1'b0), .fault_show_async(fshow),
    .stat_on_async(stat_on), .menu_disp_async(menu_disp),
    .fb_addr(14'd0), .fb_q(),
    .rgb_out(rgb)
);


integer f, x, yy, n;
reg [8*40:1] fn;
task grab; input [8*40:1] name; begin
    @(negedge vs); @(posedge vs);           // 等新一帧开始
    f = $fopen(name, "w"); $fwrite(f, "P3 224 96 255\n");
    for (yy = 0; yy < 96; yy = yy + 1)
        for (x = 0; x < 224; x = x + 1) begin
            @(posedge pix_clk); while (!(de && hc == x && vc == yy)) @(posedge pix_clk);
            #1 $fwrite(f, "%0d %0d %0d\n", rgb[23:16], rgb[15:8], rgb[7:0]);
        end
    $fclose(f);
end endtask
task setwh; input [10:0] w, h; begin
    wh = {w, h}; #200000;                    // 等转换 + 文字刷新
    @(negedge vs); @(negedge vs);            // 等帧边界锁存
end endtask
initial begin
    #1000 rst_n = 1'b1;
    #10000 @(posedge sd_clk); stog = 1'b1; @(posedge sd_clk); stog = 1'b0;
    setwh(11'd1920, 11'd1080); grab("sim/stat4_a.ppm");
    setwh(11'd320,  11'd240);  grab("sim/stat4_b.ppm");
    setwh(11'd640,  11'd480);  grab("sim/stat4_c.ppm");
    setwh(11'd8,    11'd8);    grab("sim/stat4_d.ppm");
    setwh(11'd650,  11'd90);   grab("sim/stat4_e.ppm");
    cpr = 1'b1; @(negedge vs); @(negedge vs); grab("sim/stat4_f.ppm");
    // R11：急救 ② 也是 3 行（第四行不画）
    cst = 3'd2; #200000; @(negedge vs); @(negedge vs); grab("sim/stat4_g.ppm");
    $display("RESULT: DONE");
    $finish;
end
endmodule
