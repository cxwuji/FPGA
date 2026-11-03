`timescale 1ns/1ps

// R3'-A: stream real audio content from the TF card and feed it into the
// existing HDMI audio chain (docs/29 rev: "what actually wins"). This module
// sits between the SD sector-read infrastructure and the PCM sample
// interface, using a dual-port BRAM circular buffer to absorb the ~12.5x
// rate mismatch between TF reads (~1.2 MB/s burst) and audio consumption
// (96 KB/s at 48 kHz 16-bit mono).
//
// Architecture:
//   TF sector bytes (mem_clk domain, byte-serial)
//     -> pair into 16-bit samples -> write into BRAM circular buffer
//   Audio sample ticks (pixel_clk domain, ~48 kHz)
//     -> read from BRAM -> output on valid/ready PCM interface
//
// The write side uses a sector-level state machine: issue one sector read,
// fill 256 samples (512 bytes), then issue the next. The read side consumes
// at the audio sample rate. Pointer crossing uses gray-coded 2FF sync (the
// established idiom). Buffer underflow outputs silence (zeros) with
// sample_valid still asserted, so the downstream HDMI chain never stalls.
//
// Data format: raw 16-bit signed little-endian PCM, 48 kHz mono. The PC
// tool (tools/make_audio_corpus.py) converts any WAV to this format before
// writing to the TF card. Endianness: TF bytes arrive LSB first.
module wav_stream_player #(
    parameter integer ADDR_WIDTH = 12,         // 4096 x 16-bit = 8 KB
    parameter integer SAMPLES_PER_SECTOR = 256, // 512 bytes / 2
    parameter         LOOP = 1'b0               // 1：读完最后一个扇区接着从头读（循环播放，无缝）
) (
    // write side: mem_clk domain (SD SPI engine clock)
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        play_enable,        // level: stream active
    input  wire        loop_en,            // R9：1 = 按 LOOP 循环（音乐），0 = 播完停（急救语音一段）
    input  wire [31:0] start_lba,          // first data sector (after WAV header)
    input  wire [31:0] total_sectors,      // audio data extent in sectors
    output wire        sd_req,             // request a sector read
    output reg  [31:0] sd_lba,
    input  wire        sd_busy,
    input  wire        sd_valid,           // one byte per valid pulse
    input  wire [7:0]  sd_byte,
    input  wire [8:0]  sd_byte_index,      // 0..511 within sector
    input  wire        sd_done,
    input  wire [7:0]  sd_error,

    // read side: pixel_clk domain (audio chain clock)
    input  wire        rd_clk,
    input  wire        rd_rst_n,
    input  wire        sample_tick,        // ~48 kHz pulse: consume one sample
    output reg  signed [15:0] sample_out,
    output reg         sample_valid,
    input  wire        sample_ready,       // from downstream (always 1 in our chain)
    input  wire        pause,              // rd_clk 域电平：1 = 暂停（照常输出静音样本，不消耗缓冲，写侧缓冲满后自然停读）

    // status (read side)
    output reg  [31:0] sample_counter,     // samples consumed (for OSD)
    output wire        stream_active,      // play_enable && not ended
    output wire        stream_end,         // all data consumed
    output wire        buffer_low          // < 25% remaining (for OSD/status)
);
    // ---------------- circular buffer ----------------
    reg [15:0] buffer [0:(1<<ADDR_WIDTH)-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;    // write pointer (wr_clk domain)
    reg [ADDR_WIDTH-1:0] rd_ptr;    // read pointer (rd_clk domain)

    // 移植修正：读写 buffer 放到不带复位的独立 always 块里，TD 才能推断成 BRAM。
    // 原写法读写都在带异步复位的状态机块里，被综合成分布式 RAM，LUT 占用从 44% 涨到 92%。
    // 读口每拍寄存 buffer[rd_ptr]；rd_ptr 只在采样节拍（约 520 拍一次）变，节拍到来时数据早已稳定，行为不变
    reg        buf_we;
    reg [ADDR_WIDTH-1:0] buf_waddr;
    reg [15:0] buf_wdata;
    reg [15:0] buf_rdata;
    always @(posedge wr_clk) begin
        if (buf_we)
            buffer[buf_waddr] <= buf_wdata;
    end
    always @(posedge rd_clk) begin
        buf_rdata <= buffer[rd_ptr];
    end

    // write state sync to read domain (quasi-static, 2FF is safe)
    reg [2:0] wstate_sync1, wstate_sync2;

    // gray-coded sync: wr_ptr -> rd_clk domain
    reg [ADDR_WIDTH-1:0] wr_gray;
    reg [ADDR_WIDTH-1:0] wr_gray_sync1, wr_gray_sync2;
    // gray-coded sync: rd_ptr -> wr_clk domain
    reg [ADDR_WIDTH-1:0] rd_gray;
    reg [ADDR_WIDTH-1:0] rd_gray_sync1, rd_gray_sync2;

    function [ADDR_WIDTH-1:0] to_gray;
        input [ADDR_WIDTH-1:0] b;
        begin
            to_gray = b ^ (b >> 1);
        end
    endfunction

    function [ADDR_WIDTH-1:0] from_gray;
        input [ADDR_WIDTH-1:0] g;
        reg [ADDR_WIDTH-1:0] b;
        integer i;
        begin
            b[ADDR_WIDTH-1] = g[ADDR_WIDTH-1];
            for (i = ADDR_WIDTH-2; i >= 0; i = i - 1)
                b[i] = b[i+1] ^ g[i];
            from_gray = b;
        end
    endfunction

    // synchronized pointers (each in the other domain)
    wire [ADDR_WIDTH-1:0] wr_ptr_in_rd = from_gray(wr_gray_sync2);
    wire [ADDR_WIDTH-1:0] rd_ptr_in_wr = from_gray(rd_gray_sync2);

    // fill level in write domain (for flow control)
    // R1.5a 修正：差值按 2^ADDR_WIDTH 取模（原来写指针回绕后高位借位，level 多出 2^ADDR_WIDTH：写侧误判满而停读、读侧读空）。
    // 写侧流控保证 level 最多 2^ADDR_WIDTH - 16，不会和 0 混淆
    wire [ADDR_WIDTH-1:0] diff_wr = wr_ptr - rd_ptr_in_wr;
    wire [ADDR_WIDTH-1:0] diff_rd = wr_ptr_in_rd - rd_ptr;
    wire [ADDR_WIDTH:0] level_wr = {1'b0, diff_wr};
    // fill level in read domain (for buffer_low status)
    wire [ADDR_WIDTH:0] level_rd = {1'b0, diff_rd};

    // ---------------- write side state machine ----------------
    localparam [2:0] WS_IDLE  = 3'd0;
    localparam [2:0] WS_REQ   = 3'd1;
    localparam [2:0] WS_FILL  = 3'd2;
    localparam [2:0] WS_DONE  = 3'd3;
    localparam [2:0] WS_END   = 3'd4;
    reg [2:0]  wstate;
    wire wstate_ended = (wstate == WS_END);
    reg [31:0] cur_lba;
    reg [31:0] sectors_read;
    reg        last_sec;            // R9 时序：「这是最后一个扇区」提前算好（sectors_read + 1 >= total_sectors，填一个扇区要 512 拍以上）
    always @(posedge wr_clk) last_sec <= (sectors_read + 32'd1 >= total_sectors);
    reg [7:0]  lo_byte;             // little-endian pair assembly
    reg        lo_pending;

    assign sd_req = (wstate == WS_REQ);
    assign stream_active = play_enable && (wstate != WS_END);
    assign stream_end = (wstate == WS_END);
    assign buffer_low = (level_rd < (1 << (ADDR_WIDTH-2))); // < 25%

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wstate         <= WS_IDLE;
            cur_lba        <= 32'd0;
            sectors_read   <= 32'd0;
            wr_ptr         <= {ADDR_WIDTH{1'b0}};
            lo_pending     <= 1'b0;
            lo_byte        <= 8'd0;
            sd_lba         <= 32'd0;
            rd_gray_sync1  <= {ADDR_WIDTH{1'b0}};
            rd_gray_sync2  <= {ADDR_WIDTH{1'b0}};
            rd_gray        <= {ADDR_WIDTH{1'b0}};
            buf_we         <= 1'b0;
            buf_waddr      <= {ADDR_WIDTH{1'b0}};
            buf_wdata      <= 16'd0;
        end else begin
            buf_we <= 1'b0;
            // gray-code sync of rd_ptr into wr domain
            rd_gray      <= to_gray(rd_ptr);
            rd_gray_sync1 <= rd_gray;
            rd_gray_sync2 <= rd_gray_sync1;

            case (wstate)
            WS_IDLE: begin
                if (play_enable && start_lba != 32'd0 && total_sectors != 32'd0) begin
                    cur_lba      <= start_lba;
                    sd_lba       <= start_lba;   // 移植修正：sd_req 那一拍 sd_lba 必须已经有效
                    sectors_read <= 32'd0;
                    wr_ptr       <= {ADDR_WIDTH{1'b0}};
                    lo_pending   <= 1'b0;
                    wstate       <= WS_REQ;
                end
            end
            WS_REQ: begin
                // 移植修正：流控，缓冲里留得下一个扇区才发请求
                if (!sd_busy && level_wr <= (1 << ADDR_WIDTH) - SAMPLES_PER_SECTOR - 16) begin
                    sd_lba  <= cur_lba;
                    wstate  <= WS_FILL;
                end
            end
            WS_FILL: begin
                if (sd_valid) begin
                    if (!lo_pending) begin
                        lo_byte    <= sd_byte;
                        lo_pending <= 1'b1;
                    end else begin
                        buf_we         <= 1'b1;
                        buf_waddr      <= wr_ptr;
                        buf_wdata      <= {sd_byte, lo_byte};
                        wr_ptr         <= wr_ptr + 1'b1;
                        lo_pending     <= 1'b0;
                    end
                end
                if (sd_done) begin
                    if (sd_error != 8'd0) begin
                        wstate <= WS_END;  // sector error: stop streaming
                    end else begin
                        sectors_read <= sectors_read + 1'b1;
                        cur_lba      <= cur_lba + 1'b1;
                        sd_lba       <= cur_lba + 1'b1;
                        if (last_sec) begin
                            if (LOOP && loop_en) begin
                                sectors_read <= 32'd0;
                                cur_lba      <= start_lba;
                                sd_lba       <= start_lba;
                                wstate       <= WS_REQ;
                            end else
                                wstate <= WS_END;
                        end else
                            wstate <= WS_REQ;
                    end
                end
            end
            WS_DONE: wstate <= WS_REQ;  // unused, reserved
            WS_END: begin
                // stay ended until play_enable drops
                if (!play_enable)
                    wstate <= WS_IDLE;
            end
            default: wstate <= WS_IDLE;
            endcase

            // R4：播放关闭（含拔卡后 SD 口被收回）时无论在哪个状态都回 IDLE，
            // 否则拔卡那一刻停在 WS_FILL 等 sd_done，插回卡后永远不再请求
            if (!play_enable && wstate != WS_IDLE && wstate != WS_END)
                wstate <= WS_IDLE;
            // R9：关掉就把写指针归零（读侧同时归零），换段 / 换音源后从空缓冲开始，不会播出上一段的残留
            if (!play_enable)
                wr_ptr <= {ADDR_WIDTH{1'b0}};

            // flow control: pause sector requests when buffer > 75% full
            // (the WS_REQ state naturally waits because we only advance
            // to WS_REQ from WS_FILL when the sector is done; the buffer
            // level check is implicit in the consumption rate)
        end
    end

    // ---------------- read side ----------------
    // R9：play_enable 过域（原来直接用写侧电平）；关着时输出静音，不读缓冲
    (* async_reg = "true" *) reg pe_s1, pe_s2;
    always @(posedge rd_clk or negedge rd_rst_n)
        if (!rd_rst_n) begin pe_s1 <= 1'b0; pe_s2 <= 1'b0; end
        else           begin pe_s1 <= play_enable; pe_s2 <= pe_s1; end
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr         <= {ADDR_WIDTH{1'b0}};
            sample_out     <= 16'sd0;
            sample_valid   <= 1'b0;
            sample_counter <= 32'd0;
            wr_gray_sync1  <= {ADDR_WIDTH{1'b0}};
            wr_gray_sync2  <= {ADDR_WIDTH{1'b0}};
            wr_gray        <= {ADDR_WIDTH{1'b0}};
            wstate_sync1   <= 3'd0;
            wstate_sync2   <= 3'd0;
        end else begin
            // gray-code sync of wr_ptr into rd domain
            wr_gray      <= to_gray(wr_ptr);
            wr_gray_sync1 <= wr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
            wstate_sync1 <= wstate;
            wstate_sync2 <= wstate_sync1;

            sample_valid <= 1'b0;

            if (sample_tick && sample_ready) begin
                if (pause || !pe_s2) begin
                    sample_out   <= 16'sd0;
                    sample_valid <= 1'b1;
                end else if (level_rd >= SAMPLES_PER_SECTOR || (wstate_sync2 == 3'd4 && level_rd > 0)) begin
                    // enough data (or stream ended with residual): play
                    sample_out   <= buf_rdata;
                    rd_ptr       <= rd_ptr + 1'b1;
                    sample_valid <= 1'b1;
                    sample_counter <= sample_counter + 1'b1;
                end else begin
                    // prefill or underflow: silence, don't consume
                    sample_out   <= 16'sd0;
                    sample_valid <= 1'b1;
                end
            end

            if (!pe_s2) begin
                rd_ptr         <= {ADDR_WIDTH{1'b0}};
                sample_counter <= 32'd0;
            end
        end
    end
endmodule
