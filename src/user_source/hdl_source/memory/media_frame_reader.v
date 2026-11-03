`timescale 1ns/1ps

module media_frame_reader #(
    parameter integer ADDR_WIDTH = 21,
    parameter integer IMAGE_WORDS = 307200,
    parameter integer FIFO_DEPTH = 512,
    parameter integer FIFO_MARGIN = 8,
    parameter integer BURST_SIZE = 128,
    parameter integer BURST_GAP_CYCLES = 12,
    parameter integer MAX_INFLIGHT_BURSTS = 2,
    parameter integer DIAG_RETURN_PATTERN = 0,
    parameter integer DIAG_SYNTH_STREAM = 0,
    parameter integer IMAGE_WIDTH = 640,    // 第14课：缩略图读法用
    parameter integer IMAGE_HEIGHT = 480
) (
    input  wire                  mem_clk,
    input  wire                  mem_rst_n,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output reg                   app_rd_en,
    output reg  [ADDR_WIDTH-1:0] app_rd_addr,
    input  wire                  sdram_rd_valid,
    input  wire [31:0]           sdram_rd_data,

    input  wire                  pix_clk,
    input  wire                  pix_rst_n,
    input  wire                  frame_start,
    input  wire [2:0]            active_index,
    // R7b-1 急救覆盖（像素域，调用方已在 frame_start 锁存，整帧不变）：ovr_en = 1 时本帧改读 ovr_bank（0~5），
    // 不按缩略图读；播放器的 active_index 不动，覆盖撤掉就回到原来那张图
    input  wire                  ovr_en,
    input  wire [2:0]            ovr_bank,
    input  wire                  thumb_mode,       // 1 = 本帧按 2x2 缩略图读（R11；与 active_index 同时锁存）
    // R5 画面变换：非缩略图帧按行 DDA 取源行（输出第 j 行 = 源行 v(j) = starty + j·stepy，16.16，翻转 / 越界钳位）。
    // 像素域整帧不变的寄存器，和 active_index 一起在请求时锁存
    input  wire [31:0]           geo_stepy,
    input  wire signed [31:0]    geo_starty,
    input  wire                  geo_flip,
    // R12c 推移转场（像素域，transition_engine 给出，frame_start 后几拍内稳定；请求晚 7 拍锁存）：本帧每行由旧图、新图各取一段
    //   push_h = 1 向左推移：每行 = 旧图 [off, W) + 新图 [0, off)；push_h = 0 向上推移：行 [0, H-off) = 旧图行 L+off，其余 = 新图行 L-(H-off)
    //   active_index 已经是新图，push_old = 旧图；off = 0 整帧读旧图、off = W / H 整帧读新图（都按普通帧读）
    input  wire                  push_on,
    input  wire                  push_h,
    input  wire [2:0]            push_old,
    input  wire [9:0]            push_off,
    input  wire                  pixel_consume,
    output wire [23:0]           pixel_rgb,
    output wire                  pixel_valid,
    output reg                   underflow,

    output reg                   reader_busy,
    output reg                   frame_read_done,
    output reg  [2:0]            reader_index,
    output reg  [7:0]            reader_error
);
    localparam [7:0] ERR_NONE          = 8'h00;
    localparam [7:0] ERR_FRAME_OVERRUN = 8'h61;
    localparam [7:0] ERR_FIFO_OVERFLOW = 8'h62;
    localparam [7:0] ERR_UNDERFLOW     = 8'h63;
    localparam [7:0] ERR_SHORT_FRAME   = 8'h64;
    localparam integer FIFO_COUNT_W = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam integer BURST_COUNT_W =
        (BURST_SIZE < 2) ? 1 : $clog2(BURST_SIZE + 1);
    localparam integer INFLIGHT_COUNT_W =
        (MAX_INFLIGHT_BURSTS * BURST_SIZE < 2) ? 1 :
        $clog2(MAX_INFLIGHT_BURSTS * BURST_SIZE + 1);

    reg request_pending_pix;
    reg request_toggle_pix;
    reg [2:0] request_index_pix;
    reg request_thumb_pix;
    reg [31:0] request_stepy_pix;
    reg signed [31:0] request_starty_pix;
    reg request_flip_pix;
    reg [2:0] request_dly_pix;              // R12c：frame_start 后等 7 拍再锁存（转场引擎的推移参数这时才算好）
    reg request_push_pix, request_ph_pix;
    reg [2:0] request_old_pix;
    reg [9:0] request_off_pix;
    reg push_s1, ph_s1, push_mem, ph_mem;
    reg [2:0] old_s1, old_mem;
    reg [9:0] off_s1, off_mem;
    reg [31:0] stepy_s1, stepy_mem;
    reg signed [31:0] starty_s1, starty_mem;
    reg flip_s1, flip_mem;
    // 行 DDA（mem 域）
    reg signed [31:0] g_vacc;                // 下一行的源坐标
    reg [9:0]  g_col;
    reg [ADDR_WIDTH-1:0] g_rowbase_next;     // 下一行第一段首地址（g_base_cur + 源行 x W）
    reg [ADDR_WIDTH-1:0] g_rowbase2_next;    // R12c：下一行第二段（新图）首地址
    reg [ADDR_WIDTH-1:0] g_ptr;              // R12c：下一个要发的读地址（原来每拍算 行首 + 列号）
    reg [ADDR_WIDTH-1:0] g_rb2;              // R12c：本行第二段首地址
    reg [ADDR_WIDTH-1:0] g_base_bot;         // R12c：新图 bank 基址（向上推移的下半部分 / 向左推移的第二段）
    reg [9:0]  g_vline;                      // R12c：g_vacc 现在对应第几个输出行
    reg [9:0]  g_split_m1;                   // R12c：向上推移时最后一个旧图行（再下一行换新图、源行从 starty 重新算），不推移时 1023（不会到）
    reg        g_sw;                         // R12c：g_vline == g_split_m1（寄存，g_vline 隔 W 拍才变）
    reg [9:0]  g_adv;                        // R12c：帧开始先把 DDA 往前推几行（向上推移：旧图从第 off 行起）
    reg [2:0]  g_settle;                     // R12c：DDA 最后一次变化后等行地址流水线 3 拍
    reg [9:0]  g_len1_m1, g_len1_m2;         // R12c：每行第一段长度 - 1 / - 2（不推移时 W - 1，第二段不会用到）
    reg        g_l1;                         // R12c：当前列是第一段最后一列（下一个字跳到第二段）
    reg signed [15:0] g_vi;                  // 下一行源行号（整数部分）
    reg [9:0]  g_row;                        // 钳位 + 翻转后
    reg [ADDR_WIDTH-1:0] g_base_cur;
    reg frame_armed_pix;
    reg [ADDR_WIDTH:0] consumed_count_pix;

    reg request_sync1_mem;
    reg request_sync2_mem;
    reg request_seen_mem;
    reg [2:0] index_sync1_mem;
    reg [2:0] index_sync2_mem;
    reg thumb_sync1_mem, thumb_sync2_mem;
    reg reload_thumb_mem;
    reg reader_thumb;                       // 本帧缩略图读法
    reg [ADDR_WIDTH:0] total_words_mem;     // 本帧要读的字数：IMAGE_WORDS 或 2 x IMAGE_WORDS
    reg [ADDR_WIDTH:0] total_last_mem;
    // R11 2x2 缩略图地址发生器（R8-1a 的 3x2 是 3 取 1 点采样，字断成点）：每个显示行依次读左右两格 bank 的同一源行（2W 字），
    //   返回字两两平均（每色 (a + b) / 2）进 FIFO（正好 W 字）：x < W/2 来自左格、其余右格（每格 320x240，见 thumbnail_layout）。
    //   上排 [0, TH) 读 bank0/1 的源行 2y，下排 [TH, 2TH) 读 bank2/3 的源行 2(y-TH)（纵向隔行取）。读带宽是 3x2 的 2/3。
    localparam integer TH  = IMAGE_HEIGHT / 2;
    reg [9:0]  t_col;                       // 源行内列号 0..IMAGE_WIDTH-1
    reg [1:0]  t_side;                      // 0 / 1 = 左 / 右格
    reg [ADDR_WIDTH-1:0] t_base;            // 当前段（当前格的源行）首地址
    reg [ADDR_WIDTH-1:0] t_b1;              // 本行右格的首地址
    // 下一行的参数（提前一行算好、寄存，换行那一拍只搬寄存器）
    reg [9:0]  n_line;                      // 下一行的行号
    reg        n_grp;                       // 下一行用下排（bank2/3）
    reg [ADDR_WIDTH-1:0] n_rowoff;          // 下一行的源行偏移
    reg [ADDR_WIDTH-1:0] n_g0, n_g1;        // 下一行两格的 bank 基址（寄存）
    reg [ADDR_WIDTH-1:0] n_b0, n_b1;        // 下一行两格的首地址 = 基址 + 偏移（寄存）
    reg [1:0]  t_keep;                      // 返回字奇偶：0 = 存进 t_hold，1 = 和 t_hold 平均后写 FIFO
    reg [23:0] t_hold;
    reg reload_pending_mem;
    reg [2:0] reload_index_mem;
    reg [2:0] fifo_reset_count_mem;
    reg [ADDR_WIDTH:0] issued_count_mem;
    reg [ADDR_WIDTH:0] returned_count_mem;
    reg [INFLIGHT_COUNT_W-1:0] inflight_count_mem;
    reg inflight_empty_mem /* fehdl keep="true" */;
    reg burst_active_mem;
    reg [BURST_COUNT_W-1:0] burst_issued_mem;
    reg [BURST_COUNT_W-1:0] burst_target_mem;
    reg [7:0] burst_gap_count_mem;
    reg [ADDR_WIDTH:0] diag_written_count_mem;
    reg [9:0] diag_column_mem;
    reg [23:0] diag_rgb_mem;
    reg [1:0] fifo_release_mem;
    reg [1:0] fifo_release_pix;

    wire fifo_reset_request = !mem_rst_n || !pix_rst_n ||
                              (fifo_reset_count_mem != 0);
    wire fifo_reset = fifo_reset_request ||
                      !fifo_release_mem[1] || !fifo_release_pix[1];
    wire fifo_full;
    wire fifo_empty;
    wire fifo_almost_full;
    wire [FIFO_COUNT_W-1:0] fifo_wrusedw;
    wire [31:0] fifo_raw_data;
    wire fifo_raw_valid;
    wire fifo_raw_read_en;
    wire prefetch_valid;
    wire [31:0] prefetch_data;
    wire pixel_pop = pixel_consume && prefetch_valid;
    wire [ADDR_WIDTH:0] inflight_words =
        {{(ADDR_WIDTH+1-INFLIGHT_COUNT_W){1'b0}}, inflight_count_mem};
    wire final_return = returned_count_mem == total_last_mem;
    // 缩略图读法只有 1/2 返回字进 FIFO
    wire [ADDR_WIDTH:0] inflight_fifo_words = reader_thumb ? (inflight_words >> 1) : inflight_words;
    wire [ADDR_WIDTH+1:0] reserved_words =
        {{(ADDR_WIDTH+2-FIFO_COUNT_W){1'b0}}, fifo_wrusedw} +
        {{1{1'b0}}, inflight_fifo_words};
    localparam integer FULL_BURSTS_ONLY = (IMAGE_WORDS % BURST_SIZE) == 0;
    wire [ADDR_WIDTH:0] remaining_words = total_words_mem - issued_count_mem;
    wire [ADDR_WIDTH:0] next_burst_words =
        FULL_BURSTS_ONLY ? BURST_SIZE :
        ((remaining_words > BURST_SIZE) ? BURST_SIZE : remaining_words);
    wire [ADDR_WIDTH:0] next_burst_fifo_words = reader_thumb ? (next_burst_words >> 1) : next_burst_words;
    wire [ADDR_WIDTH+2:0] reserved_after_burst =
        {{1{1'b0}}, reserved_words} + {{2{1'b0}}, next_burst_fifo_words};
    wire inflight_window_ok = (MAX_INFLIGHT_BURSTS == 1) ?
        inflight_empty_mem :
        ((inflight_words + next_burst_words) <=
         (MAX_INFLIGHT_BURSTS * BURST_SIZE));
    wire fifo_reservation_ok =
        reserved_after_burst <= (FIFO_DEPTH - FIFO_MARGIN);
    reg inflight_window_ok_q;
    reg fifo_reservation_ok_q;
    // 移植修正（参考工程）：SDRAM 刷新打开后，新突发只在控制器空闲且不在刷新准入窗口时开始（已开始的突发不拆）
    wire start_burst = !DIAG_SYNTH_STREAM && reader_busy && controller_init_done &&
                       !controller_busy && !refresh_active &&
                       fifo_reset_count_mem == 0 && !g_first && !burst_active_mem &&
                       burst_gap_count_mem == 0 &&
                       issued_count_mem != total_words_mem &&
                       inflight_window_ok_q && fifo_reservation_ok_q;
    wire issue_allowed = !DIAG_SYNTH_STREAM && reader_busy && burst_active_mem;
    wire diag_stream_write = DIAG_SYNTH_STREAM && reader_busy &&
                             !fifo_reset && !fifo_full;
    wire fifo_write_enable = DIAG_SYNTH_STREAM ? diag_stream_write :
                             (sdram_rd_valid && !fifo_reset && !fifo_full &&
                              (!reader_thumb || t_keep[0]));   // 缩略图：两个字写一个（平均）
    // 缩略图横向两点平均（每色 9 位和取高 8 位）
    wire [8:0]  t_sr = {1'b0, t_hold[23:16]} + {1'b0, sdram_rd_data[23:16]};
    wire [8:0]  t_sg = {1'b0, t_hold[15:8]}  + {1'b0, sdram_rd_data[15:8]};
    wire [8:0]  t_sb = {1'b0, t_hold[7:0]}   + {1'b0, sdram_rd_data[7:0]};
    wire [31:0] fifo_write_data = (DIAG_RETURN_PATTERN || DIAG_SYNTH_STREAM) ? {8'h00, diag_rgb_mem} :
                                  reader_thumb ? {8'h00, t_sr[8:1], t_sg[8:1], t_sb[8:1]} : sdram_rd_data;

    always @* begin
        if (diag_column_mem < 10'd80)
            diag_rgb_mem = 24'hffffff;
        else if (diag_column_mem < 10'd160)
            diag_rgb_mem = 24'hffff00;
        else if (diag_column_mem < 10'd240)
            diag_rgb_mem = 24'h00ffff;
        else if (diag_column_mem < 10'd320)
            diag_rgb_mem = 24'h00ff00;
        else if (diag_column_mem < 10'd400)
            diag_rgb_mem = 24'hff00ff;
        else if (diag_column_mem < 10'd480)
            diag_rgb_mem = 24'hff0000;
        else if (diag_column_mem < 10'd560)
            diag_rgb_mem = 24'h0000ff;
        else
            diag_rgb_mem = 24'h000000;
    end

    function [ADDR_WIDTH-1:0] bank_base;
        input [2:0] index;
        begin
            case (index)
                3'd0: bank_base = {ADDR_WIDTH{1'b0}};
                3'd1: bank_base = IMAGE_WORDS;
                3'd2: bank_base = IMAGE_WORDS * 2;
                3'd3: bank_base = IMAGE_WORDS * 3;
                3'd4: bank_base = IMAGE_WORDS * 4;
                default: bank_base = IMAGE_WORDS * 5;
            endcase
        end
    endfunction

    // Delay the request by one pixel clock so media_player_control can commit
    // active_index on the frame_start edge before this module captures it.
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            request_pending_pix <= 1'b0;
            request_toggle_pix <= 1'b0;
            request_index_pix <= 3'd0;
            request_thumb_pix <= 1'b0;
            request_stepy_pix <= 32'd65536;
            request_starty_pix <= 32'sd0;
            request_flip_pix <= 1'b0;
            request_dly_pix <= 3'd0;
            request_push_pix <= 1'b0; request_ph_pix <= 1'b0; request_old_pix <= 3'd0; request_off_pix <= 10'd0;
            frame_armed_pix <= 1'b0;
            consumed_count_pix <= 0;
            underflow <= 1'b0;
            fifo_release_pix <= 2'b00;
        end else begin
            if (fifo_reset_request)
                fifo_release_pix <= 2'b00;
            else
                fifo_release_pix <= {fifo_release_pix[0], 1'b1};

            if (frame_start) begin
                if (frame_armed_pix && consumed_count_pix != IMAGE_WORDS) begin
                    underflow <= 1'b1;
                end
                consumed_count_pix <= 0;
                request_pending_pix <= 1'b1;
                request_dly_pix <= 3'd6;
            end else if (request_pending_pix && request_dly_pix != 3'd0) begin
                request_dly_pix <= request_dly_pix - 3'd1;
            end else if (request_pending_pix) begin
                // R12c 推移：off = 0 整帧读旧图；off 到头整帧读新图；中间才两张图各取一段
                request_index_pix <= ovr_en ? ovr_bank : (push_on && !thumb_mode && push_off == 10'd0) ? push_old : active_index;
                request_push_pix <= push_on && !ovr_en && !thumb_mode && push_off != 10'd0 &&
                                    (push_h ? (push_off < IMAGE_WIDTH) : (push_off < IMAGE_HEIGHT));
                request_ph_pix <= push_h;  request_old_pix <= push_old;  request_off_pix <= push_off;
                request_thumb_pix <= thumb_mode && !ovr_en;
                request_stepy_pix <= geo_stepy;
                request_starty_pix <= geo_starty;
                request_flip_pix <= geo_flip;
                request_toggle_pix <= ~request_toggle_pix;
                request_pending_pix <= 1'b0;
                frame_armed_pix <= 1'b1;
            end

            if (pixel_consume) begin
                if (prefetch_valid)
                    consumed_count_pix <= consumed_count_pix + 1'b1;
                else if (frame_armed_pix)
                    underflow <= 1'b1;
            end
        end
    end

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            request_sync1_mem <= 1'b0;
            request_sync2_mem <= 1'b0;
            request_seen_mem <= 1'b0;
            index_sync1_mem <= 3'd0;
            index_sync2_mem <= 3'd0;
            thumb_sync1_mem <= 1'b0;
            thumb_sync2_mem <= 1'b0;
            reload_thumb_mem <= 1'b0;
            reader_thumb <= 1'b0;
            total_words_mem <= IMAGE_WORDS;
            total_last_mem <= IMAGE_WORDS - 1;
            t_col <= 10'd0; t_side <= 2'd0; t_keep <= 2'd0;
            t_base <= {ADDR_WIDTH{1'b0}}; t_b1 <= {ADDR_WIDTH{1'b0}};
            n_line <= 10'd0; n_grp <= 1'b0; n_rowoff <= {ADDR_WIDTH{1'b0}};
            reload_pending_mem <= 1'b0;
            reload_index_mem <= 3'd0;
            fifo_reset_count_mem <= 3'd0;
            issued_count_mem <= 0;
            returned_count_mem <= 0;
            inflight_count_mem <= 0;
            inflight_empty_mem <= 1'b1;
            burst_active_mem <= 1'b0;
            burst_issued_mem <= 0;
            burst_target_mem <= 0;
            burst_gap_count_mem <= 0;
            diag_written_count_mem <= 0;
            diag_column_mem <= 0;
            fifo_release_mem <= 2'b00;
            inflight_window_ok_q <= 1'b1;
            fifo_reservation_ok_q <= 1'b1;
            app_rd_en <= 1'b0;
            app_rd_addr <= 0;
            reader_busy <= 1'b0;
            frame_read_done <= 1'b0;
            reader_index <= 3'd0;
            reader_error <= ERR_NONE;
        end else begin
            if (fifo_reset_request)
                fifo_release_mem <= 2'b00;
            else
                fifo_release_mem <= {fifo_release_mem[0], 1'b1};

            request_sync1_mem <= request_toggle_pix;
            request_sync2_mem <= request_sync1_mem;
            index_sync1_mem <= request_index_pix;
            index_sync2_mem <= index_sync1_mem;
            thumb_sync1_mem <= request_thumb_pix;
            thumb_sync2_mem <= thumb_sync1_mem;
            stepy_s1 <= request_stepy_pix;  starty_s1 <= request_starty_pix;  flip_s1 <= request_flip_pix;
            push_s1 <= request_push_pix;  ph_s1 <= request_ph_pix;  old_s1 <= request_old_pix;  off_s1 <= request_off_pix;
            app_rd_en <= 1'b0;
            frame_read_done <= 1'b0;
            inflight_window_ok_q <= inflight_window_ok;
            fifo_reservation_ok_q <= fifo_reservation_ok;

            if (fifo_reset_count_mem != 0)
                fifo_reset_count_mem <= fifo_reset_count_mem - 1'b1;
            if (burst_gap_count_mem != 0)
                burst_gap_count_mem <= burst_gap_count_mem - 1'b1;

            case ({issue_allowed, sdram_rd_valid})
                2'b10: begin
                    inflight_count_mem <= inflight_count_mem + 1'b1;
                    inflight_empty_mem <= 1'b0;
                end
                2'b01: begin
                    if (!inflight_empty_mem) begin
                        inflight_count_mem <= inflight_count_mem - 1'b1;
                        if (inflight_count_mem == 1)
                            inflight_empty_mem <= 1'b1;
                    end
                end
                default: begin
                    inflight_count_mem <= inflight_count_mem;
                    inflight_empty_mem <= inflight_empty_mem;
                end
            endcase

            if (request_sync2_mem != request_seen_mem) begin
                request_seen_mem <= request_sync2_mem;
                reload_pending_mem <= 1'b1;
                reload_index_mem <= index_sync2_mem;
                reload_thumb_mem <= thumb_sync2_mem;
                stepy_mem <= stepy_s1;  starty_mem <= starty_s1;  flip_mem <= flip_s1;
                push_mem <= push_s1;  ph_mem <= ph_s1;  old_mem <= old_s1;  off_mem <= off_s1;
                if (reader_busy || !inflight_empty_mem) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    reader_error <= ERR_FRAME_OVERRUN;
                end
            end

            if (reload_pending_mem && inflight_empty_mem) begin
                reload_pending_mem <= 1'b0;
                reader_index <= reload_index_mem;
                reader_thumb <= reload_thumb_mem;
                total_words_mem <= reload_thumb_mem ? IMAGE_WORDS * 2 : IMAGE_WORDS;
                total_last_mem <= reload_thumb_mem ? IMAGE_WORDS * 2 - 1 : IMAGE_WORDS - 1;
                // 第 0 行：bank0/1 的源行 0；下一行 = 第 1 行，源行 2
                t_col <= 10'd0; t_side <= 2'd0; t_keep <= 2'd0;
                t_base <= bank_base(3'd0); t_b1 <= bank_base(3'd1);
                n_line <= 10'd1; n_grp <= 1'b0; n_rowoff <= IMAGE_WIDTH * 2;
                // R12c：第一段 = 旧图（推移）或本图；向左推移把起始列 off 并进基址；向上推移先把 DDA 推 off 行
                g_base_cur <= push_mem ? bank_base(old_mem) + (ph_mem ? {{(ADDR_WIDTH-10){1'b0}}, off_mem} : {ADDR_WIDTH{1'b0}})
                                       : bank_base(reload_index_mem);
                g_base_bot <= bank_base(reload_index_mem);
                g_split_m1 <= (push_mem && !ph_mem) ? IMAGE_HEIGHT - 1 - off_mem : 10'd1023;
                g_adv      <= (push_mem && !ph_mem) ? off_mem : 10'd0;
                g_len1_m1  <= (push_mem && ph_mem) ? IMAGE_WIDTH - 1 - off_mem : IMAGE_WIDTH - 1;
                g_len1_m2  <= (push_mem && ph_mem) ? IMAGE_WIDTH - 2 - off_mem : IMAGE_WIDTH - 2;
                g_vline <= 10'd0;
                g_settle <= 3'd3;
                g_col <= 10'd0;
                g_vacc <= starty_mem;                // 先装第 0 行，下一拍起 g_rowbase_next 跟上
                g_first <= 1'b1;
                issued_count_mem <= 0;
                returned_count_mem <= 0;
                inflight_count_mem <= 0;
                inflight_empty_mem <= 1'b1;
                burst_active_mem <= 1'b0;
                burst_issued_mem <= 0;
                burst_target_mem <= 0;
                burst_gap_count_mem <= 0;
                diag_written_count_mem <= 0;
                diag_column_mem <= 0;
                fifo_reset_count_mem <= 3'd4;
                reader_busy <= 1'b1;
                reader_error <= ERR_NONE;
            end

            // R12c 向上推移：帧开始先把 DDA 往前推 off 行（每拍一行，最多 H 拍，场消隐里来得及；不推移时 0 拍）
            if (g_first && g_adv != 10'd0) begin
                g_adv    <= g_adv - 10'd1;
                g_vacc   <= g_vacc + $signed(stepy_mem);
                g_settle <= 3'd3;
            end else if (g_settle != 3'd0)
                g_settle <= g_settle - 3'd1;
            // 第 0 行地址：DDA 停下后等 3 拍流水线算好再用（不推移时正好 FIFO 复位 4 拍的最后一拍，和原来一样）
            if (g_first && fifo_reset_count_mem <= 3'd1 && g_adv == 10'd0 && g_settle == 3'd0) begin
                g_first <= 1'b0;
                g_ptr   <= g_rowbase_next;
                g_rb2   <= g_rowbase2_next;
                g_l1    <= (g_len1_m1 == 10'd0);
                g_vline <= g_vline + 10'd1;
                if (g_sw) begin                  // 下一行起是新图（向上推移只剩 1 行旧图时）
                    g_vacc     <= starty_mem;
                    g_base_cur <= g_base_bot;
                end else
                    g_vacc <= g_vacc + $signed(stepy_mem);
            end

            if (start_burst) begin
                burst_active_mem <= 1'b1;
                burst_issued_mem <= 0;
                burst_target_mem <= next_burst_words[BURST_COUNT_W-1:0];
            end

            if (reader_thumb && sdram_rd_valid) begin
                t_keep <= {1'b0, ~t_keep[0]};
                if (!t_keep[0])
                    t_hold <= sdram_rd_data[23:0];
            end

            if (issue_allowed) begin
                app_rd_en <= 1'b1;
                if (reader_thumb) begin
                    app_rd_addr <= t_base + t_col;
                    if (t_col == IMAGE_WIDTH - 1) begin
                        t_col <= 10'd0;
                        if (t_side == 2'd0) begin
                            t_side <= 2'd1;
                            t_base <= t_b1;
                        end else begin
                            // 换行：搬入下一行的两格首地址，再推算下下一行
                            t_side <= 2'd0;
                            t_base <= n_b0;  t_b1 <= n_b1;
                            n_line <= n_line + 10'd1;
                            if (n_line + 10'd1 == TH) begin
                                n_grp <= 1'b1;  n_rowoff <= {ADDR_WIDTH{1'b0}};
                            end else if (n_line + 10'd1 >= 2 * TH) begin
                                n_grp <= 1'b0;  n_rowoff <= {ADDR_WIDTH{1'b0}};
                            end else
                                n_rowoff <= n_rowoff + IMAGE_WIDTH * 2;
                        end
                    end else begin
                        t_col <= t_col + 1'b1;
                    end
                end else begin
                    // R12c：地址用寄存器 g_ptr 直接发（原来 行首 + 列号 每拍一个加法）；第一段最后一列之后跳到第二段
                    app_rd_addr <= g_ptr;
                    if (g_col == IMAGE_WIDTH - 1) begin
                        g_col   <= 10'd0;
                        g_ptr   <= g_rowbase_next;
                        g_rb2   <= g_rowbase2_next;
                        g_l1    <= (g_len1_m1 == 10'd0);
                        g_vline <= g_vline + 10'd1;
                        if (g_sw) begin              // 向上推移：下一行起是新图，源行从 starty 重新算
                            g_vacc     <= starty_mem;
                            g_base_cur <= g_base_bot;
                        end else
                            g_vacc <= g_vacc + $signed(stepy_mem);
                    end else begin
                        g_col <= g_col + 10'd1;
                        g_ptr <= g_l1 ? g_rb2 : g_ptr + 1'b1;
                        g_l1  <= (g_col == g_len1_m2);
                    end
                end
                issued_count_mem <= issued_count_mem + 1'b1;
                burst_issued_mem <= burst_issued_mem + 1'b1;
                if (burst_issued_mem + 1'b1 == burst_target_mem) begin
                    burst_active_mem <= 1'b0;
                    burst_gap_count_mem <= BURST_GAP_CYCLES;
                end
            end

            if (!DIAG_SYNTH_STREAM && sdram_rd_valid) begin
                returned_count_mem <= returned_count_mem + 1'b1;
                if (fifo_full) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    reader_error <= ERR_FIFO_OVERFLOW;
                end else if (final_return) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    frame_read_done <= 1'b1;
                end
            end

            if (DIAG_SYNTH_STREAM && diag_stream_write) begin
                diag_written_count_mem <= diag_written_count_mem + 1'b1;
                diag_column_mem <= (diag_column_mem == 10'd639) ?
                                   10'd0 : diag_column_mem + 1'b1;
                if (diag_written_count_mem == IMAGE_WORDS - 1) begin
                    reader_busy <= 1'b0;
                    frame_read_done <= 1'b1;
                end
            end else if (!DIAG_SYNTH_STREAM && DIAG_RETURN_PATTERN &&
                         sdram_rd_valid) begin
                diag_column_mem <= (diag_column_mem == 10'd639) ?
                                   10'd0 : diag_column_mem + 1'b1;
            end
        end
    end

    // 行 DDA 流水线：g_vacc -> 整数行号 -> 钳位 / 翻转 -> 行首地址（W = 640 时 r·640 = r·512 + r·128）
    reg g_first;
    function [ADDR_WIDTH-1:0] row_off;      // r x IMAGE_WIDTH，640 时用移位相加（不占 DSP）
        input [9:0] r;
        row_off = (IMAGE_WIDTH == 640) ? ({{(ADDR_WIDTH-19){1'b0}}, r, 9'd0} + {{(ADDR_WIDTH-17){1'b0}}, r, 7'd0})
                                       : r * IMAGE_WIDTH;
    endfunction
    always @(posedge mem_clk) begin
        g_vi  <= g_vacc[31:16];
        g_row <= (g_vi < 0) ? 10'd0 : (g_vi > IMAGE_HEIGHT - 1) ? IMAGE_HEIGHT - 1 : g_vi[9:0];
        g_rowbase_next  <= g_base_cur + row_off(flip_mem ? (IMAGE_HEIGHT - 1 - g_row) : g_row);
        g_rowbase2_next <= g_base_bot + row_off(flip_mem ? (IMAGE_HEIGHT - 1 - g_row) : g_row);   // R12c 向左推移的第二段（新图同一源行）
        g_sw            <= (g_vline == g_split_m1);
        // R11 缩略图：下一行两格首地址（两级寄存；n_* 只在换行时变，下一次换行在 2W 拍之后）
        n_g0 <= bank_base(n_grp ? 3'd2 : 3'd0);
        n_g1 <= bank_base(n_grp ? 3'd3 : 3'd1);
        n_b0 <= n_g0 + n_rowoff;
        n_b1 <= n_g1 + n_rowoff;
    end

    rfifo_32_32_512 #(
        .DATA_WIDTH_W(32), .DATA_WIDTH_R(32),
        .ADDR_WIDTH_W(FIFO_COUNT_W), .ADDR_WIDTH_R(FIFO_COUNT_W),
        .AL_FULL_NUM(FIFO_DEPTH-FIFO_MARGIN), .AL_EMPTY_NUM(2),
        .SHOW_AHEAD_EN(1'b0), .OUTREG_EN("NOREG")
    ) u_read_fifo (
        .rst(fifo_reset), .clkw(mem_clk), .clkr(pix_clk),
        .we(fifo_write_enable), .di(fifo_write_data),
        .re(fifo_raw_read_en), .dout(fifo_raw_data), .valid(fifo_raw_valid),
        .full_flag(fifo_full), .empty_flag(fifo_empty),
        .afull(fifo_almost_full), .aempty(),
        .wrusedw(fifo_wrusedw), .rdusedw()
    );

    fifo_prefetch_2 #(.DATA_WIDTH(32)) u_prefetch (
        .clk(pix_clk), .rst(fifo_reset), .raw_empty(fifo_empty),
        .raw_valid(fifo_raw_valid), .raw_data(fifo_raw_data),
        .raw_read_en(fifo_raw_read_en), .consume(pixel_pop),
        .out_valid(prefetch_valid), .out_empty(), .out_data(prefetch_data)
    );

    assign pixel_rgb = prefetch_data[23:0];
    assign pixel_valid = prefetch_valid;

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            // The memory-domain error remains authoritative for controller faults.
        end else if (underflow) begin
            // underflow is exported separately; the Top may merge it as 8'h63.
        end
    end

endmodule
