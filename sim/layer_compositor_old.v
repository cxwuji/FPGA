`timescale 1ns/1ps

// R3 图层合成（video_clk 域；接法同其他叠加模块：不改变 hs/vs/de 对齐，只换 rgb）
// 四个图层，位置 / 透明度 / 上下顺序 / 运动方式都由图层页设置（page_menu_ctrl，sd_card_clk 域）：
//   0 台标 LOGO  96x40，4 色（logo_rom.hex，tools/gen_logo.py 生成）
//   1 字幕 SUB   整行宽 640x24 的黑底条，白色 16x16 中文（文字 RAM 地址 128~191，字库借 cn_text_overlay 的第二读口）
//   2 画中画 PIP（R8-4b 为掉电保存腾资源删掉，图层 2 恒不显示）原 132x100（2 点白边 + 128x96）：显示"上一张图"。播放时每帧把画面按 1/10 抽样存进 64x48x9 位缓冲，
//                两块缓冲交替，换图时交换，所以显示的永远是换图前那一张（转场 / 缩略图期间不抽样）
//   3 频谱       528x64（R8-3：audio_spectrum 512 点 FFT，32 根彩虹柱 + 白色顶帽，柱子以外透明）
//                R10 资源：原来的 1 波形 / 4 音量表删掉（3 示波器 R8-2 已删），viz 端口只用来判断开关
// 运动（每帧更新）：0 不动；1 弹跳（横 2 点 / 竖 1 点每帧，碰边反向）；2 滚动（字幕条里文字右往左，其他层整体右往左循环）
// 合成：按层序 z（0 最下 3 最上）从下往上 C = C(1-a) + col·a，T = T(1-a)；最后 out = bg·T + C。a = 透明度 0~100% 的 16 级
// 图层页打开菜单时，选中的图层外面画黄色虚线框。
// R8-1c 串口替换字幕（io/uart_subtitle.v）：电脑发来的 512x16 点阵存进字幕点阵 RAM（1 KB），替换生效（sub_ovr，且是全部图或正好是那张图）时
//   字幕条按点阵取点、不再走文字 RAM + 字库；字色 8 选 1、滚动每帧 1~4 点。没替换时每帧 2 点，字色 = 显示页的字幕颜色（R8-2，默认白）。
// 流水线：按 pixel_x + LA 提前算坐标 -> ROM / RAM -> 字库 -> 各层颜色 -> 4 级合成 -> 虚线框 -> 当前像素。
`ifndef LOGO_HEX
`define LOGO_HEX "logo_rom.hex"     // TD：相对本源文件所在目录
`endif
module layer_compositor_old (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [9:0]  pixel_x,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out,
    // sd_card_clk 域（慢变，2FF + 帧边界两次一致才锁存）
    input  wire        enable_async,     // 显示打开且不在急救中
    input  wire        sel_en_async,     // 图层页菜单打开：画选中框
    input  wire [1:0]  sel_async,
    input  wire [3:0]  show_async,
    input  wire [27:0] x_async,          // 4 × 7 位，单位 8 点
    input  wire [23:0] y_async,          // 4 × 6 位，单位 8 点
    input  wire [15:0] alpha_async,      // 4 × 4 位，0~10
    input  wire [7:0]  z_async,          // 4 × 2 位
    input  wire [7:0]  motion_async,     // 4 × 2 位
    // 波形（video_clk 域）
    input  wire        wave_en,
    input  wire [2:0]  viz,              // video_clk 域：R10 只剩 2 频谱（不再使用，开关由 wave_en 给出）
    input  wire        pcm_valid,
    input  wire signed [15:0] pcm,
    // 画中画抽样（video_clk 域）
    input  wire        cap_en,
    input  wire [2:0]  img_idx,
    // 字幕文字写口（sd_card_clk 域，地址 128~191 归本模块）
    input  wire        wclk,
    input  wire        we,
    input  wire [7:0]  waddr,
    input  wire [10:0] wdata,
    // R8-1c 字幕点阵写口（sd_card_clk 域，uart_subtitle）+ 替换参数（慢变，同样 2FF + 帧边界锁存）
    input  wire        bm_we,
    input  wire [9:0]  bm_addr,
    input  wire [7:0]  bm_data,
    input  wire        sub_ovr_async,
    input  wire        sub_all_async,
    input  wire [2:0]  sub_pic_async,
    input  wire [2:0]  sub_color_async,
    input  wire [1:0]  sub_speed_async,
    input  wire [2:0]  sub_col_async,    // R8-2 显示页：片内字幕颜色（串口字幕仍用 sub_color_async）
    // 字库第二读口（cn_text_overlay 里，1 拍）
    output wire [13:0] fb_addr,          // 组合输出，cn_text_overlay 里寄存读出
    input  wire [7:0]  fb_q
);
    localparam integer LA = 9;
    localparam [10:0] W0 = 96,  H0 = 40;
    localparam [10:0] W1 = 640, H1 = 24;
    localparam [10:0] W2 = 132, H2 = 100;
    localparam [10:0] W3 = 528, H3 = 64;
    localparam [10:0] SUBLEN = 512;      // 64 格 × 8 点
    localparam [10:0] SCROLL_P = 640 + 512;

    // ---------------- 行 / 帧 ----------------
    reg vs_q, de_q;
    reg [9:0] line_y;
    wire frame_start = vs_q && !vsync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_q <= 1'b1; de_q <= 1'b0; line_y <= 10'd0;
        end else begin
            vs_q <= vsync; de_q <= de;
            if (!vsync) line_y <= 10'd0;
            else if (de_q && !de) line_y <= line_y + 10'd1;
        end
    end

    // ---------------- 参数跨域 ----------------
    localparam integer PW = 1 + 1 + 2 + 4 + 28 + 24 + 16 + 8 + 8;
    wire [PW-1:0] p_a = {enable_async, sel_en_async, sel_async, show_async, x_async, y_async, alpha_async, z_async, motion_async};
    reg  [PW-1:0] p_s1, p_s2, p_f;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_s1 <= {PW{1'b0}}; p_s2 <= {PW{1'b0}}; p_f <= {PW{1'b0}};
        end else begin
            p_s1 <= p_a; p_s2 <= p_s1;
            if (frame_start && p_s1 == p_s2) p_f <= p_s2;
        end
    end
    wire        en_f     = p_f[PW-1];
    wire        selen_f  = p_f[PW-2];
    wire [1:0]  sel_f    = p_f[PW-3 -: 2];
    wire [3:0]  show_f   = p_f[PW-5 -: 4];
    wire [27:0] x_f      = p_f[PW-9 -: 28];
    wire [23:0] y_f      = p_f[PW-37 -: 24];
    wire [15:0] alpha_f  = p_f[PW-61 -: 16];
    wire [7:0]  z_f      = p_f[PW-77 -: 8];
    wire [7:0]  mot_f    = p_f[7:0];
    // R8-1c 字幕替换参数
    wire [12:0] q_a = {sub_col_async, sub_ovr_async, sub_all_async, sub_pic_async, sub_color_async, sub_speed_async};
    reg  [12:0] q_s1, q_s2, q_f;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_s1 <= 13'd1; q_s2 <= 13'd1; q_f <= 13'd1;
        end else begin
            q_s1 <= q_a; q_s2 <= q_s1;
            if (frame_start && q_s1 == q_s2) q_f <= q_s2;
        end
    end
    reg       sub_on;                      // 本图用替换字幕
    wire      sub_on_w = q_f[9] && (q_f[8] || img_idx == q_f[7:5]);
    reg [2:0] scol_f;
    reg [1:0] sspd_f;
    always @(posedge clk) begin
        sub_on <= sub_on_w;
        scol_f <= sub_on_w ? q_f[4:2] : q_f[12:10];          // 替换字幕用串口颜色，否则用显示页的片内字幕颜色
        sspd_f <= q_f[1:0];
    end
    wire [10:0] sstep = sub_on ? {9'd0, sspd_f} + 11'd1 : 11'd2;

    // ---------------- 运动（帧边界更新位置）----------------
    reg signed [11:0] px [0:3];
    reg        [9:0]  py [0:3];
    reg        [3:0]  dirx, diry;          // 1 = 向右 / 向下
    reg        [10:0] scroll;              // 字幕滚动量 0..SCROLL_P-1
    function [10:0] wof; input [1:0] i; wof = (i == 0) ? W0 : (i == 1) ? W1 : (i == 2) ? W2 : W3; endfunction
    function [10:0] hof; input [1:0] i; hof = (i == 0) ? H0 : (i == 1) ? H1 : (i == 2) ? H2 : H3; endfunction
    integer i;
    reg signed [11:0] nx;
    reg        [10:0] ny;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin px[i] <= 12'sd0; py[i] <= 10'd0; end
            dirx <= 4'b1111; diry <= 4'b1111; scroll <= 11'd0;
        end else if (frame_start) begin
            scroll <= (mot_f[3:2] == 2'd2) ? ((scroll >= SCROLL_P - sstep) ? 11'd0 : scroll + sstep) : 11'd0;
            for (i = 0; i < 4; i = i + 1) begin
                case (mot_f[i*2 +: 2])
                    2'd1: begin                                    // 弹跳
                        if (i != 1) begin
                            nx = dirx[i] ? px[i] + 12'sd2 : px[i] - 12'sd2;
                            if (nx > $signed({1'b0, 11'd640 - wof(i)})) begin nx = $signed({1'b0, 11'd640 - wof(i)}); dirx[i] <= 1'b0; end
                            else if (nx < 0) begin nx = 12'sd0; dirx[i] <= 1'b1; end
                            px[i] <= nx;
                        end else
                            px[i] <= 12'sd0;
                        ny = diry[i] ? {1'b0, py[i]} + 11'd1 : {1'b0, py[i]} - 11'd1;
                        if (ny[10]) begin ny = 11'd0; diry[i] <= 1'b1; end
                        else if (ny > 11'd480 - hof(i)) begin ny = 11'd480 - hof(i); diry[i] <= 1'b0; end
                        py[i] <= ny[9:0];
                    end
                    2'd2: begin                                    // 滚动（字幕条本身不动，文字滚）
                        py[i] <= {y_f[i*6 +: 6], 3'b000};
                        if (i == 1)
                            px[i] <= 12'sd0;
                        else if (px[i] <= -$signed({1'b0, wof(i)}))
                            px[i] <= 12'sd640;
                        else
                            px[i] <= px[i] - 12'sd2;
                    end
                    default: begin
                        px[i] <= (i == 1) ? 12'sd0 : $signed({2'b00, x_f[i*7 +: 7], 3'b000});
                        py[i] <= {y_f[i*6 +: 6], 3'b000};
                    end
                endcase
            end
        end
    end

    // ---------------- 存储：台标 ROM / 字幕文字 RAM / 画中画缓冲 ----------------
    reg [1:0] logo [0:3839];
    initial $readmemh(`LOGO_HEX, logo);
    reg [10:0] stxt [0:63];
    always @(posedge wclk)
        if (we && waddr[7:6] == 2'b10) stxt[waddr[5:0]] <= wdata;
    reg [7:0] sbm [0:1023];                // R8-1c 字幕点阵：地址 {行[3:0], 列字节[5:0]}，最高位在左
    always @(posedge wclk)
        if (bm_we) sbm[bm_addr] <= bm_data;

    // R8-4b 资源：画中画（图层 2，抽样缓冲 64x48x2 + 抽样计数）删掉，图层 2 恒不显示；端口 cap_en / img_idx 保留不用
    wire bankw = 1'b0;

    // R10 资源：波形（32 点取样 + 峰值条）和 R6 音量表删掉，图层 3 只画频谱（viz = 2；viz = 0 时 wave_en = 0 不画）

    // ---------------- R8-3 频谱 ----------------
`include "../user_source/hdl_source/include/spectrum_tables.vh"  // spec_color；TD 相对 td_project 目录
    wire [4:0] sp_bar;
    wire [5:0] sp_h, sp_cap;
    audio_spectrum u_spec (
        .clk(clk), .rst_n(rst_n), .frame_start(frame_start), .pcm_valid(pcm_valid), .pcm(pcm),
        .rd_bar(sp_bar), .rd_h(sp_h), .rd_cap(sp_cap)
    );

    // =============== S0：提前 LA 点的坐标 ===============
    wire [10:0] xs = {1'b0, pixel_x} + LA;
    wire [9:0]  xa = (xs >= 11'd800) ? xs - 11'd800 : xs[9:0];
    wire [9:0]  ya = line_y;
    wire signed [11:0] xas = {2'b00, xa};
    wire signed [11:0] rx0 = xas - px[0], rx2 = xas - px[2], rx3 = xas - px[3];
    wire signed [11:0] ry0 = {2'b00, ya} - {2'b00, py[0]};
    wire signed [11:0] ry1 = {2'b00, ya} - {2'b00, py[1]};
    wire signed [11:0] ry2 = {2'b00, ya} - {2'b00, py[2]};
    wire signed [11:0] ry3 = {2'b00, ya} - {2'b00, py[3]};
    wire vis_x = (xa < 10'd640);
    wire in0 = vis_x && rx0 >= 0 && rx0 < W0 && ry0 >= 0 && ry0 < H0;
    wire in1 = vis_x &&                           ry1 >= 0 && ry1 < H1;
    wire in2 = vis_x && rx2 >= 0 && rx2 < W2 && ry2 >= 0 && ry2 < H2;
    wire in3 = vis_x && rx3 >= 0 && rx3 < W3 && ry3 >= 0 && ry3 < H3;
    // 字幕文字横坐标：滚动时文字左端在 640 - scroll，否则在 X
    wire signed [11:0] sbase = (mot_f[3:2] == 2'd2) ? (12'sd640 - $signed({1'b0, scroll})) : $signed({2'b00, x_f[13:7], 3'b000});
    wire signed [11:0] stx = xas - sbase;
    wire signed [11:0] sty = ry1 - 12'sd4;
    wire s_txt = stx >= 0 && stx < SUBLEN && sty >= 0 && sty < 16;
    // 画中画内框
    wire signed [11:0] pix_ = rx2 - 12'sd2, piy = ry2 - 12'sd2;
    wire p_in = pix_ >= 0 && pix_ < 128 && piy >= 0 && piy < 96;
    wire [12:0] p_addr = (bankw ? 13'd0 : 13'd3072) + {1'b0, piy[6:1], pix_[6:1]};
    // 选中框：外扩 2 点的矩形边
    reg  signed [11:0] fx0, fx1, fy0, fy1;
    always @* begin
        fx0 = (sel_f == 2'd1) ? 12'sd0 : px[sel_f] - 12'sd2;
        fx1 = (sel_f == 2'd1) ? 12'sd639 : px[sel_f] + $signed({1'b0, wof(sel_f)}) + 12'sd1;
        fy0 = $signed({2'b00, py[sel_f]}) - 12'sd2;
        fy1 = $signed({2'b00, py[sel_f]}) + $signed({1'b0, hof(sel_f)}) + 12'sd1;
    end
    wire signed [11:0] yss = {2'b00, ya};
    wire on_frame = vis_x && selen_f && en_f && show_f[sel_f] &&
                    (((xas == fx0 || xas == fx1) && yss >= fy0 && yss <= fy1) ||
                     ((yss == fy0 || yss == fy1) && xas >= fx0 && xas <= fx1)) &&
                    xa[2] ^ ya[2];

    // =============== S1 ===============
    reg        s1_in0, s1_in1, s1_in2, s1_in3, s1_stxt, s1_pin, s1_frame;
    reg [11:0] s1_laddr;
    reg [12:0] s1_paddr;
    reg [5:0]  s1_taddr;
    reg [3:0]  s1_trow;
    reg [2:0]  s1_tcol;
    reg [9:0]  s1_rx3;
    reg [5:0]  s1_ry3;
    always @(posedge clk) begin
        s1_in0 <= in0 && show_f[0] && en_f;
        s1_in1 <= in1 && show_f[1] && en_f;
        s1_in2 <= 1'b0;                     // R8-4b：画中画删掉
        s1_in3 <= in3 && show_f[3] && en_f && wave_en;
        s1_stxt <= s_txt;
        s1_pin  <= p_in;
        s1_frame <= on_frame;
        s1_laddr <= {ry0[5:0], 6'd0} + {1'b0, ry0[5:0], 5'd0} + {5'd0, rx0[6:0]};   // ry*96 + rx
        s1_paddr <= p_addr;
        s1_taddr <= stx[8:3];
        s1_trow  <= sty[3:0];
        s1_tcol  <= stx[2:0];
        s1_rx3   <= rx3[9:0];
        s1_ry3   <= ry3[5:0];
    end
    assign sp_bar = s1_rx3[8:4];          // 频谱柱高读口：下一拍（S2）sp_h / sp_cap 有效

    // =============== S2：ROM / RAM 输出 ===============
    reg [1:0] s2_logo;
    reg [8:0] s2_pip;
    reg [10:0] s2_t;
    reg [7:0]  s2_bm;
    always @(posedge clk) begin
        s2_logo <= logo[s1_laddr];
        s2_pip  <= 9'd0;
        s2_t    <= stxt[s1_taddr];
        s2_bm   <= sbm[{s1_trow, s1_taddr}];
    end
    reg        s2_in0, s2_in1, s2_in2, s2_in3, s2_stxt, s2_pin, s2_frame;
    reg [3:0]  s2_trow;
    reg [2:0]  s2_tcol;
    reg [9:0]  s2_rx3;
    reg [5:0]  s2_ry3;
    always @(posedge clk) begin
        s2_in0 <= s1_in0; s2_in1 <= s1_in1; s2_in2 <= s1_in2; s2_in3 <= s1_in3;
        s2_stxt <= s1_stxt; s2_pin <= s1_pin; s2_frame <= s1_frame;
        s2_trow <= s1_trow; s2_tcol <= s1_tcol; s2_rx3 <= s1_rx3; s2_ry3 <= s1_ry3;
    end
    // 字库地址（第二读口），下一拍（与 S3 同拍）fb_q 有效
    wire [9:0] t_idx = s2_t[7] ? {~s2_t[9], s2_t[9] | s2_t[8], s2_t[6:0], s2_t[10]} : {3'b000, s2_t[6:0]};   // 同 cn_text_overlay
    assign fb_addr = {t_idx, s2_trow};

    // =============== S3：各层颜色 ===============
    reg        s3_in0, s3_in1, s3_in2, s3_in3, s3_stxt, s3_pin, s3_frame;
    reg [1:0]  s3_logo;
    reg [8:0]  s3_pip;
    reg [2:0]  s3_tcol;
    reg [7:0]  s3_bm;
    reg        s3_sbar, s3_scap;
    reg [4:0]  s3_seg;
    always @(posedge clk) begin
        s3_in0 <= s2_in0; s3_in1 <= s2_in1; s3_in2 <= s2_in2; s3_in3 <= s2_in3;
        s3_stxt <= s2_stxt; s3_pin <= s2_pin; s3_frame <= s2_frame;
        s3_logo <= s2_logo; s3_pip <= s2_pip; s3_tcol <= s2_tcol; s3_bm <= s2_bm;
        s3_seg   <= s2_rx3[8:4];             // 第几根柱（每根 16 列，留 2 列缝）
        // 频谱：柱子从底（第 63 行）往上 sp_h 行，顶帽 2 行在 63 - cap 和上一行（cap = 0 不画）
        s3_sbar  <= (s2_rx3 < 10'd512) && (s2_rx3[3:0] < 4'd14) && ({1'b0, s2_ry3} + {1'b0, sp_h} >= 7'd64);
        s3_scap  <= (s2_rx3 < 10'd512) && (s2_rx3[3:0] < 4'd14) && (sp_cap != 6'd0) &&
                    ((s2_ry3 == 6'd63 - sp_cap) || (s2_ry3 == 6'd62 - sp_cap));
    end
    function [4:0] a16; input [3:0] v;
        case (v)
            4'd0: a16 = 5'd0;  4'd1: a16 = 5'd2;  4'd2: a16 = 5'd3;  4'd3: a16 = 5'd5;  4'd4: a16 = 5'd6;
            4'd5: a16 = 5'd8;  4'd6: a16 = 5'd10; 4'd7: a16 = 5'd11; 4'd8: a16 = 5'd13; 4'd9: a16 = 5'd14;
            default: a16 = 5'd16;
        endcase
    endfunction
    wire [23:0] c0 = (s3_logo == 2'd1) ? 24'hd81e28 : (s3_logo == 2'd2) ? 24'hffffff : 24'h7a0e14;
    wire        h0 = s3_in0 && (s3_logo != 2'd0);
    wire        lit1 = s3_stxt && (sub_on ? s3_bm[3'd7 - s3_tcol] : fb_q[3'd7 - s3_tcol]);
    reg  [23:0] scol;                    // 字色：白 黄 红 绿 青 橙 粉 蓝（没替换时白）
    always @(posedge clk)
        case (scol_f)
            3'd0: scol <= 24'hffffff;  3'd1: scol <= 24'hffd800;  3'd2: scol <= 24'hff3030;  3'd3: scol <= 24'h30e040;
            3'd4: scol <= 24'h30e0e0;  3'd5: scol <= 24'hff9020;  3'd6: scol <= 24'hff70c0;  default: scol <= 24'h4080ff;
        endcase
    wire [23:0] c1 = lit1 ? scol : 24'h000000;
    wire        h1 = s3_in1;
    wire [23:0] c2 = !s3_pin ? 24'hffffff :
                     {s3_pip[8:6], s3_pip[8:6], s3_pip[8:7], s3_pip[5:3], s3_pip[5:3], s3_pip[5:4], s3_pip[2:0], s3_pip[2:0], s3_pip[2:1]};
    wire        h2 = s3_in2;
    wire [23:0] c3 = s3_scap ? 24'hffffff : spec_color(s3_seg);
    wire        h3 = s3_in3 && (s3_sbar || s3_scap);

    reg [3:0]  l_hit;
    reg [95:0] l_col;                    // {层3, 层2, 层1, 层0}
    reg        s4_frame;
    always @(posedge clk) begin
        l_hit <= {h3, h2, h1, h0};
        l_col <= {c3, c2, c1, c0};
        s4_frame <= s3_frame;
    end

    // =============== S4~S7：按层序从下往上合成（每级一个图层，at_z[k] = 层序为 k 的图层号）===============
    reg [1:0] at_z [0:3];
    integer zi, li;
    always @* begin
        for (zi = 0; zi < 4; zi = zi + 1) begin
            at_z[zi] = 2'd0;
            for (li = 0; li < 4; li = li + 1)
                if (z_f[li*2 +: 2] == zi[1:0]) at_z[zi] = li[1:0];
        end
    end
    // c(16-a) + col·a = 16c + (col-c)·a：每通道只用一个乘法（原来两个，DSP 用到 28/29），结果逐位相同
    function [7:0] blend; input [7:0] c, col; input [4:0] a;
        reg signed [8:0]  d;
        reg signed [14:0] t;
        begin
            d = $signed({1'b0, col}) - $signed({1'b0, c});
            t = $signed({3'b000, c, 4'b0000}) + d * $signed({1'b0, a}) + 15'sd8;
            blend = t[11:4];
        end
    endfunction
    // 第 g 级输入 = 第 g 个寄存组（第 0 组就是 S4 的 l_*）
    reg [23:0] cq [0:4];
    reg [8:0]  tq [0:4];
    reg [3:0]  hq [0:4];
    reg [95:0] lq [0:4];
    reg        fq [0:4];
    always @* begin
        cq[0] = 24'd0; tq[0] = 9'd256; hq[0] = l_hit; lq[0] = l_col; fq[0] = s4_frame;
    end
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_stage
            wire [1:0]  L   = at_z[g];
            wire        hit = hq[g][L];
            wire [23:0] col = lq[g][L*24 +: 24];
            wire [4:0]  a   = a16(alpha_f[L*4 +: 4]);
            wire [13:0] tm  = tq[g] * (5'd16 - a);
            always @(posedge clk) begin
                cq[g+1] <= hit ? {blend(cq[g][23:16], col[23:16], a), blend(cq[g][15:8], col[15:8], a), blend(cq[g][7:0], col[7:0], a)} : cq[g];
                tq[g+1] <= hit ? tm[12:4] : tq[g];
                hq[g+1] <= hq[g];
                lq[g+1] <= lq[g];
                fq[g+1] <= fq[g];
            end
        end
    endgenerate

    // =============== S8：选中框 ===============
    reg [23:0] c8;
    reg [8:0]  t8;
    always @(posedge clk) begin
        c8 <= fq[4] ? 24'hffd040 : cq[4];
        t8 <= fq[4] ? 9'd0 : tq[4];
    end

    // =============== 当前像素：out = bg·T/256 + C ===============
    function [7:0] fin_c; input [7:0] bg, c; input [8:0] t;
        reg [16:0] p; reg [9:0] s;
        begin
            p = bg * t + 17'd128;
            s = {2'b00, p[15:8]} + {2'b00, c};
            fin_c = s[9:8] != 0 ? 8'hff : s[7:0];
        end
    endfunction
    wire [23:0] mixed = {fin_c(rgb_in[23:16], c8[23:16], t8), fin_c(rgb_in[15:8], c8[15:8], t8), fin_c(rgb_in[7:0], c8[7:0], t8)};
    assign rgb_out = (de && t8 != 9'd256) ? mixed : rgb_in;
endmodule
