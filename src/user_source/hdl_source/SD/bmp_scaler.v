`timescale 1ns/1ps
// R8-5a：BMP 加载时等比缩放（sd_card_clk）。原图 W x H 的像素流（文件顺序）-> 固定 OUT_W x OUT_H 的像素流（含黑边），
// 下游 media_frame_loader 照旧按顺序写 SDRAM bank，显示链不用动。
//   尺寸：倍数 s = min(OUT_W/W, OUT_H/H, 3)，等比缩到一边贴满（或 3 倍），另一边 = 原边 * 比例（串行除法），居中加黑边。
//   缩小 = 面积平均：每个原图像素按 DDA 归到一个输出格（格宽 / 格高 1~5 个原图像素），格内求和再乘 1/n（查表，1 个乘法器分时）。
//   原尺寸（s = 1）是格 1x1 的特例（和 x 65536 >> 16 = 原值，逐位不变）。
//   R8-5b 放大（s > 1）= 双线性，见下面"放大"两段。
// 结构：输入侧把一行输出格的结果写进行缓冲（乒乓两块），输出侧按 OUT_W x OUT_H 顺序出像素，窗口外出黑色，
//   窗口内的行要等对应的行缓冲写好；out_ready 是 loader FIFO 的余量（反压只在输出侧，输入侧不能停）。
// 输入像素间隔至少 6 拍（扇区重放每 2 拍 1 字节，3 字节 1 像素），格结算流水 5 拍，够用；违例时 overrun 置 1。
// 反压：另一块行缓冲还在等送出（rdy[~wpp]）时 hold = 1，暂停扇区重放（细长图的黑边很长，输出侧会比输入慢）。
//   hold 到字节真正停下还有 2~3 个字节在路上，最多再收 1 个像素，写进的是当前块；一行至少 8 个像素，这块写不满，不会冲掉。
// 坐标约定：输出行 k 按文件顺序（BMP 自下而上：显示第 OUT_H-1-k 行，loader 负责翻转），上下黑边按显示坐标居中。
//   R8-5b：负高度 BMP（src_td = 1，自上而下）文件顺序就是显示顺序，窗口行号直接按显示坐标算，loader 这张图不翻转。
module bmp_scaler #(
    parameter integer OUT_W = 640,
    parameter integer OUT_H = 480
)(
    input              clk,
    input              rst,
    input              clr,          // 同步清除（中止加载）
    input              start,        // 单拍：src_w / src_h 有效，开始一张图
    input      [11:0]  src_w,
    input      [11:0]  src_h,
    input              src_td,       // R8-5b：1 = 自上而下（负高度 BMP）
    input              in_valid,
    input      [23:0]  in_rgb,       // {R, G, B}
    input              out_ready,    // 下游还能收（loader FIFO 有余量）
    output reg         out_valid,
    output reg [23:0]  out_rgb,
    output reg         busy,         // start 之后，到 OUT_W x OUT_H 个像素全部送出
    output             hold,         // 请上游暂停送像素
    output reg         overrun       // 输入太快 / 行缓冲没来得及送出（不应出现）
);

localparam [9:0] OW = OUT_W;
localparam [9:0] OH = OUT_H;

// ---------------- 缩放参数 ----------------
localparam [3:0] P_IDLE = 4'd0, P_CMP = 4'd1, P_DIV = 4'd2, P_GO = 4'd3, P_RUN = 4'd4, P_CMP2 = 4'd5, P_GEO = 4'd6, P_DLD = 4'd7, P_DEND = 4'd8,
                 P_SX = 4'd9, P_SY = 4'd10;
localparam [1:0] DK_GEO = 2'd0, DK_SX = 2'd1, DK_SY = 2'd2;
reg [3:0]  pst;
reg        prun;             // R9 时序：= (pst == P_RUN)，单独一个寄存器（pst 译码扇出 70 多，in_go -> 行缓冲写 -0.37ns）
reg [11:0] sw, sh;           // 原图宽高
reg        td;               // 自上而下
reg [9:0]  wo, ho;           // 缩放后窗口宽高
reg [9:0]  x0, x1;           // 窗口列 [x0, x1)
reg [9:0]  kb, ke;           // 窗口行（文件顺序）[kb, ke)
reg        fit, wide, cap3;
reg        up;               // R8-5b：放大（双线性），P_GEO 定下来，整张图不变
reg [21:0] mw, mh;           // W*OH / H*OW（时序：单独寄存一拍）
reg [12:0] tw, th;           // 3W / 3H
reg [9:0]  gx0, gy0;
reg [27:0] dnum;             // 除法：被除数移位寄存器（R8-5b：放大步长要 W << 16，22 -> 28 位）
reg [11:0] dden;
reg [12:0] drem;
reg [16:0] dquo;
reg [4:0]  dcnt;
reg        div_ho;           // 1 = 结果是 ho，0 = 结果是 wo
reg [1:0]  div_k;            // 这次除法算什么：窗口尺寸 / 横向步长 / 纵向步长
reg [16:0] stx, sty;         // R8-5b：放大步长 W/wo、H/ho（16 位小数，<= 1.0）
reg [9:0]  wom1;             // wo - 1

// 乘常数写成移位加法（直接写 * 会被综合成 DSP，DSP 只剩 4 个）
function [21:0] cmul;
    input [11:0] a;
    input [9:0]  k;
    integer i;
    begin
        cmul = 22'd0;
        for (i = 0; i < 10; i = i + 1)
            if (k[i]) cmul = cmul + ({10'd0, a} << i);
    end
endfunction

wire [12:0] drem_sh  = {drem[11:0], dnum[27]};
wire [12:0] drem_sub = drem_sh - {1'b0, dden};

always @(posedge clk or posedge rst) begin
    if (rst) begin
        pst <= P_IDLE;  prun <= 1'b0;
        sw <= 12'd0; sh <= 12'd0; td <= 1'b0; wo <= 10'd0; ho <= 10'd0;
        x0 <= 10'd0; x1 <= 10'd0; kb <= 10'd0; ke <= 10'd0;
        fit <= 1'b0; wide <= 1'b0; cap3 <= 1'b0; up <= 1'b0;
        mw <= 22'd0; mh <= 22'd0; tw <= 13'd0; th <= 13'd0; gx0 <= 10'd0; gy0 <= 10'd0;
        dnum <= 28'd0; dden <= 12'd1; drem <= 13'd0; dquo <= 17'd0; dcnt <= 5'd0; div_ho <= 1'b0; div_k <= DK_GEO;
        stx <= 17'd0; sty <= 17'd0; wom1 <= 10'd0;
    end else if (clr) begin
        pst <= P_IDLE;  prun <= 1'b0;
    end else begin
        case (pst)
            P_IDLE: if (start) begin
                sw  <= src_w;
                sh  <= src_h;
                td  <= src_td;
                pst <= P_CMP;
            end
            P_CMP: begin
                // 宽度贴满 <=> OW/W <= OH/H <=> W*OH >= H*OW（常数乘法 = 移位加法）
                fit  <= (sw <= OW) && (sh <= OH);
                mw   <= cmul(sw, OH);
                mh   <= cmul(sh, OW);
                tw   <= {1'b0, sw} + {sw, 1'b0};
                th   <= {1'b0, sh} + {sh, 1'b0};
                pst  <= P_CMP2;
            end
            P_CMP2: begin
                wide <= mw >= mh;
                cap3  <= (tw <= {3'd0, OW}) && (th <= {3'd0, OH});   // 放大到 3 倍还放得下：倍数封顶 3
                pst  <= P_DLD;
            end
            P_DLD: begin
                drem  <= 13'd0;
                dquo  <= 17'd0;
                dcnt  <= 5'd27;
                div_k <= DK_GEO;
                if (fit && cap3) begin
                    wo  <= tw[9:0];
                    ho  <= th[9:0];
                    pst <= P_SX;
                end else begin
                    div_ho <= wide;
                    dnum   <= wide ? {6'd0, mh} : {6'd0, mw};
                    dden   <= wide ? sw : sh;
                    pst    <= P_DIV;
                end
            end
            P_DIV: begin
                // 恢复余数除法，一拍一位，28 拍
                dnum <= {dnum[26:0], 1'b0};
                drem <= drem_sub[12] ? drem_sh : drem_sub;
                dquo <= {dquo[15:0], !drem_sub[12]};
                dcnt <= dcnt - 5'd1;
                if (dcnt == 5'd0)
                    pst <= P_DEND;
            end
            P_DEND: begin
                case (div_k)
                    DK_GEO: begin
                        // 结果为 0（原图极细长）时按 1 处理
                        if (div_ho) begin
                            wo <= OW;
                            ho <= (dquo[9:0] == 10'd0) ? 10'd1 : dquo[9:0];
                        end else begin
                            ho <= OH;
                            wo <= (dquo[9:0] == 10'd0) ? 10'd1 : dquo[9:0];
                        end
                        pst <= fit ? P_SX : P_GEO;   // 缩小不用步长
                    end
                    DK_SX: begin
                        stx <= dquo;
                        pst <= P_SY;
                    end
                    default: begin
                        sty <= dquo;
                        pst <= P_GEO;
                    end
                endcase
            end
            P_SX: begin
                // 放大步长 = W * 65536 / wo（原尺寸时 = 65536，用不上）
                drem  <= 13'd0;
                dquo  <= 17'd0;
                dcnt  <= 5'd27;
                div_k <= DK_SX;
                dnum  <= {sw, 16'd0};
                dden  <= {2'd0, wo};
                pst   <= P_DIV;
            end
            P_SY: begin
                drem  <= 13'd0;
                dquo  <= 17'd0;
                dcnt  <= 5'd27;
                div_k <= DK_SY;
                dnum  <= {sh, 16'd0};
                dden  <= {2'd0, ho};
                pst   <= P_DIV;
            end
            P_GEO: begin
                gx0 <= (OW - wo) >> 1;
                gy0 <= (OH - ho) >> 1;
                up  <= fit && ((wo != sw[9:0]) || (ho != sh[9:0]));
                pst <= P_GO;
            end
            P_GO: begin
                x0   <= gx0;
                x1   <= gx0 + wo;
                kb   <= td ? gy0 : (OH - gy0 - ho);
                ke   <= td ? (gy0 + ho) : (OH - gy0);
                wom1 <= wo - 10'd1;
                pst  <= P_RUN;
                prun <= 1'b1;
            end
            P_RUN: if (!busy) begin
                pst  <= P_IDLE;
                prun <= 1'b0;
            end
            default: begin
                pst  <= P_IDLE;
                prun <= 1'b0;
            end
        endcase
    end
end

wire run_go = (pst == P_GO);        // 下一拍开始收像素 / 出像素

// ---------------- 输入侧：DDA 分格 + 行内求和 ----------------
reg [9:0]  ox;               // 当前像素属于第几个输出格
reg [11:0] hacc, vacc;
reg [11:0] sx;               // 原图列
reg [2:0]  cx, cyr;          // 当前格已收几个像素 / 当前原图行是格内第几行（从 0 数）
reg        rlast;            // 当前原图行是格的最后一行（要结算）
reg        rlast_upd, rlast_upd2;
reg [10:0] hs_r, hs_g, hs_b;   // 一行内格的部分和（<= 5 x 255）
reg [16:0] rc_pre;             // R8-5b 时序：本格若在当前像素结算，1/n = recip(cx+1, cyr+1)，每拍预先查表（原来令牌 -> 查表一拍，-0.6~-4.2ns）

// 时序：比较结果每拍按当前状态预先寄存（输入像素至少隔 6 拍，状态更新后下一拍就准备好）
//   两级：nh = hacc + wo，下一拍再比较；行尾比较用预先算好的 sw - 1
reg  [12:0] nh;
reg         cend, rowe;
reg  [11:0] swm1, shm1;
// R9 时序：行尾结算判断 vacc + ho >= sh 拆两拍：vh 每拍寄存，rlast_upd 晚一拍（rlast_upd2）再比较（原来一拍 7 级，-0.56ns）
reg  [12:0] vh;
always @(posedge clk) begin
    swm1 <= sw - 12'd1;
    shm1 <= sh - 12'd1;
    vh   <= {1'b0, vacc} + ho;
    nh   <= hacc + wo;
    cend <= nh >= {1'b0, sw};
    rowe <= (sx == swm1);
end
wire [10:0] sum_r = (cx == 3'd0 ? 11'd0 : hs_r) + in_rgb[23:16];
wire [10:0] sum_g = (cx == 3'd0 ? 11'd0 : hs_g) + in_rgb[15:8];
wire [10:0] sum_b = (cx == 3'd0 ? 11'd0 : hs_b) + in_rgb[7:0];
wire        in_go = in_valid && prun;

// 格结算令牌
reg        t_v;
reg [9:0]  t_ox;
reg [10:0] t_r, t_g, t_b;
reg [16:0] t_rc;
reg        t_first, t_last, t_rowend;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        ox <= 10'd0; hacc <= 12'd0; vacc <= 12'd0; sx <= 12'd0; cx <= 3'd0; cyr <= 3'd0;
        rlast <= 1'b0; rlast_upd <= 1'b0; rlast_upd2 <= 1'b0;
        hs_r <= 11'd0; hs_g <= 11'd0; hs_b <= 11'd0;
        t_v <= 1'b0; t_ox <= 10'd0; t_r <= 11'd0; t_g <= 11'd0; t_b <= 11'd0;
        t_rc <= 17'd0; t_first <= 1'b0; t_last <= 1'b0; t_rowend <= 1'b0;
    end else if (clr || run_go) begin
        ox <= 10'd0; hacc <= 12'd0; vacc <= 12'd0; sx <= 12'd0; cx <= 3'd0; cyr <= 3'd0;
        rlast <= ({2'b00, ho} >= sh);    // 第 0 行：vacc = 0
        rlast_upd <= 1'b0; rlast_upd2 <= 1'b0;
        t_v <= 1'b0;
    end else begin
        t_v        <= 1'b0;
        rlast_upd  <= 1'b0;
        rlast_upd2 <= rlast_upd;
        if (rlast_upd2)
            rlast <= vh >= {1'b0, sh};
        if (in_go) begin
            if (cend) begin
                t_v      <= 1'b1;
                t_ox     <= ox;
                t_r      <= sum_r;
                t_g      <= sum_g;
                t_b      <= sum_b;
                t_rc     <= rc_pre;
                t_first  <= (cyr == 3'd0);
                t_last   <= rlast;
                t_rowend <= rowe;
                hacc     <= nh - sw;
                ox       <= ox + 10'd1;
                cx       <= 3'd0;
            end else begin
                hacc <= nh[11:0];
                cx   <= cx + 3'd1;
                hs_r <= sum_r;
                hs_g <= sum_g;
                hs_b <= sum_b;
            end
            if (rowe) begin
                // 原图一行结束（最后一个像素一定是格尾：W*wo mod W = 0）
                sx   <= 12'd0;
                ox   <= 10'd0;
                hacc <= 12'd0;
                if (rlast) begin
                    vacc <= vacc + ho - sh;
                    cyr  <= 3'd0;
                end else begin
                    vacc <= vacc + ho;
                    cyr  <= cyr + 3'd1;
                end
                rlast_upd <= 1'b1;
            end else begin
                sx <= sx + 12'd1;
            end
        end
    end
end

// ---------------- 格结算：累加行缓存 + 乘 1/n ----------------
(* ram_style = "bram_32k" *) reg [38:0] acc_mem [0:OUT_W-1];   // 每格 RGB 各 13 位（<= 25 x 255）
reg [38:0] acc_q;
always @(posedge clk)
    if (in_go)
        acc_q <= acc_mem[ox];       // 当前格这一列上面几行的和，下一拍（结算第 1 拍）用

// round(65536 / n)，n = cx * cy（1~5 x 1~5）
function [16:0] recip;
    input [2:0] a, b;
    begin
        case ({a, b})
            6'o11: recip = 17'd65536; 6'o12: recip = 17'd32768; 6'o13: recip = 17'd21845; 6'o14: recip = 17'd16384; 6'o15: recip = 17'd13107;
            6'o21: recip = 17'd32768; 6'o22: recip = 17'd16384; 6'o23: recip = 17'd10923; 6'o24: recip = 17'd8192;  6'o25: recip = 17'd6554;
            6'o31: recip = 17'd21845; 6'o32: recip = 17'd10923; 6'o33: recip = 17'd7282;  6'o34: recip = 17'd5461;  6'o35: recip = 17'd4369;
            6'o41: recip = 17'd16384; 6'o42: recip = 17'd8192;  6'o43: recip = 17'd5461;  6'o44: recip = 17'd4096;  6'o45: recip = 17'd3277;
            6'o51: recip = 17'd13107; 6'o52: recip = 17'd6554;  6'o53: recip = 17'd4369;  6'o54: recip = 17'd3277;  6'o55: recip = 17'd2621;
            default: recip = 17'd0;
        endcase
    end
endfunction

always @(posedge clk)
    rc_pre <= recip(cx + 3'd1, cyr + 3'd1);

// 时序：令牌再寄存一级 t2（BRAM 读出 acc_q 先打一拍再做加法），令牌间隔 >= 6 拍不受影响
reg        t2_v;
reg [9:0]  t2_ox;
reg [10:0] t2_r, t2_g, t2_b;
reg        t2_first, t2_last, t2_rowend;
reg [16:0] t2_rc;
reg [38:0] acc_q2;
always @(posedge clk) begin
    t2_ox     <= t_ox;
    t2_r      <= t_r;
    t2_g      <= t_g;
    t2_b      <= t_b;
    t2_first  <= t_first;
    t2_last   <= t_last;
    t2_rowend <= t_rowend;
    t2_rc     <= t_rc;
    acc_q2    <= acc_q;
end
always @(posedge clk or posedge rst) begin
    if (rst)
        t2_v <= 1'b0;
    else
        t2_v <= t_v && !(clr || run_go) && !up;    // R8-5b：放大时不走格结算，像素直接进行缓冲（见下）
end

// ---------------- 放大：输入侧（R8-5b）----------------
// 原图行 j 存进行缓冲 ob_mem 的第 j[0] 块（放大时 W <= 640，一块放一整行），输出侧同时用相邻两行 iy / iy+1。
// 行 j 要覆盖 j-2，所以 j > iy + 1 时不能写（u_blk）：hold 暂停读卡；hold 生效前最多还会进来 1 个像素（总在一行开头），
// 先存进 pend，放行后再写。u_blk 只会在行与行之间变 1（iy 只增不减），所以 pend 里一定不是行尾像素。
reg [9:0]  j_in;             // 正在收的原图行
reg [9:0]  rows_wr;          // 已完整写进行缓冲的行数
reg        u_blk;
reg        pend_v;
reg [9:0]  pend_col;
reg [23:0] pend_rgb;
reg [9:0]  iy, iy1, iyp2;    // 输出侧当前行用到的原图行（定义见输出侧）

reg [4:0]  fs;               // 结算流水级（独热，bit0 = 第 1 拍）
reg [9:0]  f_ox;
reg [12:0] f_r, f_g, f_b;
reg        f_last, f_rowend;
reg [16:0] f_rc;
reg [29:0] prod;
reg [7:0]  avg_r, avg_g;
reg        acc_we;
reg [38:0] acc_wd;
reg [9:0]  acc_wa;
reg        ob_we;
reg [23:0] ob_wd;
reg [10:0] ob_wa;
reg        wpp;              // 输入侧正在写的行缓冲
reg [1:0]  rdy;              // 行缓冲已写好、等输出侧取走
reg [1:0]  rdy_clr;          // 输出侧取走（组合，来自下面）
assign hold = rdy[~wpp] || u_blk;     // 放大时 rdy 一直是 0；缩小时 u_blk 一直是 0

// 一个乘法器分时：第 2 / 3 / 4 拍依次乘 R / G / B
wire [12:0] mul_in   = fs[0] ? f_r : (fs[1] ? f_g : f_b);
wire [13:0] avg_full = (prod + 30'd32768) >> 16;
wire [7:0]  avg8     = avg_full[13:8] != 6'd0 ? 8'd255 : avg_full[7:0];
wire        up_in    = in_go && up;

always @(posedge clk) begin
    if (acc_we) acc_mem[acc_wa] <= acc_wd;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        fs <= 5'd0; f_ox <= 10'd0; f_r <= 13'd0; f_g <= 13'd0; f_b <= 13'd0;
        f_last <= 1'b0; f_rowend <= 1'b0; f_rc <= 17'd0; prod <= 30'd0;
        avg_r <= 8'd0; avg_g <= 8'd0;
        acc_we <= 1'b0; acc_wd <= 39'd0; acc_wa <= 10'd0;
        ob_we <= 1'b0; ob_wd <= 24'd0; ob_wa <= 11'd0;
        wpp <= 1'b0; rdy <= 2'b00; overrun <= 1'b0;
        j_in <= 10'd0; rows_wr <= 10'd0; pend_v <= 1'b0; pend_col <= 10'd0; pend_rgb <= 24'd0;
    end else if (clr || run_go) begin
        fs <= 5'd0; acc_we <= 1'b0; ob_we <= 1'b0;
        wpp <= 1'b0; rdy <= 2'b00; overrun <= 1'b0;
        j_in <= 10'd0; rows_wr <= 10'd0; pend_v <= 1'b0;
    end else begin
        acc_we <= 1'b0;
        ob_we  <= 1'b0;
        rdy    <= rdy & ~rdy_clr;
        fs     <= {fs[3:0], 1'b0};
        if (t2_v && fs[3:0] != 4'd0)
            overrun <= 1'b1;
        // 第 1 拍：加上面几行的和
        if (t2_v) begin
            fs[0]    <= 1'b1;
            f_ox     <= t2_ox;
            f_r      <= t2_r + (t2_first ? 13'd0 : acc_q2[38:26]);
            f_g      <= t2_g + (t2_first ? 13'd0 : acc_q2[25:13]);
            f_b      <= t2_b + (t2_first ? 13'd0 : acc_q2[12:0]);
            f_last   <= t2_last;
            f_rowend <= t2_rowend;
            f_rc     <= t2_rc;
        end
        // 第 2 拍：不是格的最后一行 -> 写回累加缓存；是 -> 开始乘 R
        if (fs[0]) begin
            if (!f_last) begin
                acc_we <= 1'b1;
                acc_wa <= f_ox;
                acc_wd <= {f_r, f_g, f_b};
                fs[1]  <= 1'b0;
            end
        end
        if (fs[0] || fs[1] || fs[2])
            prod <= mul_in * f_rc;
        if (fs[1])
            avg_r <= avg8;
        if (fs[2])
            avg_g <= avg8;
        // 第 5 拍：写行缓冲；行尾 -> 这一块交给输出侧
        if (fs[3]) begin
            ob_we <= 1'b1;
            ob_wa <= {wpp, f_ox};
            ob_wd <= {avg_r, avg_g, avg8};
            if (rdy[wpp])
                overrun <= 1'b1;
            if (f_rowend) begin
                rdy[wpp] <= 1'b1;
                wpp      <= ~wpp;
            end
        end

        // 放大：原图像素直接写行缓冲（同一个写口；放大时上面的格结算不工作）
        if (up_in) begin
            if (!u_blk) begin
                ob_we <= 1'b1;
                if (pend_v) begin
                    // 刚放行就来了下一个像素：先写 pend，这个像素顶进 pend（下一拍写）
                    ob_wa    <= {j_in[0], pend_col};
                    ob_wd    <= pend_rgb;
                    pend_col <= sx[9:0];
                    pend_rgb <= in_rgb;
                end else begin
                    ob_wa <= {j_in[0], sx[9:0]};
                    ob_wd <= in_rgb;
                    if (rowe)
                        rows_wr <= rows_wr + 10'd1;
                end
            end else if (!pend_v) begin
                pend_v   <= 1'b1;
                pend_col <= sx[9:0];
                pend_rgb <= in_rgb;
            end else begin
                overrun <= 1'b1;                 // hold 之后来了 2 个像素（不应出现）
            end
            if (rowe)
                j_in <= j_in + 10'd1;
        end else if (pend_v && !u_blk) begin
            ob_we  <= 1'b1;
            ob_wa  <= {j_in[0], pend_col};
            ob_wd  <= pend_rgb;
            pend_v <= 1'b0;
        end
    end
end

// 放大：行 j_in 还有、而且要覆盖仍在用的行 iy 时挡住（寄存：j_in 变后 1 拍生效，下一个像素至少 6 拍后才到）
always @(posedge clk or posedge rst) begin
    if (rst)
        u_blk <= 1'b0;
    else
        u_blk <= up && prun && (j_in < sh[9:0]) && (j_in >= iyp2);
end

// ---------------- 输出侧：按 OUT_W x OUT_H 顺序出像素 ----------------
(* ram_style = "bram_32k" *) reg [23:0] ob_mem [0:2*1024-1];
reg [23:0] ob_q;
reg [10:0] u_ra;             // 放大：读地址（双线性取 4 个邻点）
always @(posedge clk) begin
    if (ob_we) ob_mem[ob_wa] <= ob_wd;
end

reg        sq_run;
reg [9:0]  sk, sc, scc;      // 输出行（文件顺序）/ 输出列 / 窗口内列
reg        rp;               // 输出侧在读的行缓冲
reg        a_v, a_d;         // 读出级：有效 / 是窗口内像素
reg        u_done;           // 放大：当前窗口像素已算好（u_out）
reg [23:0] u_out;
// R8-5b 时序：窗口内外改成寄存器 s_row / s_col，随 sk / sc 一起更新（下一个位置的比较从 sk / sc 预先算，
//   和 s_go 无关）。原来 sk/sc -> 区间比较 -> s_go -> 计数器使能一拍，-0.9~-6.5ns
reg        s_row, s_col;
wire       c_nx   = ((sc + 10'd1) >= x0) && ((sc + 10'd1) < x1);
wire       r_nx   = ((sk + 10'd1) >= kb) && ((sk + 10'd1) < ke);
reg        c0, r0;           // 第 0 列 / 第 0 行在不在窗口里
wire       s_go   = sq_run && out_ready && (!s_row || (up ? (!s_col || u_done) : rdy[rp]));
wire       u_take = s_go && up && s_row && s_col;     // 放大：取走一个窗口像素

wire [10:0] rd_a = up ? u_ra : {rp, scc};
always @(posedge clk)
    if (s_go || up)
        ob_q <= ob_mem[rd_a];

always @(*) begin
    rdy_clr = 2'b00;
    if (s_go && s_row && sc == OW - 10'd1)
        rdy_clr[rp] = 1'b1;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sq_run <= 1'b0; sk <= 10'd0; sc <= 10'd0; scc <= 10'd0; rp <= 1'b0;
        a_v <= 1'b0; a_d <= 1'b0; out_valid <= 1'b0; out_rgb <= 24'd0; busy <= 1'b0;
        s_row <= 1'b0; s_col <= 1'b0; c0 <= 1'b0; r0 <= 1'b0;
    end else if (clr) begin
        sq_run <= 1'b0; a_v <= 1'b0; out_valid <= 1'b0; busy <= 1'b0;
    end else begin
        out_valid <= a_v;
        out_rgb   <= a_d ? (up ? u_out : ob_q) : 24'd0;   // u_out 取走后至少 10 拍才会被下一个像素改写
        a_v       <= s_go;
        a_d       <= s_row && s_col;
        if (start && pst == P_IDLE)
            busy <= 1'b1;
        if (run_go) begin
            sq_run <= 1'b1;
            sk <= 10'd0; sc <= 10'd0; scc <= 10'd0; rp <= 1'b0;
            // x0 / kb 这一拍才写入：用 gx0 / gy0 算第 0 行 / 列
            c0    <= (gx0 == 10'd0);
            r0    <= td ? (gy0 == 10'd0) : ((gy0 + ho) == OH);
            s_col <= (gx0 == 10'd0);
            s_row <= td ? (gy0 == 10'd0) : ((gy0 + ho) == OH);
        end else if (s_go) begin
            if (s_row && s_col)
                scc <= scc + 10'd1;
            if (sc == OW - 10'd1) begin
                sc    <= 10'd0;
                scc   <= 10'd0;
                s_col <= c0;
                s_row <= r_nx;
                if (s_row)
                    rp <= ~rp;
                if (sk == OH - 10'd1)
                    sq_run <= 1'b0;
                else
                    sk <= sk + 10'd1;
            end else begin
                sc    <= sc + 10'd1;
                s_col <= c_nx;
            end
        end
        // 最后一个像素已送出
        if (busy && prun && !sq_run && !a_v && !out_valid)
            busy <= 1'b0;
    end
end

// ---------------- 放大：输出侧双线性（R8-5b）----------------
// 坐标按像素中心对齐：原图坐标 p = (输出坐标 + 0.5) * 步长 - 0.5（16 位小数，步长 = W/wo、H/ho）。
//   p < 0 时取 0；右 / 下边的邻点越界时夹到最后一列 / 一行。权重取 p 的小数高 8 位。
// 每个通道：top = A*256 + fx*(B-A)，bot = C*256 + fx*(D-C)，out = (top*256 + fy*(bot-top) + 32768) >> 16
//   （A B = 行 iy 的列 ix / ix1，C D = 行 iy1 的；都是凸组合，结果在 0~255，不用封顶）。
// 1 个乘法器分时（不和缩小共用：共用要多 40 多个 LUT 的选择器，DSP 还有富余），每通道 12 拍，每个像素约 40 拍。
// 时序：行缓冲读出 ob_q 先选通道寄存成 u_px，再做减法进乘法器（原来 BRAM -> 选择 -> 减法 -> 乘法器输入一拍，-1.6ns）。
reg  [26:0] rx, ry, rxs;     // 有符号 Q16 坐标；rxs = 每行起点
reg  [9:0]  ix, ix1;
reg  [7:0]  fx, fy;
reg  [1:0]  u_wt;            // 坐标更新后等 3 拍（ix/iy -> ix1/iy1 -> u_rok 三级寄存）
reg         u_rok;           // 要用的两行都已写进行缓冲
reg         u_run;
reg  [3:0]  u_k;             // 通道内第几拍
reg  [1:0]  u_ch;            // 0 R 1 G 2 B
reg  [7:0]  ua, uc;
reg  [7:0]  u_px;            // ob_q 选好通道，晚一拍
reg  [17:0] ma;
reg  [7:0]  mb;
reg  signed [26:0] mp;
reg  [15:0] u_top, u_bot;
wire [7:0]  u_sel  = (u_ch == 2'd0) ? ob_q[23:16] : (u_ch == 2'd1) ? ob_q[15:8] : ob_q[7:0];
wire [15:0] u_sum  = {(u_k == 4'd6) ? ua : uc, 8'd0} + mp[15:0];
wire [23:0] u_fin  = {u_top, 8'd0} + mp[23:0] + 24'd32768;

always @(posedge clk) begin
    // 坐标 -> 整数 / 权重（一级），邻点 / 读行判断（二级），行就绪（三级）
    ix   <= rx[26] ? 10'd0 : rx[25:16];
    fx   <= rx[26] ? 8'd0  : rx[15:8];
    iy   <= ry[26] ? 10'd0 : ry[25:16];
    fy   <= ry[26] ? 8'd0  : ry[15:8];
    ix1  <= (ix == swm1[9:0]) ? ix : ix + 10'd1;
    iy1  <= (iy == shm1[9:0]) ? iy : iy + 10'd1;
    iyp2 <= iy + 10'd2;
    u_rok <= rows_wr > iy1;
    u_px <= u_sel;
    mp   <= $signed(ma) * $signed({1'b0, mb});
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rx <= 27'd0; ry <= 27'd0; rxs <= 27'd0; u_wt <= 2'd0; u_run <= 1'b0; u_k <= 4'd0; u_ch <= 2'd0;
        u_done <= 1'b0; u_out <= 24'd0; u_ra <= 11'd0; ua <= 8'd0; uc <= 8'd0; ma <= 18'd0; mb <= 8'd0;
        u_top <= 16'd0; u_bot <= 16'd0;
    end else if (clr) begin
        u_run <= 1'b0; u_done <= 1'b0;
    end else if (run_go) begin
        // 起点 = 步长 / 2 - 0.5
        rxs <= {10'd0, stx[16:1]} - 27'd32768;
        rx  <= {10'd0, stx[16:1]} - 27'd32768;
        ry  <= {10'd0, sty[16:1]} - 27'd32768;
        u_wt <= 2'd3; u_run <= 1'b0; u_done <= 1'b0;
    end else begin
        if (u_take) begin
            u_done <= 1'b0;
            u_wt   <= 2'd3;
            if (scc == wom1) begin
                rx <= rxs;
                ry <= ry + {10'd0, sty};
            end else begin
                rx <= rx + {10'd0, stx};
            end
        end else if (u_wt != 2'd0) begin
            u_wt <= u_wt - 2'd1;
        end else if (!u_run && !u_done && up && prun && u_rok) begin
            u_run <= 1'b1;
            u_k   <= 4'd0;
            u_ch  <= 2'd0;
        end

        if (u_run) begin
            u_k <= u_k + 4'd1;
            case (u_k)
                // u_ra 第 n 拍设好 -> ob_q 第 n+2 拍 -> u_px 第 n+3 拍
                4'd0: u_ra <= {iy[0],  ix};
                4'd1: u_ra <= {iy[0],  ix1};
                4'd2: u_ra <= {iy1[0], ix};
                4'd3: begin u_ra <= {iy1[0], ix1};  ua <= u_px; end         // A
                4'd4: begin ma <= {10'd0, u_px} - {10'd0, ua}; mb <= fx; end // B
                4'd5: uc <= u_px;                                           // C（这拍乘 B-A）
                4'd6: begin u_top <= u_sum;                                 // D
                            ma <= {10'd0, u_px} - {10'd0, uc}; mb <= fx; end
                4'd8: u_bot <= u_sum;
                4'd9: begin ma <= {2'd0, u_bot} - {2'd0, u_top}; mb <= fy; end
                4'd11: begin
                    case (u_ch)
                        2'd0: u_out[23:16] <= u_fin[23:16];
                        2'd1: u_out[15:8]  <= u_fin[23:16];
                        default: u_out[7:0] <= u_fin[23:16];
                    endcase
                    u_k <= 4'd0;
                    if (u_ch == 2'd2) begin
                        u_run  <= 1'b0;
                        u_done <= 1'b1;
                    end else begin
                        u_ch <= u_ch + 2'd1;
                    end
                end
                default: ;
            endcase
        end
    end
end

endmodule
