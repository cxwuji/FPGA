`timescale 1ns/1ps

// R8-3 音乐频谱（video_clk 域，layer_compositor 里例化；全部定点，不用 IP）
//   1 抽取：48 kHz -> 24 kHz，7 抽头半带 FIR [-1 0 9 16 9 0 -1]/32（移位加法），存进 512 点环形缓冲（BRAM32K）
//   2 每帧 frame_start 起算一次（约 3.3 万拍，一帧 42 万拍）：
//     LOAD 取最近 512 点 × Hann 窗（窗值由余弦表算），×2 后按位反序存进工作 RAM（实 / 虚各 512 × 18 位）
//     FFT  512 点基 2 DIT，原位，每级 /2 防溢出（|值| 永远不超过输入最大值）；一个乘法器分时做复数乘法，12 拍一个蝶形
//     MAG  频点 2~213：幅度 ≈ max(|实|,|虚|) + min/2，每根柱取所含频点的最大值（分柱见 include/spectrum_tables.vh，mel 刻度）
//          -> 对数高度：4 × log2 + 2 位小数 - 4（每 6 dB 4 点），限 0~60，存进 stg
//   3 下一个 frame_start（场消隐里）用 32 拍把 stg 合进显示高度（IIR 平滑；第一次算完之前不合，stg 上电没有值）：
//     升：直接跟上；降：每帧落 max(1, 差/8)。顶帽：被顶上去时停 30 帧，之后每帧落 1 点
//   显示：rd_bar（组合）-> 下一拍 rd_h / rd_cap
module audio_spectrum (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               frame_start,
    input  wire               pcm_valid,
    input  wire signed [15:0] pcm,
    input  wire [4:0]         rd_bar,
    output reg  [5:0]         rd_h,
    output reg  [5:0]         rd_cap
);
`include "../user_source/hdl_source/include/spectrum_tables.vh"  // TD 相对 td_project 目录；仿真加 -Isrc/td_project

    // ---------------- 1 抽取 FIR + 环形缓冲 ----------------
    reg signed [15:0] x0, x1, x2, x3, x4, x5, x6;
    reg               ph, fir_go;
    reg        [8:0]  wp;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x0 <= 0; x1 <= 0; x2 <= 0; x3 <= 0; x4 <= 0; x5 <= 0; x6 <= 0; ph <= 1'b0; fir_go <= 1'b0; wp <= 9'd0;
        end else begin
            fir_go <= 1'b0;
            if (pcm_valid) begin
                x6 <= x5; x5 <= x4; x4 <= x3; x3 <= x2; x2 <= x1; x1 <= x0; x0 <= pcm;
                ph <= ~ph;
                fir_go <= ph;
            end
            if (fir_go) wp <= wp + 9'd1;
        end
    end
    // y = (16·x3 + 9·(x2 + x4) - (x0 + x6)) / 32，9·s = 8·s + s
    wire signed [16:0] s24  = {x2[15], x2} + {x4[15], x4};
    wire signed [16:0] s06  = {x0[15], x0} + {x6[15], x6};
    wire signed [21:0] facc = ({{6{x3[15]}}, x3} <<< 4) + ({{5{s24[16]}}, s24} <<< 3) + {{5{s24[16]}}, s24} - {{5{s06[16]}}, s06};
    wire signed [16:0] fy   = facc >>> 5;
    wire signed [15:0] fsat = (fy > 17'sd32767) ? 16'sd32767 : (fy < -17'sd32768) ? -16'sd32768 : fy[15:0];
    (* ram_style = "bram_32k" *) reg signed [15:0] ring [0:511];
    reg        [8:0]  ring_ra;
    reg signed [15:0] ring_q;
    always @(posedge clk) if (fir_go) ring[wp] <= fsat;
    always @(posedge clk) ring_q <= ring[ring_ra];

    // ---------------- 工作 RAM（实 / 虚各 512 × 18 位）----------------
    reg signed [17:0] wre [0:511];
    reg signed [17:0] wim [0:511];
    reg               w_we;
    reg        [8:0]  w_wa, w_ra;
    reg signed [17:0] w_dre, w_dim, w_qre, w_qim;
    always @(posedge clk) if (w_we) begin wre[w_wa] <= w_dre; wim[w_wa] <= w_dim; end
    always @(posedge clk) begin w_qre <= wre[w_ra]; w_qim <= wim[w_ra]; end

    // ---------------- 余弦表（组合 ROM，寄存输出）+ 共用乘法器 ----------------
    reg        [7:0]  c_idx;
    reg signed [15:0] cq;
    always @(posedge clk) cq <= spec_cos(c_idx);
    reg signed [17:0] ma;
    reg signed [15:0] mb;
    reg signed [33:0] mp;
    always @(posedge clk) mp <= ma * mb;

    function [8:0] bitrev; input [8:0] v; integer q; for (q = 0; q < 9; q = q + 1) bitrev[q] = v[8 - q]; endfunction

    // ---------------- 2 计算状态机 ----------------
    localparam [2:0] S_IDLE = 3'd0, S_LOAD = 3'd1, S_FFT = 3'd2, S_MAG = 3'd3, S_WAIT = 3'd4;
    reg [2:0]  st;
    reg [3:0]  pc;                       // 一个样点 / 蝶形 / 频点内的第几拍
    reg [8:0]  n;                        // LOAD 样点号 / MAG 频点号
    reg [8:0]  rp;                       // 本次取数的最老样点
    reg [3:0]  stg_s;                    // FFT 第几级
    reg [7:0]  bf;                       // 这一级第几个蝶形
    reg [8:0]  t_top, t_bot;
    reg [7:0]  t_k;
    reg        c_neg;
    reg signed [17:0] tre, tim, bre, bim;
    reg signed [15:0] wr, ws;
    reg signed [34:0] acc_r, acc_i;
    reg [5:0]  bi;                       // MAG：当前柱
    reg [17:0] mx;                       // 当前柱的最大幅度
    reg [5:0]  stg [0:31];               // 本帧算出的目标高度
    reg        stg_we;
    reg [4:0]  stg_wa;
    reg [5:0]  stg_wd;
    always @(posedge clk) if (stg_we) stg[stg_wa] <= stg_wd;

    // LOAD：Hann 窗 w = (1 - cos) / 2，cos(2πn/512) 由 1/4 周期表按象限取
    wire [1:0]  ld_q   = n[8:7];
    wire [7:0]  ld_idx = ld_q[0] ? 8'd128 - {1'b0, n[6:0]} : {1'b0, n[6:0]};
    wire        ld_neg = (ld_q == 2'd1) || (ld_q == 2'd2);
    wire signed [16:0] cosv = c_neg ? -{cq[15], cq} : {cq[15], cq};
    wire [16:0] hann2  = 17'd32768 - cosv;                 // 0..65535
    // FFT 蝶形地址
    wire [8:0]  half   = 9'd1 << stg_s;
    wire [8:0]  jj     = {1'b0, bf} & (half - 9'd1);
    wire [8:0]  grp    = {1'b0, bf} >> stg_s;
    wire [8:0]  top_a  = (grp << (stg_s + 4'd1)) | jj;
    wire [7:0]  kk     = jj[7:0] << (4'd8 - stg_s);
    // 蝶形结果
    wire signed [17:0] t_r = (acc_r + 35'sd16384) >>> 15;
    wire signed [17:0] t_i = (acc_i + 35'sd16384) >>> 15;
    wire signed [18:0] sum_r = {tre[17], tre} + {t_r[17], t_r};
    wire signed [18:0] sum_i = {tim[17], tim} + {t_i[17], t_i};
    wire signed [18:0] dif_r = {tre[17], tre} - {t_r[17], t_r};
    wire signed [18:0] dif_i = {tim[17], tim} - {t_i[17], t_i};
    // MAG
    wire [17:0] ar  = w_qre[17] ? -w_qre : w_qre;
    wire [17:0] ai  = w_qim[17] ? -w_qim : w_qim;
    wire [17:0] amx = (ar > ai) ? ar : ai;
    wire [17:0] amn = (ar > ai) ? ai : ar;
    wire [18:0] mag = {1'b0, amx} + {2'b00, amn[17:1]};
    wire [17:0] mag_s = mag[18] ? 18'h3ffff : mag[17:0];
    function [5:0] logh;                  // 4 × log2(m) + 2 位小数 - 4，限 0~60
        input [17:0] m;
        integer q, p;
        reg [1:0] f;
        reg signed [8:0] h;
        begin
            p = -1;
            for (q = 0; q < 18; q = q + 1) if (m[q]) p = q;
            if (p < 0) logh = 6'd0;
            else begin
                f = (p >= 2) ? m[p-1 -: 2] : (p == 1) ? {m[0], 1'b0} : 2'b00;
                h = 4 * p + f - 4;
                logh = (h < 0) ? 6'd0 : (h > 60) ? 6'd60 : h[5:0];
            end
        end
    endfunction

    reg go;                               // 本帧要开始算
    reg have;                             // 至少算完过一次（stg 有值）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; pc <= 4'd0; n <= 9'd0; rp <= 9'd0; stg_s <= 4'd0; bf <= 8'd0;
            w_we <= 1'b0; w_wa <= 9'd0; w_ra <= 9'd0; w_dre <= 18'sd0; w_dim <= 18'sd0; ring_ra <= 9'd0;
            c_idx <= 8'd0; c_neg <= 1'b0; ma <= 18'sd0; mb <= 16'sd0;
            t_top <= 9'd0; t_bot <= 9'd0; t_k <= 8'd0; tre <= 0; tim <= 0; bre <= 0; bim <= 0; wr <= 0; ws <= 0;
            acc_r <= 0; acc_i <= 0; bi <= 6'd0; mx <= 18'd0; stg_we <= 1'b0; stg_wa <= 5'd0; stg_wd <= 6'd0; go <= 1'b0; have <= 1'b0;
        end else begin
            w_we <= 1'b0;  stg_we <= 1'b0;
            if (frame_start) go <= 1'b1;
            case (st)
                S_IDLE: if (go) begin
                    go <= 1'b0;  st <= S_LOAD;  n <= 9'd0;  pc <= 4'd0;  rp <= wp;
                end
                // ---- 每个样点 5 拍：取数 / 查表 -> 等 -> 乘 -> 等 -> 写 ----
                S_LOAD: begin
                    pc <= pc + 4'd1;
                    case (pc)
                        4'd0: begin ring_ra <= rp + n;  c_idx <= ld_idx;  c_neg <= ld_neg; end
                        4'd2: begin ma <= {{2{ring_q[15]}}, ring_q};  mb <= hann2[16:1]; end
                        4'd4: begin
                            w_we <= 1'b1;  w_wa <= bitrev(n);  w_dre <= mp >>> 14;  w_dim <= 18'sd0;
                            pc <= 4'd0;  n <= n + 9'd1;
                            if (n == 9'd511) begin st <= S_FFT;  stg_s <= 4'd0;  bf <= 8'd0; end
                        end
                        default: ;
                    endcase
                end
                // ---- 每个蝶形 12 拍 ----
                // W = cos - j·sin（k = j·2^(8-s)），t = bot·W：tr = br·wr + bi·ws，ti = bi·wr - br·ws
                S_FFT: begin
                    pc <= pc + 4'd1;
                    case (pc)
                        4'd0:  begin t_top <= top_a;  t_bot <= top_a | half;  t_k <= kk; end
                        4'd1:  begin w_ra <= t_top;  c_idx <= t_k[7] ? 8'd0 - t_k : t_k;  c_neg <= t_k[7]; end   // cos：k<128 C[k]，否则 -C[256-k]
                        4'd2:  begin w_ra <= t_bot;  c_idx <= t_k[7] ? {1'b0, t_k[6:0]} : 8'd128 - t_k; end     // sin：k<128 C[128-k]，否则 C[k-128]
                        4'd3:  begin tre <= w_qre;  tim <= w_qim;  wr <= c_neg ? -cq : cq; end
                        4'd4:  begin bre <= w_qre;  bim <= w_qim;  ws <= cq;  ma <= w_qre;  mb <= wr; end
                        4'd5:  begin ma <= bim;  mb <= ws; end
                        4'd6:  begin ma <= bim;  mb <= wr;  acc_r <= {mp[33], mp}; end
                        4'd7:  begin ma <= bre;  mb <= ws;  acc_r <= acc_r + {mp[33], mp}; end
                        4'd8:  begin acc_i <= {mp[33], mp}; end
                        4'd9:  begin acc_i <= acc_i - {mp[33], mp}; end
                        4'd10: begin w_we <= 1'b1;  w_wa <= t_top;  w_dre <= sum_r >>> 1;  w_dim <= sum_i >>> 1; end
                        default: begin
                            w_we <= 1'b1;  w_wa <= t_bot;  w_dre <= dif_r >>> 1;  w_dim <= dif_i >>> 1;
                            pc <= 4'd0;  bf <= bf + 8'd1;
                            if (bf == 8'd255) begin
                                stg_s <= stg_s + 4'd1;
                                if (stg_s == 4'd8) begin st <= S_MAG;  n <= {1'b0, spec_edge(6'd0)};  bi <= 6'd0;  mx <= 18'd0; end
                            end
                        end
                    endcase
                end
                // ---- 每个频点 3 拍 ----
                S_MAG: begin
                    pc <= pc + 4'd1;
                    case (pc)
                        4'd0: w_ra <= n;
                        4'd2: begin
                            pc <= 4'd0;  n <= n + 9'd1;
                            if (n == {1'b0, spec_edge(bi + 6'd1)}) begin       // 进入下一根柱：上一根定下来
                                stg_we <= 1'b1;  stg_wa <= bi[4:0];  stg_wd <= logh(mx);
                                bi <= bi + 6'd1;  mx <= mag_s;
                                if (bi == 6'd31) begin st <= S_WAIT;  have <= 1'b1; end
                            end else if (mag_s > mx)
                                mx <= mag_s;
                        end
                        default: ;
                    endcase
                end
                default: st <= S_IDLE;           // S_WAIT：等下一帧
            endcase
        end
    end

    // ---------------- 3 每帧合进显示高度（场消隐里 32 × 3 拍）----------------
    // hd / cp / hl 放分布式 RAM（不带复位，一拍只写一根柱）：做成寄存器阵列时每位都要写使能 + 多路读，u_spec 占 2100 LUT。
    // 上电第一次算完之前（!have）合并流程照跑，但写 0，把 RAM 清干净。
    reg [5:0] hd [0:31];
    reg [5:0] cp [0:31];
    reg [4:0] hl [0:31];
    reg       cm_on;
    reg [4:0] cm_a;
    reg [1:0] cm_p;
    reg [5:0] c_t, c_h, c_c;
    reg [4:0] c_l;
    reg       cm_we;
    reg [5:0] w_hd, w_cp;
    reg [4:0] w_hl;
    always @(posedge clk) begin c_t <= stg[cm_a]; c_h <= hd[cm_a]; c_c <= cp[cm_a]; c_l <= hl[cm_a]; end
    always @(posedge clk) if (cm_we) begin hd[cm_a] <= w_hd; cp[cm_a] <= w_cp; hl[cm_a] <= w_hl; end
    wire [5:0] dd   = c_h - c_t;
    wire [5:0] c_hn = (c_t >= c_h) ? c_t : c_h - ((dd[5:3] == 3'd0) ? 6'd1 : {3'd0, dd[5:3]});
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cm_on <= 1'b0; cm_a <= 5'd0; cm_p <= 2'd0; cm_we <= 1'b0; w_hd <= 6'd0; w_cp <= 6'd0; w_hl <= 5'd0;
        end else begin
            cm_we <= 1'b0;
            if (frame_start) begin
                cm_on <= 1'b1; cm_a <= 5'd0; cm_p <= 2'd0;
            end else if (cm_on) begin
                // 每根柱 3 拍：0 给地址 -> 1 读出 -> 2 算好写回（cm_we 下一拍写，地址还没变）
                cm_p <= (cm_p == 2'd2) ? 2'd0 : cm_p + 2'd1;
                if (cm_p == 2'd1) begin
                    cm_we <= 1'b1;
                    if (!have) begin
                        w_hd <= 6'd0;  w_cp <= 6'd0;  w_hl <= 5'd0;
                    end else begin
                        w_hd <= c_hn;
                        if (c_hn >= c_c) begin w_cp <= c_hn;  w_hl <= 5'd30; end
                        else if (c_l != 5'd0) begin w_cp <= c_c;  w_hl <= c_l - 5'd1; end
                        else begin w_cp <= (c_c != 6'd0) ? c_c - 6'd1 : 6'd0;  w_hl <= 5'd0; end
                    end
                end
                if (cm_p == 2'd2) begin
                    cm_a <= cm_a + 5'd1;
                    if (cm_a == 5'd31) cm_on <= 1'b0;
                end
            end
        end
    end
    always @(posedge clk) begin rd_h <= hd[rd_bar]; rd_cap <= cp[rd_bar]; end
endmodule
