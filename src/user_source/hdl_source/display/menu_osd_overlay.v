`timescale 1ns/1ps

// R1 功能页 OSD 菜单叠加（video_clk 域，组合叠加，不改变 hs/vs/de 对齐，接法同 promax_audio_waveform）
// 右上角半透明框，两行 × 20 字；5x7 字形放大 2 倍（10x14），字距 12、行距 18。第 1 行黄色，第 2 行白色。
// 文字来自 page_menu_ctrl（sd_card_clk 域）：text_toggle 翻转后整组拷贝 text_in（源端翻转后至少 1024 拍不变）。
module menu_osd_overlay #(
    parameter integer BOX_X = 384,
    parameter integer BOX_Y = 4,
    parameter integer COLS  = 20
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         vsync,
    input  wire         de,
    input  wire [23:0]  rgb_in,
    input  wire [9:0]   pixel_x,
    input  wire         visible_async,   // sd_card_clk 域
    input  wire [319:0] text_in,         // sd_card_clk 域，toggle 握手
    input  wire         text_toggle,
    output wire [23:0]  rgb_out
);
    localparam integer TX = BOX_X + 6;
    localparam integer TY = BOX_Y + 5;
    localparam integer BOX_W = COLS * 12 + 10;
    localparam integer BOX_H = 18 * 2 + 8;

    // ---------------- 跨域：可见标志 + 文字 ----------------
    reg vis_s1, vis_s2;
    reg tg_s1, tg_s2, tg_s3;
    reg [319:0] text;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vis_s1 <= 1'b0;  vis_s2 <= 1'b0;
            tg_s1 <= 1'b0;  tg_s2 <= 1'b0;  tg_s3 <= 1'b0;
            text <= {40{8'h20}};
        end else begin
            vis_s1 <= visible_async;  vis_s2 <= vis_s1;
            tg_s1 <= text_toggle;  tg_s2 <= tg_s1;  tg_s3 <= tg_s2;
            if (tg_s2 != tg_s3)
                text <= text_in;
        end
    end

    // ---------------- 行 / 列计数 ----------------
    reg [11:0] line_y;
    reg de_q, vs_q;
    reg vis_f;                          // 整帧锁存的可见标志
    reg [4:0] cx;                       // 字符列 0..COLS-1
    reg [3:0] px;                       // 字符内列 0..11
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0;  de_q <= 1'b0;  vs_q <= 1'b1;  vis_f <= 1'b0;
            cx <= 5'd0;  px <= 4'd0;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            if (vs_q && !vsync)
                vis_f <= vis_s2;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;
            // pixel_x 在有效行内每拍加 1：在 TX-1 那一拍清零，下一拍对应字符 0 的第 0 列
            if (de && pixel_x == TX - 1) begin
                cx <= 5'd0;  px <= 4'd0;
            end else if (px == 4'd11) begin
                px <= 4'd0;  cx <= cx + 5'd1;
            end else
                px <= px + 4'd1;
        end
    end

    wire in_box = vis_f && de &&
                  pixel_x >= BOX_X && pixel_x < BOX_X + BOX_W &&
                  line_y  >= BOX_Y && line_y  < BOX_Y + BOX_H;
    wire on_border = in_box && (pixel_x == BOX_X || pixel_x == BOX_X + BOX_W - 1 ||
                                line_y == BOX_Y || line_y == BOX_Y + BOX_H - 1);

    wire in_tx = pixel_x >= TX && pixel_x < TX + COLS * 12;
    wire [11:0] ty = line_y - TY;
    wire in_ty = line_y >= TY && line_y < TY + 36;
    wire second = (ty >= 12'd18);
    wire [4:0] pr = second ? ty[4:0] - 5'd18 : ty[4:0];

    // 第 cx 个字：第 1 行在 text[319 -: 160]，第 2 行在 text[159 -: 160]，每行最高字节是第 0 个字
    wire [8:0] bitpos = (second ? 9'd159 : 9'd319) - {cx, 3'd0};
    wire [7:0] ch = text[bitpos -: 8];

    wire [4:0] glyph;
    font5x7_rom u_font (.ch(ch[6:0]), .row(pr[3:1]), .bits(glyph));
    wire lit = in_box && in_tx && in_ty && px < 4'd10 && pr < 5'd14 && glyph[3'd4 - px[3:1]];

    // 背景：原画面压暗到 1/4 再加深蓝底
    wire [23:0] dim = {2'b00, rgb_in[23:18], 2'b00, rgb_in[15:10], 2'b00, rgb_in[7:2]} + 24'h101830;

    assign rgb_out = !in_box   ? rgb_in :
                     lit       ? (second ? 24'hffffff : 24'hffd040) :
                     on_border ? 24'hffd040 : dim;
endmodule
