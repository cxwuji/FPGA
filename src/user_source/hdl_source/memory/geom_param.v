`timescale 1ns/1ps

// R5 画面变换参数（ctrl_clk 域）：把画面页的设置换算成源坐标 DDA 参数，全部用移位 / 加法 / 逐位除法，不占 DSP。
//   输出像素 (x, y) 对应源像素 u = startx + x·stepx，v = starty + y·stepy（16.16 定点），镜像 / 翻转后 u' = W-1-u，v' = H-1-v；
//   超出 0..W-1 / 0..H-1 的地方显示黑色。缩放以画面中心为中心：start = C - C_out·step + 平移。
//   step = 1 / 倍数：倍数 s 用 1/64 单位（16 = 0.25 倍 .. 256 = 4 倍），step = 2^22 / s（逐位除法，约 25 拍算一次）。
// 推拉摇移（kenburns）：倍数在 1.00 ~ 1.50 之间慢慢来回（约 8 秒一个来回），横向平移在 ±48 点之间来回，覆盖手动缩放 / 平移。
// enable = 0（缩略图 / 急救 / 显示未打开）：恒等变换（step = 1、start = 0、不镜像不翻转）。
module geom_param #(
    parameter integer CLKS_PER_MS = 100_000,
    parameter integer W = 640,
    parameter integer H = 480
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               enable,
    input  wire [4:0]         sx_q,           // 1~16 = 0.25~4.00 倍
    input  wire [4:0]         sy_q,
    input  wire               mirror,
    input  wire               flip,
    input  wire signed [5:0]  panx,           // 单位 16 点（源像素）
    input  wire signed [5:0]  pany,
    input  wire               kenburns,
    output reg  [31:0]        stepx,
    output reg  signed [31:0] startx,
    output reg  [31:0]        stepy,
    output reg  signed [31:0] starty,
    output reg                mirror_o,
    output reg                flip_o
);
    localparam integer CX = W / 2, CY = H / 2;
    localparam integer KB_TICK = 16 * CLKS_PER_MS;          // 约 60 次 / 秒

    // ---------------- 推拉摇移动画 ----------------
    reg [27:0] kb_div;
    reg [6:0]  kb_s;            // 64..96（1.00 ~ 1.50 倍，1/64 单位）
    reg        kb_sdir;
    reg signed [7:0] kb_px;     // -48..48 源像素
    reg        kb_pdir;
    reg [1:0]  kb_ph;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            kb_div <= 28'd0; kb_s <= 7'd64; kb_sdir <= 1'b1; kb_px <= 8'sd0; kb_pdir <= 1'b1; kb_ph <= 2'd0;
        end else if (!kenburns) begin
            kb_div <= 28'd0; kb_s <= 7'd64; kb_sdir <= 1'b1; kb_px <= 8'sd0; kb_pdir <= 1'b1; kb_ph <= 2'd0;
        end else if (kb_div >= KB_TICK - 1) begin
            kb_div <= 28'd0;
            kb_ph  <= kb_ph + 2'd1;
            if (kb_ph[0]) begin                              // 倍数每 2 tick 变 1/64：约 1 秒 0.25 倍
                if (kb_sdir) begin if (kb_s >= 7'd96) kb_sdir <= 1'b0; else kb_s <= kb_s + 7'd1; end
                else         begin if (kb_s <= 7'd64) kb_sdir <= 1'b1; else kb_s <= kb_s - 7'd1; end
            end
            if (kb_pdir) begin if (kb_px >= 8'sd48) kb_pdir <= 1'b0; else kb_px <= kb_px + 8'sd1; end
            else         begin if (kb_px <= -8'sd48) kb_pdir <= 1'b1; else kb_px <= kb_px - 8'sd1; end
        end else
            kb_div <= kb_div + 28'd1;
    end

    // ---------------- 目标参数（寄存）----------------
    reg [8:0]  tsx, tsy;        // 倍数，1/64 单位
    reg signed [12:0] tpx, tpy; // 平移，源像素
    reg tm, tf;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tsx <= 9'd64; tsy <= 9'd64; tpx <= 13'sd0; tpy <= 13'sd0; tm <= 1'b0; tf <= 1'b0;
        end else if (!enable) begin
            tsx <= 9'd64; tsy <= 9'd64; tpx <= 13'sd0; tpy <= 13'sd0; tm <= 1'b0; tf <= 1'b0;
        end else begin
            tsx <= kenburns ? {2'b00, kb_s} : {sx_q, 4'b0000};
            tsy <= kenburns ? {2'b00, kb_s} : {sy_q, 4'b0000};
            tpx <= kenburns ? {{5{kb_px[7]}}, kb_px} : {{3{panx[5]}}, panx, 4'b0000};
            tpy <= kenburns ? 13'sd0 : {{3{pany[5]}}, pany, 4'b0000};
            tm  <= mirror;
            tf  <= flip;
        end
    end

    // ---------------- 逐位除法 2^22 / s，x / y 轮流算 ----------------
    reg        axis;            // 0 = x, 1 = y
    reg [4:0]  it;
    reg [22:0] rem;
    reg [22:0] quo;
    reg [8:0]  dv;
    reg signed [12:0] pan_l;
    reg        ml, fl;
    reg [2:0]  ph;              // 0 准备 1 除法 2 取商 4 算 C·step 3 输出
    wire [23:0] rem_sh = {rem, quo[22]};
    wire [23:0] trial  = rem_sh - {15'd0, dv};
    reg  [31:0] stp;
    // C·step：640x480 时 320 = 256 + 64，240 = 256 - 16（移位相加）；其他尺寸（仿真）直接乘
    wire [31:0] c_step = (W == 640 && H == 480) ?
                         (axis ? ({stp[23:0], 8'd0} - {stp[27:0], 4'd0}) : ({stp[23:0], 8'd0} + {stp[25:0], 6'd0})) :
                         (axis ? stp * CY : stp * CX);
    localparam signed [31:0] CXF = CX <<< 16;
    localparam signed [31:0] CYF = CY <<< 16;
    // R8-5b 时序：C·step（移位相加）先寄存，下一拍再做减法 + 平移（原来 stp -> 5 级加法 -> startx 一拍，-0.2~-2.1ns）
    reg  [31:0] c_step_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axis <= 1'b0; it <= 5'd0; rem <= 23'd0; quo <= 23'd0; dv <= 9'd64; pan_l <= 13'sd0; ml <= 1'b0; fl <= 1'b0; ph <= 3'd0;
            stp <= 32'd65536;  c_step_r <= 32'd0;
            stepx <= 32'd65536; startx <= 32'sd0; stepy <= 32'd65536; starty <= 32'sd0; mirror_o <= 1'b0; flip_o <= 1'b0;
        end else begin
            case (ph)
                3'd0: begin
                    dv    <= axis ? tsy : tsx;
                    pan_l <= axis ? tpy : tpx;
                    ml <= tm; fl <= tf;
                    rem <= 23'd0; quo <= 23'h400000;    // 被除数 2^22 从高位移入
                    it  <= 5'd0;
                    ph  <= 3'd1;
                end
                3'd1: begin
                    // 恢复余数除法：每拍移入一位
                    if (!trial[23]) begin rem <= trial[22:0]; quo <= {quo[21:0], 1'b1}; end
                    else            begin rem <= rem_sh[22:0]; quo <= {quo[21:0], 1'b0}; end
                    it <= it + 5'd1;
                    if (it == 5'd22) ph <= 3'd2;
                end
                3'd2: begin
                    stp <= {9'd0, quo};
                    ph  <= 3'd4;
                end
                3'd4: begin
                    c_step_r <= c_step;
                    ph       <= 3'd3;
                end
                default: begin
                    if (axis) begin
                        stepy <= stp;  starty <= (axis ? CYF : CXF) - $signed(c_step_r) + {{3{pan_l[12]}}, pan_l, 16'd0};
                        flip_o <= fl;
                    end else begin
                        stepx <= stp;  startx <= (axis ? CYF : CXF) - $signed(c_step_r) + {{3{pan_l[12]}}, pan_l, 16'd0};
                        mirror_o <= ml;
                    end
                    axis <= ~axis;
                    ph   <= 3'd0;
                end
            endcase
        end
    end
endmodule
