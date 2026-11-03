`timescale 1ns/1ps

// R2 转场引擎（替代 video_fade_transition）。帧缓存只有一个读口，读不到新旧两帧，所以所有转场都是
// "旧图按图形消失到黑 -> 换图 -> 新图按同一图形出现"：
//   S_OUT：进度 p 从 0 走到 256，被图形盖住的地方变黑（淡入淡出 / 马赛克改为整体变暗）
//   S_HOLD：全黑；此时才把切图请求放给 media_player_control（next_out / prev_out），等 index_commit
//   S_IN：p 从 0 走到 256，被图形盖住的地方显示新图
// 效果 effect：0 淡入淡出 1 右擦 2 左擦 3 下擦 4 上擦 5 圆扩 6 圆缩 7 菱形 8 横百叶 9 竖百叶 10 棋盘 11 溶解 12 马赛克 13 硬切
//   R12c 14 向左推移 15 向上推移：不经过黑场——请求马上放行换图，换好后 media_frame_reader 每帧按 push_off 从旧图 / 新图各读一段
//   （新图从右边 / 下边把旧图推出去），off 按缓出曲线 256·(1-(1-p)²) 走，像素这边不遮罩、不变暗；速度是其他效果单个阶段的 2 倍帧数。
// 速度 speed 1~8：每个阶段 3/5/7/10/14/18/24/30 帧（60Hz 下整个转场约 0.1~1 秒）。
// 效果 / 速度 / 方向在 ctrl_clk 域随请求一起锁存（请求翻转后到下一个请求前不变，像素域看到翻转再采样，跨域安全）。
// ENABLE=0：直通（next/prev 直接放出，像素原样），保持老回归逐像素一致。
// 急救 no_transition=1：画面不做任何遮罩 / 变暗，请求照常走（media_player_control 那边会丢掉），S_HOLD 不等换图直接回 IDLE。
// R8-2b 预览 preview_in：和 next_in 一样走"消失 -> 出现"，但全黑时不放换图请求，S_OUT 结束直接进 S_IN（还是这张图）；
//   硬切 / 播放器没在放 / 急救中的预览什么都不做。
module transition_engine #(
    parameter integer ENABLE = 1,
    parameter integer H_ACT  = 640,
    parameter integer V_ACT  = 480
) (
    input  wire        ctrl_clk,
    input  wire        ctrl_rst_n,
    input  wire        next_in,
    input  wire        prev_in,
    input  wire        preview_in,          // R8-2b：同一张图预览（单拍）
    input  wire [3:0]  effect_in,
    input  wire [3:0]  speed_in,
    input  wire        no_transition,       // ctrl_clk 域电平
    output wire        next_out,
    output wire        prev_out,
    output wire        busy,                // ctrl_clk 域：转场进行中（新请求会被丢弃）

    input  wire        pix_clk,
    input  wire        pix_rst_n,
    input  wire        player_active,
    input  wire        frame_start,
    input  wire        index_commit,
    input  wire        de,                  // 与 x / y / rgb_in 同拍
    input  wire [9:0]  x,
    input  wire [9:0]  y,
    input  wire [7:0]  bri,                 // 亮度（折进 alpha，与原来一致）
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out,
    output wire [7:0]  audio_alpha,         // 音画同步：只有淡入淡出时声音跟着变
    output wire        active,
    // R12c 推移（像素域，p 在帧边界变，4 拍内算好；reader 在 frame_start 后第 7 拍锁存）
    input  wire [2:0]  active_index,        // 播放器当前图（换图那一拍记下旧图）
    output wire        push_on,
    output wire        push_h,              // 1 = 向左推移，0 = 向上推移
    output wire [2:0]  push_old,
    output wire [9:0]  push_off
);
    generate
    if (ENABLE == 0) begin : g_bypass
        assign next_out = next_in;   // 直通时预览没有效果
        assign prev_out = prev_in;
        assign busy = 1'b0;
        assign rgb_out = rgb_in;
        assign audio_alpha = 8'd255;
        assign active = 1'b0;
        assign push_on = 1'b0;  assign push_h = 1'b0;  assign push_old = 3'd0;  assign push_off = 10'd0;
    end else begin : g_eng
        localparam [3:0] E_FADE = 4'd0, E_WR = 4'd1, E_WL = 4'd2, E_WD = 4'd3, E_WU = 4'd4,
                         E_CIN = 4'd5, E_COUT = 4'd6, E_DIA = 4'd7, E_BH = 4'd8, E_BV = 4'd9,
                         E_CHK = 4'd10, E_DIS = 4'd11, E_MOS = 4'd12, E_CUT = 4'd13, E_PL = 4'd14, E_PU = 4'd15;
        localparam [1:0] S_IDLE = 2'd0, S_OUT = 2'd1, S_HOLD = 2'd2, S_IN = 2'd3;
        localparam integer CX = H_ACT / 2, CY = V_ACT / 2;
        localparam integer RMAX = CX + CY;          // 菱形最大半径；圆的最大半径取 sqrt 近似见下

        // ---------------- ctrl_clk 域：请求 / 放行 ----------------
        reg       req_tgl, ack_seen, dir_r, same_r;
        reg [3:0] eff_r, spd_r;
        reg       com_s1, com_s2, busy_s1, busy_s2;
        wire      running_pix;
        wire      com_tgl_w;
        // 请求发出后到像素域 busy 传回来之前有十几拍空窗：pend 在这段时间挡住重复请求
        reg       pend;
        assign busy = busy_s2 | pend;
        wire release_c = (com_s2 != ack_seen);
        assign next_out = release_c && !dir_r;
        assign prev_out = release_c &&  dir_r;
        always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
            if (!ctrl_rst_n) begin
                req_tgl <= 1'b0; ack_seen <= 1'b0; dir_r <= 1'b0; same_r <= 1'b0; eff_r <= 4'd0; spd_r <= 4'd3; pend <= 1'b0;
                com_s1 <= 1'b0; com_s2 <= 1'b0; busy_s1 <= 1'b0; busy_s2 <= 1'b0;
            end else begin
                busy_s1 <= running_pix;  busy_s2 <= busy_s1;
                com_s1 <= com_tgl_w;  com_s2 <= com_s1;
                if (busy_s2)
                    pend <= 1'b0;
                if ((next_in || prev_in || preview_in) && !busy_s2 && !pend) begin
                    pend    <= 1'b1;
                    req_tgl <= ~req_tgl;
                    dir_r   <= prev_in;
                    same_r  <= preview_in && !next_in && !prev_in;
                    eff_r   <= effect_in;
                    spd_r   <= speed_in;
                end
                if (release_c)
                    ack_seen <= com_s2;
            end
        end
        // ---------------- 像素域：状态机 ----------------
        reg [1:0] state;
        reg [8:0] p;                     // 0..256
        reg [3:0] eff;
        reg [6:0] step;
        reg       req_s1, req_s2, req_seen, com_tgl, nt_s1, nt_s2, same;
        reg [2:0] idx_q, old_idx;            // R12c：上一拍的 active_index（换图那一拍 = 旧图）/ 推移的旧图
        wire      push   = (eff == E_PL) || (eff == E_PU);
        wire      push_r = (eff_r == E_PL) || (eff_r == E_PU);
        assign running_pix = (state != S_IDLE) || (req_s2 != req_seen);
        assign com_tgl_w = com_tgl;
        assign active = (state != S_IDLE);

        function [6:0] step_of;          // 256 / 每阶段帧数（向上取整）
            input [3:0] s;
            case (s)
                4'd1: step_of = 7'd86;  4'd2: step_of = 7'd52;  4'd3: step_of = 7'd37;  4'd4: step_of = 7'd26;
                4'd5: step_of = 7'd19;  4'd6: step_of = 7'd15;  4'd7: step_of = 7'd11;  default: step_of = 7'd9;
            endcase
        endfunction
        wire [9:0] p_next = {1'b0, p} + {3'd0, step};
        wire       p_done = (p == 9'd256);

        always @(posedge pix_clk or negedge pix_rst_n) begin
            if (!pix_rst_n) begin
                state <= S_IDLE; p <= 9'd0; eff <= 4'd0; step <= 7'd9; same <= 1'b0; idx_q <= 3'd0; old_idx <= 3'd0;
                req_s1 <= 1'b0; req_s2 <= 1'b0; req_seen <= 1'b0; com_tgl <= 1'b0; nt_s1 <= 1'b0; nt_s2 <= 1'b0;
            end else begin
                req_s1 <= req_tgl;  req_s2 <= req_s1;
                nt_s1 <= no_transition;  nt_s2 <= nt_s1;
                idx_q <= active_index;
                case (state)
                S_IDLE: if (req_s2 != req_seen) begin
                    req_seen <= req_s2;
                    eff  <= eff_r;
                    step <= push_r ? {1'b0, step_of(spd_r)} >> 1 : step_of(spd_r);   // R12c 推移只有一个阶段，帧数翻倍
                    p    <= 9'd0;
                    same <= same_r;
                    old_idx <= active_index;
                    if (same_r && (!player_active || eff_r == E_CUT || nt_s2))
                        ;                        // 预览硬切 / 没在放 / 急救：什么都不做
                    else if (same_r)
                        state <= push_r ? S_IN : S_OUT;   // R12c 推移预览：这张图把自己推出去
                    else if (!player_active || eff_r == E_CUT || nt_s2 || push_r) begin
                        com_tgl <= ~com_tgl;     // 硬切 / 推移：直接放行，等换图
                        state   <= S_HOLD;
                    end else
                        state <= S_OUT;
                end
                S_OUT: if (frame_start) begin
                    if (same && nt_s2)                  // 预览途中进急救：直接收尾
                        state   <= S_IDLE;
                    else if (same && p_done) begin      // 预览：全黑后不换图，直接出现
                        p       <= 9'd0;
                        state   <= S_IN;
                    end else if (p_done || nt_s2) begin // 急救中不再数完淡出，下一帧直接收尾
                        state   <= S_HOLD;
                        com_tgl <= ~com_tgl;
                    end else
                        p <= (p_next >= 10'd256) ? 9'd256 : p_next[8:0];
                end
                // R7a：急救不切图，淡出途中进急救时放出的请求被丢掉，等不到 index_commit，急救中直接回 IDLE
                S_HOLD: if (index_commit || nt_s2) begin
                    p <= 9'd0;
                    old_idx <= idx_q;            // R12c：换图前那张
                    state <= (eff == E_CUT || nt_s2) ? S_IDLE : S_IN;
                end
                default: begin          // S_IN
                    if (nt_s2)
                        state <= S_IDLE;
                    else if (frame_start) begin
                        if (p_done)
                            state <= S_IDLE;
                        else
                            p <= (p_next >= 10'd256) ? 9'd256 : p_next[8:0];
                    end
                end
                endcase
            end
        end

        // ---------------- 每帧参数（p 只在帧边界变，下面几拍内算好，场消隐里早已稳定）----------------
        wire        in_ph  = (state == S_IN);
        wire        out_ph = (state == S_OUT);
        wire        hold   = (state == S_HOLD) && (eff != E_CUT) && !push && !nt_s2;
        wire        masking = (in_ph || out_ph) && !push && !nt_s2;
        reg  [9:0]  thr_x, thr_y;        // 擦除边界
        reg  [18:0] r2;                  // 圆半径平方
        reg  [9:0]  rd;                  // 菱形半径
        reg  [5:0]  thr_bh;              // 横百叶（每 32 行一条）
        reg  [6:0]  thr_bv;              // 竖百叶（每 64 列一条）
        reg  [6:0]  thr_c0, thr_c1;      // 棋盘：先揭一半格子再揭另一半
        reg  [2:0]  mos_k;               // 马赛克块 = 2^k
        reg  [8:0]  alpha9;              // 淡入淡出 / 马赛克亮度 0..256
        wire [8:0]  pq = in_ph ? p : (9'd256 - p);   // 马赛克 / 淡入淡出：亮度（出：256->0，进：0->256）
        reg  [9:0]  rr;                  // 圆半径
        wire [17:0] thr_x_m = p * H_ACT;
        wire [17:0] thr_y_m = p * V_ACT;
        // 圆最大半径 = sqrt(CX^2 + CY^2)，640x480 时 400；参数化时用 CX + CY/2 近似（只决定转场末尾那几帧）
        localparam integer RCIRC = (CX > CY) ? (CX + CY / 2) : (CY + CX / 2);
        wire [18:0] rr_m = p * RCIRC;
        wire [18:0] rd_m = p * RMAX;
        always @(posedge pix_clk) begin
            thr_x  <= thr_x_m[17:8];
            thr_y  <= thr_y_m[17:8];
            rr     <= (eff == E_COUT) ? (RCIRC - rr_m[17:8]) : rr_m[17:8];
            r2     <= rr * rr;
            rd     <= rd_m[17:8];
            thr_bh <= p[8:3];
            thr_bv <= p[8:2];
            thr_c0 <= (p >= 9'd128) ? 7'd64 : {1'b0, p[6:1]};
            thr_c1 <= p[8] ? 7'd64 : (p <= 9'd128) ? 7'd0 : {1'b0, p[6:1]};   // p = 256 时 p[6:1] 回到 0，要单独处理
            mos_k  <= (pq[8:5] >= 4'd5) ? 3'd0 : 3'd5 - pq[7:5];   // 亮度满 -> 块 1，越暗块越大（最大 32）
            alpha9 <= (eff == E_FADE || eff == E_MOS) ? pq : 9'd256;
        end

        // R12c 推移距离：缓出 pe = 256 - (256-p)²/256（开始快、到位前减速），off = pe × W（或 H）/ 256
        wire [8:0]  pr  = 9'd256 - p;
        reg  [17:0] pr2;
        reg  [8:0]  pe;
        reg  [9:0]  off_r;
        wire [18:0] off_m = pe * ((eff == E_PL) ? H_ACT : V_ACT);
        always @(posedge pix_clk) begin
            pr2   <= pr * pr;
            pe    <= 9'd256 - pr2[16:8];
            off_r <= off_m[17:8];
        end
        assign push_on  = in_ph && push && !nt_s2;
        assign push_h   = (eff == E_PL);
        assign push_old = old_idx;
        assign push_off = off_r;

        // ---------------- 每行参数 ----------------
        reg  [18:0] dy2;
        reg  [9:0]  ady;
        reg  [7:0]  rnd_y;
        wire [9:0]  ady_w = (y >= CY) ? (y - CY) : (CY - y);
        always @(posedge pix_clk) begin
            ady   <= ady_w;
            dy2   <= ady_w * ady_w;
            rnd_y <= {y[9:4], 2'b00} + {y[9:4], 4'b0000} + {y[9:4], 6'b000000} + y[9:4];   // ×85
        end

        // ---------------- 逐像素 ----------------
        // (x - CX)^2 递推：消隐里预置成 CX^2，有效像素每拍加 2(x-CX)+1，寄存器值始终对应当前 x
        reg  [18:0] dx2;
        wire signed [11:0] dxs = $signed({2'b00, x}) - CX;
        always @(posedge pix_clk) begin
            if (de)
                dx2 <= dx2 + {{7{dxs[11]}}, dxs[10:0], 1'b1};
            else
                dx2 <= CX * CX;
        end
        wire [9:0]  adx = (x >= CX) ? (x - CX) : (CX - x);
        wire [18:0] d2  = dx2 + dy2;
        wire [10:0] dsum = {1'b0, adx} + {1'b0, ady};

        // 溶解：16x16 Bayer 有序抖动阈值（每块 0..255 各一次）异或每块一个伪随机数，仍然每块均匀
        wire [3:0] bx = x[3:0], by = y[3:0];
        wire [3:0] bxy = bx ^ by;
        wire [7:0] bayer = {bxy[0], by[0], bxy[1], by[1], bxy[2], by[2], bxy[3], by[3]};
        wire [7:0] rnd_x = {x[9:4], 2'b00} + {x[9:4], 1'b0} + x[9:4] + {x[9:4], 5'b00000};   // ×39
        wire [7:0] dis_t = bayer ^ (rnd_x + rnd_y);

        reg cov;
        always @* begin
            case (eff)
                E_WR:   cov = (x < thr_x);
                E_WL:   cov = (x >= H_ACT - thr_x);
                E_WD:   cov = (y < thr_y);
                E_WU:   cov = (y >= V_ACT - thr_y);
                E_CIN:  cov = (d2 < r2) || p_done;
                E_COUT: cov = (d2 >= r2) || p_done;
                E_DIA:  cov = (dsum < {1'b0, rd}) || p_done;
                E_BH:   cov = ({1'b0, y[4:0]} < thr_bh);
                E_BV:   cov = ({1'b0, x[5:0]} < thr_bv);
                E_CHK:  cov = (x[6] ^ y[6]) ? ({1'b0, x[5:0]} < thr_c1) : ({1'b0, x[5:0]} < thr_c0);
                E_DIS:  cov = ({1'b0, dis_t} < p);
                default: cov = in_ph;            // 淡入淡出 / 马赛克：不挡，靠亮度
            endcase
        end
        wire shown = in_ph ? cov : !cov;          // 出：挡住的地方变黑；进：挡住的地方是新图

        // 马赛克：水平保持 + 行缓存竖直复制（块起始行写缓存，块内其余行读缓存）
        wire [9:0] kmask = (10'd1 << mos_k) - 10'd1;
        wire       blk_x0 = ((x & kmask) == 10'd0);
        wire       blk_y0 = ((y & kmask) == 10'd0);
        reg  [23:0] hreg;
        wire [23:0] hval = blk_x0 ? rgb_in : hreg;
        reg  [23:0] lbuf [0:1023];
        reg  [23:0] lb_q;
        wire [9:0]  x_nxt = de ? x + 10'd1 : 10'd0;
        always @(posedge pix_clk) begin
            if (de) hreg <= hval;
            if (de && blk_y0) lbuf[x] <= hval;
            lb_q <= lbuf[x_nxt];
        end
        wire mos_on = masking && (eff == E_MOS) && (mos_k != 3'd0);
        wire [23:0] src = !mos_on ? rgb_in : blk_y0 ? hval : lb_q;

        // 亮度：淡入淡出 alpha × (bri+1)/256，与原 video_fade_transition 路径一致（满亮 255 时比原图低 1 LSB）
        wire [7:0]  a8   = masking ? (alpha9[8] ? 8'd255 : alpha9[7:0]) : 8'd255;
        wire [15:0] ea_m = {8'd0, a8} * ({8'd0, bri} + 16'd1);
        wire [7:0]  ea   = ea_m[15:8];
        wire [15:0] mr = {8'd0, src[23:16]} * ea;
        wire [15:0] mg = {8'd0, src[15:8]}  * ea;
        wire [15:0] mb = {8'd0, src[7:0]}   * ea;
        wire [23:0] mul = {mr[15:8], mg[15:8], mb[15:8]};

        assign rgb_out = hold ? 24'h000000 :
                         (masking && !shown) ? 24'h000000 : mul;
        assign audio_alpha = (eff != E_FADE || nt_s2) ? 8'd255 :
                             hold ? 8'd0 : a8;
    end
    endgenerate
endmodule
