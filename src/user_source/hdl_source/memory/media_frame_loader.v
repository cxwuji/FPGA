`timescale 1ns/1ps

module media_frame_loader #(
    parameter integer ADDR_WIDTH = 21,
    parameter integer IMAGE_WORDS = 307200,
    parameter integer FIFO_DEPTH = 512,
    parameter integer BURST_SIZE = 128,
    parameter integer STALL_TIMEOUT = 65535,
    // 移植时加：BMP 文件里最后一行在前（自下而上），官方 frame_fifo_write 用 WRITE_V_FLIP 在写 SDRAM 时
    // 上下翻转；课程 loader 按顺序写，所以在这里补上同样的翻转。V_FLIP=0 时与课程原版完全一样。
    // R8-5b：负高度 BMP（自上而下）由输入 top_down 按图关掉翻转。
    parameter integer V_FLIP = 0,
    parameter integer IMAGE_WIDTH = 640,
    parameter integer IMAGE_HEIGHT = 480
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  load_start,
    input  wire [2:0]            image_index,     // R8-1a：0~4 = 轮播图 bank，5 = PIC6（急救图）
    input  wire                  pixel_valid,
    input  wire [23:0]           pixel_rgb,
    input  wire                  frame_commit,
    input  wire [7:0]            decode_error,
    output wire                  load_busy,
    output reg                   pixel_ready,     // R8-5a：FIFO 余量 > 16，上游（bmp_scaler）可以继续送
    input  wire                  top_down,        // R8-5b：本张图自上而下（文件头解析后变 1，像素来之前一定已稳定）
    output reg                   load_done,
    output reg  [4:0]            image_complete,  // 只管 bank0~4（播放 / 缩略图用）；bank5 由 sd_card_bmp 的 emg_ok 表示
    output reg  [7:0]            memory_error,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output reg                   app_wr_en,
    output reg  [ADDR_WIDTH-1:0] app_wr_addr,
    output reg  [3:0]            app_wr_mask,
    output wire [31:0]           app_wr_data
);
    localparam ERR_NONE          = 8'h00;
    localparam ERR_NOT_ACTIVE    = 8'h41;
    localparam ERR_FIFO_OVERFLOW = 8'h42;
    localparam ERR_PIXEL_COUNT   = 8'h43;
    localparam ERR_DECODE        = 8'h44;
    localparam ERR_SHORT_FRAME   = 8'h45;
    localparam ERR_WRITE_STALL   = 8'h46;

    localparam integer PTR_WIDTH = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam [PTR_WIDTH:0] EFFECTIVE_BURST =
        (BURST_SIZE < FIFO_DEPTH) ? BURST_SIZE : FIFO_DEPTH;
    localparam [ADDR_WIDTH-1:0] BANK0_BASE = 0;
    localparam [ADDR_WIDTH-1:0] BANK1_BASE = IMAGE_WORDS;
    localparam [ADDR_WIDTH-1:0] BANK2_BASE = IMAGE_WORDS * 2;
    localparam [ADDR_WIDTH-1:0] BANK3_BASE = IMAGE_WORDS * 3;
    localparam [ADDR_WIDTH-1:0] BANK4_BASE = IMAGE_WORDS * 4;
    localparam [ADDR_WIDTH-1:0] BANK5_BASE = IMAGE_WORDS * 5;

    reg active;
    reg [2:0] active_image;
    reg commit_seen;
    // 优化 A4：计数器按实际范围定位宽（原 32 位，pixels_received -> flip_addr 是 sd_card_clk 关键路径）
    reg [ADDR_WIDTH:0] pixels_received;
    reg [ADDR_WIDTH:0] pixels_written;
    reg [16:0] stall_count;
    reg [31:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [31:0] fifo_rd;
    reg [PTR_WIDTH-1:0] wr_ptr;
    reg [PTR_WIDTH-1:0] rd_ptr;
    reg [PTR_WIDTH:0] fifo_count;
    reg burst_active;
    reg [PTR_WIDTH:0] burst_remaining;
    reg [ADDR_WIDTH-1:0] flip_addr;     // V_FLIP：下一个写地址（从最后一行行首开始，每行写完跳回上一行行首）
    reg [15:0] flip_col;
    reg        td_q;            // R8-5b：top_down 上升沿 -> 这张图改成从 bank 首地址顺序写
    // R8-5b 时序：收尾判断"像素数对不对"先寄存（原来 22 位计数比较 -> image_complete 一拍，-0.1~-0.7ns）。
    //   fin_go = 上一拍已满足收尾条件；那一拍没有 push / pop，计数早已稳定，fin_ok 和它同拍有效，收尾晚 1 拍
    reg        fin_go, fin_ok;
    reg        nf;              // 这张图不翻转
    localparam [ADDR_WIDTH-1:0] FLIP_FIRST = (IMAGE_HEIGHT - 1) * IMAGE_WIDTH;
    localparam [ADDR_WIDTH-1:0] FLIP_JUMP  = IMAGE_WIDTH * 2 - 1;
    wire pop_allowed;
    wire push_allowed;
    wire start_burst;
    wire [PTR_WIDTH:0] next_burst_words;

    assign load_busy = active;
    // The inherited controller consumes a continuous App_wr_en burst and
    // handles busy/refresh internally. Those status outputs are not per-word
    // ready signals and must not split an active write burst.
    assign start_burst = active && controller_init_done && !burst_active &&
                         fifo_count != 0 &&
                         (fifo_count >= EFFECTIVE_BURST || commit_seen);
    assign next_burst_words = (fifo_count >= EFFECTIVE_BURST) ?
                              EFFECTIVE_BURST : fifo_count;
    assign pop_allowed = active && controller_init_done && burst_active &&
                         fifo_count != 0;
    // 优化 A1：留一个空位，读写永远不会同址（BRAM 同址读写结果与模式有关）
    assign push_allowed = active && pixel_valid &&
                          (fifo_count < FIFO_DEPTH - 1);
    assign app_wr_data = fifo_rd;

    // R8-5a：上游看到 ready 到像素真正进 FIFO 有 3~4 拍延迟，留 16 个空位
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pixel_ready <= 1'b0;
        else
            pixel_ready <= (fifo_count < FIFO_DEPTH - 16);
    end

    // 优化 A1：FIFO 存储放到不带复位的独立 always 块，TD 推断成 BRAM（原写法综合成约 2000 LUT）。
    // pop 那一拍读出，下一拍与 app_wr_en / app_wr_addr 同时有效，时序与原来一致
    always @(posedge clk) begin
        if (push_allowed)
            fifo_mem[wr_ptr] <= {8'h00, pixel_rgb};
        if (pop_allowed)
            fifo_rd <= fifo_mem[rd_ptr];
    end

    function [ADDR_WIDTH-1:0] bank_base;
        input [2:0] index;
        begin
            case (index)
                3'd0: bank_base = BANK0_BASE;
                3'd1: bank_base = BANK1_BASE;
                3'd2: bank_base = BANK2_BASE;
                3'd3: bank_base = BANK3_BASE;
                3'd4: bank_base = BANK4_BASE;
                default: bank_base = BANK5_BASE;
            endcase
        end
    endfunction

    task fail_load;
        input [7:0] code;
        begin
            memory_error <= code;
            active <= 1'b0;
            burst_active <= 1'b0;
            burst_remaining <= 0;
            load_done <= 1'b1;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            active_image <= 3'd0;
            commit_seen <= 1'b0;
            pixels_received <= 32'd0;
            pixels_written <= 32'd0;
            stall_count <= 32'd0;
            wr_ptr <= {PTR_WIDTH{1'b0}};
            rd_ptr <= {PTR_WIDTH{1'b0}};
            fifo_count <= {(PTR_WIDTH+1){1'b0}};
            burst_active <= 1'b0;
            burst_remaining <= 0;
            flip_addr <= {ADDR_WIDTH{1'b0}};
            flip_col <= 16'd0;
            td_q <= 1'b0;
            nf <= 1'b0;
            fin_go <= 1'b0;
            fin_ok <= 1'b0;
            load_done <= 1'b0;
            image_complete <= 5'd0;
            memory_error <= ERR_NONE;
            app_wr_en <= 1'b0;
            app_wr_addr <= {ADDR_WIDTH{1'b0}};
            app_wr_mask <= 4'b0000;
        end else begin
            load_done <= 1'b0;
            app_wr_en <= 1'b0;
            td_q <= top_down;
            fin_go <= active && commit_seen && fifo_count == 0 && !pop_allowed && !burst_active;
            fin_ok <= (pixels_received == IMAGE_WORDS) && (pixels_written == IMAGE_WORDS);

            if (load_start && !active) begin
                active <= 1'b1;
                active_image <= image_index;
                commit_seen <= 1'b0;
                pixels_received <= 32'd0;
                pixels_written <= 32'd0;
                stall_count <= 32'd0;
                wr_ptr <= {PTR_WIDTH{1'b0}};
                rd_ptr <= {PTR_WIDTH{1'b0}};
                fifo_count <= {(PTR_WIDTH+1){1'b0}};
                burst_active <= 1'b0;
                burst_remaining <= 0;
                flip_addr <= bank_base(image_index) + FLIP_FIRST;
                flip_col <= 16'd0;
                nf <= 1'b0;
                memory_error <= ERR_NONE;
                case (image_index)
                    3'd0: image_complete[0] <= 1'b0;
                    3'd1: image_complete[1] <= 1'b0;
                    3'd2: image_complete[2] <= 1'b0;
                    3'd3: image_complete[3] <= 1'b0;
                    3'd4: image_complete[4] <= 1'b0;
                    default: ;
                endcase
            end

            if (active && top_down && !td_q) begin
                flip_addr <= bank_base(active_image);
                nf <= 1'b1;
            end

            if (active) begin
                if (decode_error != 0) begin
                    fail_load(ERR_DECODE);
                end else if (pixel_valid && pixels_received >= IMAGE_WORDS) begin
                    fail_load(ERR_PIXEL_COUNT);
                end else if (pixel_valid && !push_allowed) begin
                    fail_load(ERR_FIFO_OVERFLOW);
                end else begin
                    if (start_burst) begin
                        burst_active <= 1'b1;
                        burst_remaining <= next_burst_words;
                    end

                    if (push_allowed) begin
                        wr_ptr <= wr_ptr + 1'b1;
                        pixels_received <= pixels_received + 1'b1;
                    end

                    if (pop_allowed) begin
                        app_wr_en <= 1'b1;
                        if (V_FLIP) begin
                            app_wr_addr <= flip_addr;
                            if (flip_col == IMAGE_WIDTH - 1) begin
                                flip_col <= 16'd0;
                                flip_addr <= nf ? flip_addr + 1'b1 : flip_addr - FLIP_JUMP;
                            end else begin
                                flip_col <= flip_col + 16'd1;
                                flip_addr <= flip_addr + 1'b1;
                            end
                        end else begin
                            app_wr_addr <= bank_base(active_image) + pixels_written[ADDR_WIDTH-1:0];
                        end
                        app_wr_mask <= 4'b0000;
                        rd_ptr <= rd_ptr + 1'b1;
                        pixels_written <= pixels_written + 1'b1;
                        stall_count <= 32'd0;
                        if (burst_remaining == 1) begin
                            burst_active <= 1'b0;
                            burst_remaining <= 0;
                        end else begin
                            burst_remaining <= burst_remaining - 1'b1;
                        end
                    end else if (fifo_count != 0 &&
                                 (commit_seen || fifo_count >= EFFECTIVE_BURST)) begin
                        if (stall_count == STALL_TIMEOUT)
                            fail_load(ERR_WRITE_STALL);
                        else
                            stall_count <= stall_count + 1'b1;
                    end else begin
                        stall_count <= 32'd0;
                    end

                    case ({push_allowed, pop_allowed})
                        2'b10: fifo_count <= fifo_count + 1'b1;
                        2'b01: fifo_count <= fifo_count - 1'b1;
                        default: fifo_count <= fifo_count;
                    endcase

                    if (frame_commit)
                        commit_seen <= 1'b1;

                    if (fin_go && commit_seen && fifo_count == 0 && !pop_allowed &&
                        !burst_active) begin
                        if (!fin_ok) begin
                            fail_load(ERR_SHORT_FRAME);
                        end else begin
                            case (active_image)
                                3'd0: image_complete[0] <= 1'b1;
                                3'd1: image_complete[1] <= 1'b1;
                                3'd2: image_complete[2] <= 1'b1;
                                3'd3: image_complete[3] <= 1'b1;
                                3'd4: image_complete[4] <= 1'b1;
                                default: ;
                            endcase
                            active <= 1'b0;
                            load_done <= 1'b1;
                        end
                    end
                end
            end else if (pixel_valid) begin
                memory_error <= ERR_NOT_ACTIVE;
            end
        end
    end
endmodule
