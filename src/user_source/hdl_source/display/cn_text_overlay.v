`timescale 1ns/1ps

// R1.5b 中文 OSD 文字层（video_clk 域，接法同 menu_osd_overlay：不改变 hs/vs/de 对齐，只换 rgb）
// 三个框，同一时刻一个像素只落在一个框里，所以共用一个文字 RAM 读口和一个字库 ROM：
//   S 状态栏：左上 (4,4)，2 行 × 24 半宽格，常驻；文字白色，边框青色
//     R8-2b：stat_on 时才显示（急救中强制显示），平时 4 行（框高 80，第三行在文字 RAM 192~215，R8-5c 第四行原图分辨率在 120~127 / 216~223 / 248~255），急救中 3 行（框高 62）
//   M 设置菜单：右上 (432,4)，2 行 × 24 格，menu_vis 时显示；第 1 行黄色、第 2 行白色（R8-2b：显示页 menu_disp 两行都白色）
//   H 提示条：居中 (116,HY)，1 行 × 24 格，字放大 2 倍；hint_show 时显示，hint_leave 时每帧上移 3 点并淡出（16 帧）
//     R7b-2：急救中（cpr_async）提示条改放底部 (116,HY_CPR)，当底栏短句用（PIC5 底部 y 408~479 留的纯色区）
//   F 故障条（R4）：正中 (116,FY)，1 行 × 24 格，2 倍字，红底白字红边；fault_show 时闪烁（亮 40 帧 / 灭 20 帧），有故障时提示条不出现
//     R11：急救正中黄框（note_show_async：准备好后按K3 / 到了两分钟）借同一个位置和同一段文字 RAM，压暗底、黄边黄字、不闪；有故障时不画
//     R12：开机读图「正在读取图片 n/m」也用黄框（不在急救中），黄框不再按急救门控（page_menu_ctrl 里已经判断好）
// 文字 RAM 256 × 10 位（地址 0~47 状态栏、48~95 菜单、96~119 提示条、192~215 状态栏第三行、224~247 故障条、120~127 + 216~223 + 248~255 状态栏第四行，每行 24 格），sd_card_clk 侧逐字节写入；
//   每格 {右半, 页, 码}（写入方把汉字的两字节 {8'h80|k, 8'h7F/7E} 转成这个格式；地址 128 以上是字幕条，归 layer_compositor）。
//   整帧里可能有一帧新旧文字混合，看不出来。
// 字库 cn_font16.hex（tools/gen_cn_font.py 生成）：地址 {idx[9:0], row[3:0]}，每字节 = 半字宽 8 点一行，最高位在左。
//   第二个读口 fb_addr / fb_q 给 layer_compositor 画字幕条（同一个 BRAM 双口读，不另占字库）。
// 流水线：按 pixel_x + 3 提前算框 / 格 / 行 -> 文字 RAM（1 拍）-> 字库 ROM（1 拍）-> 当前像素合成。
`ifndef CN_FONT_HEX
`define CN_FONT_HEX "cn_font16.hex"     // TD：相对本源文件所在目录（HDL-5105 规则 i）；仿真在 tb 里另行 define
`endif
module cn_text_overlay #(
    parameter integer SX = 4,   parameter integer SY = 4,
    parameter integer MX = 432, parameter integer MY = 4,
    parameter integer HX = 116, parameter integer HY = 120,
    parameter integer HY_CPR = 424,
    parameter integer FY = 218
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    // sd_card_clk 域
    input  wire        wclk,
    input  wire        we,
    input  wire [7:0]  waddr,
    input  wire [10:0] wdata,
    input  wire        menu_vis_async,
    input  wire        hint_show_async,
    input  wire        hint_leave_async,
    input  wire        fault_show_async,
    input  wire        cpr_async,                    // R7b-2：急救中（sd_card_clk 域电平）
    input  wire        note_show_async,              // R11：急救正中黄框（sd_card_clk 域寄存器输出）
    input  wire        stat_on_async,                // R8-2b：状态栏开（sd_card_clk 域电平）
    input  wire        menu_disp_async,              // R8-2b：菜单框是显示页（两行都白色）
    input  wire [13:0] fb_addr,                      // 字库第二读口（video_clk 域，1 拍延迟）
    output reg  [7:0]  fb_q,
    output wire [23:0] rgb_out
);
    localparam integer COLS = 24;
    localparam integer BW1 = COLS * 8 + 12;          // 1 倍框宽 204
    localparam integer BH1 = 16 + 18 + 10;           // 2 行框高 44
    localparam integer BH3 = 16 + 18 + 18 + 18 + 10; // 4 行框高 80（R8-2b 状态栏 3 行，R8-5c 加第四行原图分辨率）
    localparam integer BHC = 16 + 18 + 18 + 10;      // R9 急救中 3 行框高 62（第三行 = 本部分按键）
    localparam integer BW2 = COLS * 16 + 24;         // 2 倍框宽 408
    localparam integer BH2 = 32 + 12;                // 1 行框高 44
    localparam integer LA  = 3;                      // 提前量

    // ---------------- 文字 RAM（双时钟）/ 字库 ROM ----------------
    reg [10:0] tram [0:255];
    always @(posedge wclk)
        if (we && waddr[7:6] != 2'b10) tram[waddr] <= wdata;

    reg [7:0] rom [0:16383];
    initial $readmemh(`CN_FONT_HEX, rom);
    always @(posedge clk) fb_q <= rom[fb_addr];

    // ---------------- 跨域 + 帧锁存 ----------------
    reg mv1, mv2, hs1, hs2, hl1, hl2, fs1, fs2, fault_f;
    reg cp1, cp2, cpr_f;
    reg nt1, nt2, note_f;
    reg st1, st2, stat_f, md1, md2, mdisp_f;
    reg [5:0] blink;
    reg vs_q, de_q;
    reg [11:0] line_y;
    reg menu_f, hint_f;
    reg [3:0] hint_fr;                               // 淡出第几帧
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mv1 <= 0; mv2 <= 0; hs1 <= 0; hs2 <= 0; hl1 <= 0; hl2 <= 0;
            vs_q <= 1'b1; de_q <= 1'b0; line_y <= 12'd0;
            menu_f <= 1'b0; hint_f <= 1'b0; hint_fr <= 4'd0;
            fs1 <= 1'b0; fs2 <= 1'b0; fault_f <= 1'b0; blink <= 6'd0;
            cp1 <= 1'b0; cp2 <= 1'b0; cpr_f <= 1'b0;
            nt1 <= 1'b0; nt2 <= 1'b0; note_f <= 1'b0;
            st1 <= 1'b0; st2 <= 1'b0; stat_f <= 1'b0; md1 <= 1'b0; md2 <= 1'b0; mdisp_f <= 1'b0;
        end else begin
            fs1 <= fault_show_async; fs2 <= fs1;
            cp1 <= cpr_async;        cp2 <= cp1;
            nt1 <= note_show_async;  nt2 <= nt1;
            st1 <= stat_on_async;    st2 <= st1;
            md1 <= menu_disp_async;  md2 <= md1;
            mv1 <= menu_vis_async;   mv2 <= mv1;
            hs1 <= hint_show_async;  hs2 <= hs1;
            hl1 <= hint_leave_async; hl2 <= hl1;
            vs_q <= vsync;  de_q <= de;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;
            if (vs_q && !vsync) begin
                menu_f <= mv2;
                cpr_f  <= cp2;
                note_f <= nt2;
                stat_f <= st2 | cp2;
                mdisp_f <= md2;
                blink  <= (blink == 6'd59 || !fs2) ? 6'd0 : blink + 6'd1;
                fault_f <= fs2;
                if (hs2) begin
                    hint_f <= 1'b1;  hint_fr <= 4'd0;
                end else if (hl2 && hint_f) begin
                    if (hint_fr != 4'd15) hint_fr <= hint_fr + 4'd1;
                end else begin
                    hint_f <= 1'b0;  hint_fr <= 4'd0;
                end
            end
        end
    end
    wire [11:0] hy0 = cpr_f ? HY_CPR : HY - {hint_fr, 1'b0} - hint_fr;     // HY - 3 × 帧；急救中固定在底部
    wire [4:0]  alpha = 5'd16 - {1'b0, hint_fr};

    // ---------------- 第 0 级：提前 LA 点算框 / 格 ----------------
    wire [10:0] xa = {1'b0, pixel_x} + LA;
    wire [11:0] y  = line_y;

    function inbox;
        input [10:0] x; input [11:0] yy; input [10:0] x0; input [11:0] y0; input [10:0] w; input [11:0] h;
        inbox = (x >= x0) && (x < x0 + w) && (yy >= y0) && (yy < y0 + h);
    endfunction
    function onedge;
        input [10:0] x; input [11:0] yy; input [10:0] x0; input [11:0] y0; input [10:0] w; input [11:0] h;
        onedge = (x == x0) || (x == x0 + w - 1) || (yy == y0) || (yy == y0 + h - 1);
    endfunction

    wire        s3l = cpr_f;                         // R9：急救中 3 行
    wire [11:0] sbh = s3l ? BHC : BH3;
    wire s_box = stat_f && inbox(xa, y, SX, SY, BW1, sbh);
    wire m_box = menu_f && inbox(xa, y, MX, MY, BW1, BH1);
    wire f_on  = fault_f && (blink < 6'd40);
    wire f_box = f_on && inbox(xa, y, HX, FY, BW2, BH2);
    wire n_box = note_f && !fault_f && inbox(xa, y, HX, FY, BW2, BH2);   // R11 急救正中黄框
    wire h_box = hint_f && !fault_f && inbox(xa, y, HX, hy0, BW2, BH2);

    // 1 倍框：文字区 (x0+6, y0+5)，两行行距 18
    wire [10:0] s_tx = xa - (SX + 6);   wire [11:0] s_ty = y - (SY + 5);
    wire [10:0] m_tx = xa - (MX + 6);   wire [11:0] m_ty = y - (MY + 5);
    wire [10:0] h_tx = xa - (HX + 12);  wire [11:0] h_ty = y - (hy0 + 6);
    wire [11:0] f_ty = y - (FY + 6);
    wire s_txt = s_tx < COLS * 8  && (s_ty < 16 || (s_ty >= 18 && s_ty < 34) || (s_ty >= 36 && s_ty < 52) || (!s3l && s_ty >= 54 && s_ty < 70));
    wire m_txt = m_tx < COLS * 8  && m_ty < 34 && (m_ty < 16 || m_ty >= 18);
    wire h_txt = h_tx < COLS * 16 && h_ty < 32;
    wire f_txt = h_tx < COLS * 16 && f_ty < 32;

    reg        r1_box, r1_edge, r1_txt, r1_l2, r1_note;
    reg [1:0]  r1_which;                 // 0 S / 1 M / 2 H / 3 F（R11：r1_note = 3 号框画成黄框）
    reg [7:0]  r1_addr;
    reg [3:0]  r1_row;
    reg [2:0]  r1_cp;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r1_box <= 0; r1_edge <= 0; r1_txt <= 0; r1_l2 <= 0; r1_which <= 0; r1_addr <= 0; r1_row <= 0; r1_cp <= 0; r1_note <= 0;
        end else begin
            r1_box  <= s_box | m_box | h_box | f_box | n_box;
            r1_note <= n_box;
            if (f_box | n_box) begin
                r1_which <= 2'd3;
                r1_edge  <= onedge(xa, y, HX, FY, BW2, BH2);
                r1_txt   <= f_txt;
                r1_l2    <= 1'b0;
                r1_addr  <= 8'd224 + h_tx[8:4];
                r1_row   <= f_ty[4:1];
                r1_cp    <= h_tx[3:1];
            end else if (h_box) begin
                r1_which <= 2'd2;
                r1_edge  <= onedge(xa, y, HX, hy0, BW2, BH2);
                r1_txt   <= h_txt;
                r1_l2    <= 1'b0;
                r1_addr  <= 8'd96 + h_tx[8:4];
                r1_row   <= h_ty[4:1];
                r1_cp    <= h_tx[3:1];
            end else if (m_box) begin
                r1_which <= 2'd1;
                r1_edge  <= onedge(xa, y, MX, MY, BW1, BH1);
                r1_txt   <= m_txt;
                r1_l2    <= (m_ty >= 18);
                r1_addr  <= 8'd48 + ((m_ty >= 18) ? 8'd24 : 8'd0) + m_tx[7:3];
                r1_row   <= (m_ty >= 18) ? m_ty[3:0] - 4'd2 : m_ty[3:0];
                r1_cp    <= m_tx[2:0];
            end else begin
                r1_which <= 2'd0;
                r1_edge  <= onedge(xa, y, SX, SY, BW1, sbh);
                r1_txt   <= s_txt;
                r1_l2    <= (s_ty >= 18);
                // R8-5c 第四行 24 格分三段放在 RAM 120~127 / 216~223 / 248~255
                r1_addr  <= (s_ty >= 54) ? ((s_tx[7:6] == 2'd0) ? {5'b01111, s_tx[5:3]} : (s_tx[7:6] == 2'd1) ? {5'b11011, s_tx[5:3]} : {5'b11111, s_tx[5:3]}) :
                            ((s_ty >= 36) ? 8'd192 : (s_ty >= 18) ? 8'd24 : 8'd0) + s_tx[7:3];
                r1_row   <= (s_ty >= 54) ? s_ty[3:0] - 4'd6 : (s_ty >= 36) ? s_ty[3:0] - 4'd4 : (s_ty >= 18) ? s_ty[3:0] - 4'd2 : s_ty[3:0];
                r1_cp    <= s_tx[2:0];
            end
        end
    end

    // ---------------- 第 1 级：读文字 RAM ----------------
    reg [10:0] tq;
    always @(posedge clk) tq <= tram[r1_addr];
    reg        r2_box, r2_edge, r2_txt, r2_l2, r2_note;
    reg [1:0]  r2_which;
    reg [3:0]  r2_row;
    reg [2:0]  r2_cp;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r2_box <= 0; r2_edge <= 0; r2_txt <= 0; r2_l2 <= 0; r2_which <= 0; r2_row <= 0; r2_cp <= 0; r2_note <= 0;
        end else begin
            r2_box <= r1_box; r2_edge <= r1_edge; r2_txt <= r1_txt; r2_l2 <= r1_l2; r2_note <= r1_note;
            r2_which <= r1_which; r2_row <= r1_row; r2_cp <= r1_cp;
        end
    end

    // ---------------- 第 2 级：读字库 ----------------
    // 格 {右半, 页, 码}：汉字页 0 / 1 / 2 的字形从 512 / 768 / 256 号开始（R8-1b），ASCII 字形号 = 码值
    wire [9:0] idx = tq[7] ? {~tq[9], tq[9] | tq[8], tq[6:0], tq[10]} : {3'b000, tq[6:0]};
    reg [7:0] fq;
    always @(posedge clk) fq <= rom[{idx, r2_row}];
    reg        r3_box, r3_edge, r3_txt, r3_l2, r3_note;
    reg [1:0]  r3_which;
    reg [2:0]  r3_cp;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r3_box <= 0; r3_edge <= 0; r3_txt <= 0; r3_l2 <= 0; r3_which <= 0; r3_cp <= 0; r3_note <= 0;
        end else begin
            r3_box <= r2_box; r3_edge <= r2_edge; r3_txt <= r2_txt; r3_l2 <= r2_l2; r3_note <= r2_note;
            r3_which <= r2_which; r3_cp <= r2_cp;
        end
    end

    // ---------------- 第 3 级：合成当前像素 ----------------
    wire lit = r3_txt && fq[3'd7 - r3_cp];
    wire [23:0] dim = {2'b00, rgb_in[23:18], 2'b00, rgb_in[15:10], 2'b00, rgb_in[7:2]} + 24'h101830;
    wire [23:0] fg  = (r3_which == 2'd1) ? ((r3_l2 || mdisp_f) ? 24'hffffff : 24'hffd040) : r3_note ? 24'hffd040 : 24'hffffff;
    wire [23:0] bc  = (r3_which == 2'd0) ? 24'h40c0ff : (r3_which == 2'd3 && !r3_note) ? 24'hff4040 : 24'hffd040;
    wire [23:0] red = {1'b1, rgb_in[23:17], 3'b000, rgb_in[15:11], 3'b000, rgb_in[7:3]};   // 故障条底色：压暗 + 偏红
    wire [23:0] tgt = lit ? fg : r3_edge ? bc : (r3_which == 2'd3 && !r3_note) ? red : dim;

    // 提示条淡出：out = rgb + (tgt - rgb) × alpha / 16
    function [7:0] mixc;
        input [7:0] t; input [7:0] b; input [4:0] a;
        reg signed [9:0]  d;
        reg signed [15:0] p;
        begin
            d = {2'b00, t} - {2'b00, b};
            p = d * $signed({1'b0, a});
            mixc = b + p[11:4];
        end
    endfunction
    wire [23:0] mixed = {mixc(tgt[23:16], rgb_in[23:16], alpha),
                         mixc(tgt[15:8],  rgb_in[15:8],  alpha),
                         mixc(tgt[7:0],   rgb_in[7:0],   alpha)};

    assign rgb_out = !(de && r3_box) ? rgb_in :
                     (r3_which == 2'd2) ? mixed : tgt;
endmodule
