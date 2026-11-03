`timescale 1ns/1ps
// R12b 图层合成改版对照：新 layer_compositor（3 级合成）和改之前的原版（4 级，git 里 R12a 的版本，运行脚本取出来改名 layer_compositor_old）
//   喂同样的输入（随机背景、随机图层参数 / 层序 / 运动 / 透明度、字幕文字 + 串口点阵、频谱用的 PCM），640x480@60 真实时序，
//   每 2 帧换一组参数，从第 2 帧起逐像素比较 rgb_out，必须完全一样。
// 运行（仓库根目录）：bash sim/run_layer_eq.sh
`define LOGO_HEX "src/user_source/hdl_source/display/logo_rom.hex"
`define CN_FONT_HEX "src/user_source/hdl_source/display/cn_font16.hex"
module tb_layer_eq;
reg pix_clk = 1'b0; always #20 pix_clk = ~pix_clk;   // 25MHz
reg sd_clk  = 1'b0; always #5  sd_clk  = ~sd_clk;    // 100MHz
reg rst_n = 1'b0;
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
wire [7:0]  bgb = hc[7:0] * 8'd7 + vc[7:0] * 8'd13;
wire [23:0] bg = de ? {hc[7:0] ^ vc[7:0], hc[9:2] + vc[8:1], bgb} : 24'd0;
// 参数（sd_card_clk 域，帧中间换，模块里 2FF + 帧边界锁存）
reg        en = 1, selen = 0;
reg [1:0]  sel = 0;
reg [3:0]  show = 4'hf;
reg [27:0] lx = 0;
reg [23:0] ly = 0;
reg [15:0] la = 16'haaaa;
reg [7:0]  lz = {2'd0, 2'd1, 2'd2, 2'd3};
reg [7:0]  lm = 0;
reg        wave_en = 1;
reg        sovr = 0, sall = 1;
reg [2:0]  spic = 0, scolr = 1, scol = 0, img = 0;
reg [1:0]  sspd = 2;
// PCM（频谱）
reg        pv = 0;
reg signed [15:0] pcm = 0;
integer pc = 0;
always @(posedge pix_clk) begin
    pc = (pc == 520) ? 0 : pc + 1;
    pv <= (pc == 0);
    if (pc == 0) pcm <= $random;
end
// 字幕文字 / 点阵写口
reg        we = 0, bwe = 0;
reg [7:0]  wa = 0;
reg [10:0] wd = 0;
reg [9:0]  ba = 0;
reg [7:0]  bd = 0;
wire [13:0] fa_n, fa_o;
reg  [7:0]  fq_n, fq_o;
reg  [7:0]  font [0:16383];
initial $readmemh(`CN_FONT_HEX, font);
always @(posedge pix_clk) begin fq_n <= font[fa_n]; fq_o <= font[fa_o]; end
wire [23:0] out_n, out_o;
layer_compositor u_new (
    .clk(pix_clk), .rst_n(rst_n), .vsync(vs), .de(de), .pixel_x(video_x), .rgb_in(bg), .rgb_out(out_n),
    .enable_async(en), .sel_en_async(selen), .sel_async(sel), .show_async(show), .x_async(lx), .y_async(ly),
    .alpha_async(la), .z_async(lz), .motion_async(lm), .wave_en(wave_en), .viz(3'd2), .pcm_valid(pv), .pcm(pcm),
    .cap_en(1'b1), .img_idx(img), .wclk(sd_clk), .we(we), .waddr(wa), .wdata(wd),
    .bm_we(bwe), .bm_addr(ba), .bm_data(bd), .sub_ovr_async(sovr), .sub_all_async(sall), .sub_pic_async(spic),
    .sub_color_async(scolr), .sub_speed_async(sspd), .sub_col_async(scol), .fb_addr(fa_n), .fb_q(fq_n)
);
layer_compositor_old u_old (
    .clk(pix_clk), .rst_n(rst_n), .vsync(vs), .de(de), .pixel_x(video_x), .rgb_in(bg), .rgb_out(out_o),
    .enable_async(en), .sel_en_async(selen), .sel_async(sel), .show_async(show), .x_async(lx), .y_async(ly),
    .alpha_async(la), .z_async(lz), .motion_async(lm), .wave_en(wave_en), .viz(3'd2), .pcm_valid(pv), .pcm(pcm),
    .cap_en(1'b1), .img_idx(img), .wclk(sd_clk), .we(we), .waddr(wa), .wdata(wd),
    .bm_we(bwe), .bm_addr(ba), .bm_data(bd), .sub_ovr_async(sovr), .sub_all_async(sall), .sub_pic_async(spic),
    .sub_color_async(scolr), .sub_speed_async(sspd), .sub_col_async(scol), .fb_addr(fa_o), .fb_q(fq_o)
);
// 比较
integer frame = 0, nbad = 0, ncmp = 0, nlit = 0;
reg cmp_on = 0;
always @(posedge pix_clk) begin
    if (vc == 0 && hc == 0) frame = frame + 1;
    if (cmp_on && de) begin
        ncmp = ncmp + 1;
        if (out_n != bg) nlit = nlit + 1;
        if (out_n !== out_o) begin
            if (nbad < 10) $display("  差异 frame %0d (%0d,%0d)：新 %h 原 %h 背景 %h", frame, hc, vc, out_n, out_o, bg);
            nbad = nbad + 1;
        end
    end
end
task wait_frames(input integer n); integer f; begin f = frame + n; wait (frame == f); end endtask
// 随机一组参数：层序 = 随机排列（菜单只做相邻交换，所以一定是排列）
integer i, j, t;
reg [1:0] perm [0:3];
task randomize;
    begin
        for (i = 0; i < 4; i = i + 1) perm[i] = i;
        for (i = 3; i > 0; i = i - 1) begin j = {$random} % (i + 1); t = perm[i]; perm[i] = perm[j]; perm[j] = t; end
        lz = {perm[3], perm[2], perm[1], perm[0]};
        show = $random; show[2] = $random;
        for (i = 0; i < 4; i = i + 1) begin
            lx[i*7 +: 7] = {$random} % 70;
            ly[i*6 +: 6] = {$random} % 56;
            la[i*4 +: 4] = {$random} % 11;
            lm[i*2 +: 2] = {$random} % 3;
        end
        selen = $random;
        t = {$random} % 3;  sel = (t == 2) ? 2'd3 : t;
        sovr = $random; sall = $random; spic = {$random} % 4; img = {$random} % 4;
        scolr = $random; scol = $random; sspd = $random;
        $display("  参数：z=%b show=%b alpha=%h motion=%b sel=%0d/%0d sub_ovr=%0d", lz, show, la, lm, selen, sel, sovr);
    end
endtask
initial begin
    #200 rst_n = 1'b1;
    // 字幕文字（64 格）和串口点阵
    for (i = 0; i < 64; i = i + 1) begin
        @(posedge sd_clk) we = 1; wa = 8'd128 + i; wd = (i % 5 == 0) ? 11'h020 : (i % 3 == 0) ? {3'b001, 1'b1, 7'd0} | (i * 3) : 11'h041 + (i % 26);
    end
    @(posedge sd_clk) we = 0;
    for (i = 0; i < 1024; i = i + 1) begin @(posedge sd_clk) bwe = 1; ba = i; bd = $random; end
    @(posedge sd_clk) bwe = 0;
    // 第 1 组：默认层序、全部显示、透明度 100%
    lx = {7'd0, 7'd60, 7'd0, 7'd8}; ly = {6'd50, 6'd10, 6'd0, 6'd4}; la = 16'haaaa; lm = 0; show = 4'b1011;
    wait_frames(2);  cmp_on = 1;
    wait_frames(1);
    $display("  第 1 组：比较 %0d 点，叠加像素 %0d，差异 %0d", ncmp, nlit, nbad);
    // 三层叠在一起（台标 (8,48)、字幕条 y=48、频谱 (0,40)），半透明，换 3 种层序：检查多层先后顺序
    for (t = 0; t < 3; t = t + 1) begin
        cmp_on = 0;
        lx = {7'd0, 7'd0, 7'd2, 7'd1};  ly = {6'd5, 6'd0, 6'd6, 6'd6};  la = {4'd6, 4'd10, 4'd7, 4'd5};  lm = 0;  show = 4'b1011;
        lz = (t == 0) ? {2'd0, 2'd1, 2'd2, 2'd3} : (t == 1) ? {2'd3, 2'd2, 2'd0, 2'd1} : {2'd1, 2'd3, 2'd2, 2'd0};
        selen = 1; sel = 2'd0;
        wait_frames(2); cmp_on = 1; wait_frames(1);
        $display("  叠层 z=%b：累计比较 %0d 点，叠加像素 %0d，差异 %0d", lz, ncmp, nlit, nbad);
    end
    repeat (4) begin
        cmp_on = 0; randomize; wait_frames(2); cmp_on = 1; wait_frames(1);
        $display("  累计：比较 %0d 点，叠加像素 %0d，差异 %0d", ncmp, nlit, nbad);
    end
    if (nbad == 0 && nlit > 50000) $display("RESULT: PASS（8 组参数逐像素相同）");
    else $display("RESULT: FAIL（差异 %0d，叠加像素 %0d）", nbad, nlit);
    $finish;
end
endmodule
