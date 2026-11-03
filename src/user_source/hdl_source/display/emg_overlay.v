`timescale 1ns/1ps

// R9 急救画面叠加层（video_clk 域，接在 layer_compositor 和 cn_text_overlay 之间；不改 hs/vs/de 对齐，只换 rgb）
// 急救中（en_async）才画，三样东西互不重叠：
//   进度框：深红 3 像素框，框住 PIC6 当前这一栏（part 1 / 2 / 3；交接页不画）。栏坐标按 PIC6 板上版（y 86~391）量出：
//     第 1 栏 x 4~189、第 2 栏 196~431、第 3 栏 437~635，框画在栏外 3 像素的缝里
//   位置条：(224,50) 412×22，压暗底 + 黄边，黄字 = 位置点阵（512×16 黑白，显示前 404 列）。
//     点阵 RAM 1 KB：上电是片内默认（display/loc_default.hex），开机读到 SAVE.BIN 里的位置 / 电脑串口改了就整块重写（wclk 域写口）；
//     wclk 域另有一个读口 loc_ra / loc_q（sd_card_bmp 写回 SAVE.BIN 时按字节读，真双口 BRAM，不另存一份）
//   民法典角标：片内 ROM 348×24 1 位墨点（tools/gen_badge.py，每行按 512 点存；胶囊形状 / 颜色由 include/badge_shape.vh 算），
//     中心 (320,409)，每拍「变大 -> 变小」一次：
//     beat（sd_card_clk 域单拍，toggle 过域）后第 0 帧起按 lvl_of(帧数) 1.06 -> 1.15 -> 1.00 倍，约 250 ms；
//     33 帧（≈ 545 ms，110 次/分）没有新拍就自己再跳一次（① ③ 不按压时也一直在跳）。
//     缩放 = 最近邻：每档宽 / 高 / 左上角 / Q12 步长查表（include/badge_tab.vh），逐点 / 逐行累加步长取整数部分当源坐标，不用乘法器
// 流水线：pixel_x + 2 提前算 -> 寄存（地址）-> 读 RAM / ROM -> 当前像素合成。
`ifndef BADGE_HEX
`define BADGE_HEX "badge_rom.hex"       // TD：相对本源文件所在目录；仿真在 tb 里另行 define
`endif
`ifndef LOC_HEX
`define LOC_HEX "loc_default.hex"
`endif
module emg_overlay #(
    parameter integer LX = 224, parameter integer LY = 50, parameter integer LW = 412, parameter integer LH = 22,
    parameter integer FY0 = 83, parameter integer FY1 = 394
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [9:0]  pixel_x,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out,
    input  wire        en_async,                 // 急救中（sd_card_clk 域电平）
    input  wire [1:0]  part_async,               // 进度框：0 不画 / 1~3 第几栏
    input  wire        beat_tog,                 // sd_card_clk 域：每拍翻转一次
    // 位置点阵写口（sd_card_clk 域）
    input  wire        wclk,
    input  wire        loc_we,
    input  wire [9:0]  loc_addr,
    input  wire [7:0]  loc_data,
    input  wire [9:0]  loc_ra,                   // wclk 域读口（写回 TF 卡用，1 拍延迟）
    output reg  [7:0]  loc_q
);
`include "../user_source/hdl_source/include/badge_shape.vh"
    // ---------------- 存储 ----------------
    reg [7:0] loc [0:1023];
    initial $readmemh(`LOC_HEX, loc);
    always @(posedge wclk) begin
        if (loc_we) loc[loc_addr] <= loc_data;
        loc_q <= loc[loc_we ? loc_addr : loc_ra];
    end
    reg badge [0:12287];
    initial $readmemh(`BADGE_HEX, badge);

    // ---------------- 过域 + 帧锁存 ----------------
    (* async_reg = "true" *) reg en1, en2, bt1, bt2;
    reg        bt3;
    reg [1:0]  pt1, pt2;
    reg        vs_q, de_q;
    reg [9:0]  line_y;
    reg        en_f;
    reg [1:0]  part_f;
    reg [5:0]  fr;                               // 上一拍以来第几帧
    reg        beat_seen;
    reg [2:0]  lvl;
    reg [9:0]  t_xm1, t_x1, t_y0, t_y1;     // 角标框：左边 - 1 / 右边 + 1 / 上 / 下 + 1（查表，不在像素路径上做加法）
    reg [12:0] t_inv;
    wire       frame_start = vs_q && !vsync;
    function [2:0] lvl_of;                       // 帧 -> 档位：3 帧冲到最大，再用 12 帧回落
        input [5:0] f;
        case (f)
            6'd0: lvl_of = 3'd4;  6'd1: lvl_of = 3'd6;  6'd2: lvl_of = 3'd7;  6'd3: lvl_of = 3'd7;
            6'd4: lvl_of = 3'd6;  6'd5: lvl_of = 3'd6;  6'd6: lvl_of = 3'd5;  6'd7: lvl_of = 3'd5;
            6'd8: lvl_of = 3'd4;  6'd9: lvl_of = 3'd3;  6'd10: lvl_of = 3'd3; 6'd11: lvl_of = 3'd2;
            6'd12: lvl_of = 3'd2; 6'd13: lvl_of = 3'd1; 6'd14: lvl_of = 3'd1; default: lvl_of = 3'd0;
        endcase
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            en1 <= 1'b0; en2 <= 1'b0; bt1 <= 1'b0; bt2 <= 1'b0; bt3 <= 1'b0; pt1 <= 2'd0; pt2 <= 2'd0;
            vs_q <= 1'b1; de_q <= 1'b0; line_y <= 10'd0; en_f <= 1'b0; part_f <= 2'd0;
            fr <= 6'd32; beat_seen <= 1'b0; lvl <= 3'd0;
        end else begin
            en1 <= en_async;   en2 <= en1;
            pt1 <= part_async; pt2 <= pt1;
            bt1 <= beat_tog;   bt2 <= bt1;  bt3 <= bt2;
            vs_q <= vsync;  de_q <= de;
            if (!vsync)
                line_y <= 10'd0;
            else if (de_q && !de)
                line_y <= line_y + 10'd1;
            if (bt2 != bt3)
                beat_seen <= 1'b1;
            if (frame_start) begin
                en_f   <= en2;
                part_f <= pt2;
                beat_seen <= 1'b0;
                if (beat_seen || fr >= 6'd32) begin   // 有新拍 / 33 帧没拍：从头跳
                    fr  <= 6'd0;
                    lvl <= lvl_of(6'd0);
                end else begin
                    fr  <= fr + 6'd1;
                    lvl <= lvl_of(fr + 6'd1);
                end
            end
        end
    end
    // 档位参数（每帧开头查表，帧内不变）
    always @(posedge clk)
`include "../user_source/hdl_source/include/badge_tab.vh"

    // ---------------- 第 0 级：提前 2 点 ----------------
    wire [10:0] xa = {1'b0, pixel_x} + 11'd2;
    wire [9:0]  y  = line_y;
    // 进度框：左右边界每帧查一次（框外 fx0~fx1、框内 fi0~fi1），像素路径上只做比较
    reg  [9:0]  fx0, fx1, fi0, fi1;
    reg         f_on;
    always @(posedge clk) begin
        f_on <= en_f && (part_f != 2'd0);
        case (part_f)
            2'd1:    begin fx0 <= 10'd1;   fx1 <= 10'd192; fi0 <= 10'd4;   fi1 <= 10'd189; end
            2'd2:    begin fx0 <= 10'd193; fx1 <= 10'd434; fi0 <= 10'd196; fi1 <= 10'd431; end
            default: begin fx0 <= 10'd434; fx1 <= 10'd638; fi0 <= 10'd437; fi1 <= 10'd635; end
        endcase
    end
    wire f_row = (y >= FY0) && (y <= FY1);
    wire f_mid = (y >= FY0 + 3) && (y <= FY1 - 3);
    wire f_out = (xa >= fx0) && (xa <= fx1);
    wire f_in  = (xa >= fi0) && (xa <= fi1) && f_mid;
    wire f_hit = f_on && f_row && f_out && !f_in;
    // 位置条
    wire        l_box  = en_f && (xa >= LX) && (xa < LX + LW) && (y >= LY) && (y < LY + LH);
    wire        l_edge = (xa == LX) || (xa == LX + LW - 1) || (y == LY) || (y == LY + LH - 1);
    wire [10:0] l_tx   = xa - (LX + 4);
    wire [9:0]  l_ty   = y - (LY + 3);
    wire        l_txt  = (l_tx < 11'd404) && (l_ty < 10'd16);
    // 角标：逐点 / 逐行累加 Q12 步长，整数部分 = 源坐标
    wire        b_row  = (y >= t_y0) && (y < t_y1);
    wire        b_box  = en_f && b_row && (xa > t_xm1) && (xa < t_x1);
    reg  [21:0] acc_x;
    reg  [17:0] acc_y;
    always @(posedge clk) begin
        if (xa == {1'b0, t_xm1})
            acc_x <= {10'd0, t_inv[12:1]};       // 第一个点取源像素中心
        else
            acc_x <= acc_x + t_inv;
        if (!vsync)
            acc_y <= {6'd0, t_inv[12:1]};
        else if (de_q && !de && line_y + 10'd1 > t_y0)
            acc_y <= acc_y + t_inv;
    end
    wire [8:0] b_sx = acc_x[20:12];
    wire [4:0] b_sy = acc_y[16:12];
    reg  [4:0] b_ins;                    // 当前源行的圆角缩进（行内不变，先寄存）
    always @(posedge clk) b_ins <= ins_of(b_sy);

    reg        r1_f, r1_l, r1_le, r1_lt, r1_b;
    reg [9:0]  r1_la;
    reg [2:0]  r1_lb;
    reg [13:0] r1_ba;
    reg        r1_bi;                    // 角标：这一点是天平那几列（墨 = 橙色）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r1_f <= 1'b0; r1_l <= 1'b0; r1_le <= 1'b0; r1_lt <= 1'b0; r1_b <= 1'b0; r1_la <= 10'd0; r1_lb <= 3'd0; r1_ba <= 14'd0;
            r1_bi <= 1'b0;
        end else begin
            r1_f  <= f_hit;
            r1_l  <= l_box;
            r1_le <= l_edge;
            r1_lt <= l_txt;
            r1_la <= {l_ty[3:0], l_tx[8:3]};
            r1_lb <= l_tx[2:0];
            // 胶囊里（每行按圆角缩进）才画：没墨 = 米黄底，有墨 = 天平 / 字
            r1_b  <= b_box && (b_sx < B_W) && (b_sy < 5'd24) &&
                     ({1'b0, b_sx} >= {5'd0, b_ins}) && ({1'b0, b_sx} < B_W - {5'd0, b_ins});
            r1_ba <= {b_sy, b_sx};
            r1_bi <= ({1'b0, b_sx} < B_ICON);
        end
    end
    // ---------------- 第 1 级：读 RAM / ROM ----------------
    reg [7:0] lq;
    reg       bq;
    always @(posedge clk) begin
        lq <= loc[r1_la];
        bq <= badge[r1_ba];
    end
    reg        r2_f, r2_l, r2_le, r2_lt, r2_b, r2_bi;
    reg [2:0]  r2_lb;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r2_f <= 1'b0; r2_l <= 1'b0; r2_le <= 1'b0; r2_lt <= 1'b0; r2_b <= 1'b0; r2_lb <= 3'd0; r2_bi <= 1'b0;
        end else begin
            r2_f <= r1_f; r2_l <= r1_l; r2_le <= r1_le; r2_lt <= r1_lt; r2_b <= r1_b; r2_lb <= r1_lb; r2_bi <= r1_bi;
        end
    end
    // ---------------- 第 2 级：合成当前像素 ----------------
    wire        l_lit = r2_lt && lq[3'd7 - r2_lb];
    wire [23:0] dim   = {2'b00, rgb_in[23:18], 2'b00, rgb_in[15:10], 2'b00, rgb_in[7:2]} + 24'h101830;
    wire [23:0] bcol  = !bq ? 24'hfbf2d0 : r2_bi ? 24'he85a2a : 24'h0e4f5c;   // 米黄底 / 橙色天平 / 深青字
    assign rgb_out = r2_f                    ? 24'hb00000 :
                     r2_b                    ? bcol :
                     r2_l                    ? ((l_lit || r2_le) ? 24'hffd040 : dim) :
                     rgb_in;
endmodule
