// 第6课：BMP 头解析 + RGB 拼装 + SDRAM 写握手（文档 5.4 修改点4 的“BMP解析+RGB拼装”放在这里）。
// 扇区扫描（ST_SCAN）已由 fat32_volume_scanner 取代；数据来源从“连续物理扇区”改为
// fat32_file_streamer 按 FAT 链输出的文件字节流（file_valid / file_byte / file_done）。
// 第4课的严格校验、错误码、超时、像素完整性校验全部保留。
// 加载分两遍（和原来一样，原代码也是读两次文件头扇区）：
//   第 1 遍 ST_LOAD_HDR ：启动文件流，收前 64 字节解析并校验文件头，然后中止文件流；
//   第 2 遍 ST_LOAD_DATA：SDRAM 写应答之后重新从头启动文件流，按 pixel_offset 取像素。
// 文件流没有反压，不能边等 SDRAM 应答边收数据，所以要分两遍。
// R8-5a：不再要求原图 = 640x480。原图宽高 8~MAX_SRC（正高度 = 自下而上），每行按 4 字节对齐跳过填充，
//   像素交给 bmp_scaler 等比缩放 / 居中加黑边，输出固定 OUT_W x OUT_H 个像素；文件读完后等 scaler 送完才回空闲。
// R8-5b：也接受负高度（自上而下存放），高度取绝对值，top_down = 1 告诉 loader 这张图不翻转。
module bmp_read #(
    parameter integer SD_READ_TIMEOUT_MS = 500,          // 2.4 加载超时：超过 500ms 没收到一个字节判定超时
    parameter integer CLK_FREQ_HZ        = 100_000_000,
    parameter integer OUT_W              = 640,          // R8-5a：输出帧尺寸（= SDRAM 一个 bank）
    parameter integer OUT_H              = 480,
    parameter integer MAX_SRC            = 1920          // R8-5a：原图宽高上限
)(
    input                       clk,
    input                       rst,
    output                      ready,

    // 加载一张图到 SDRAM
    input                       load_start,
    input                       load_abort,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,      // R8-5a 起不用（输出尺寸见 OUT_W / OUT_H），保留只为例化不用改
    input  [15:0]               bmp_height,
    input                       pix_ready,      // R8-5a：loader FIFO 还有余量
    output                      src_hold,       // R8-5a：暂停文件字节流（接扇区重放缓冲；停下前最多还会来 2 个字节）
    output                      top_down,       // R8-5b：本张图是负高度 BMP（自上而下），文件头解析后有效
    output     [10:0]           src_w,          // R8-5c：原图宽 / 高（高取绝对值），下一次 load_start 前一直有效
    output     [10:0]           src_h,

    output reg                  write_req,
    input                       write_req_ack,

    // 第6课：fat32_file_streamer 文件字节流
    output reg                  file_start,     // 启动一次文件读取（单拍）
    output reg                  file_abort,     // 中止文件读取（单拍，复位文件流模块）
    input                       file_ready,     // 流读器已出复位且空闲（file_abort 之后要过 2 拍才就绪）
    input                       file_valid,
    input  [7:0]                file_byte,
    input                       file_done,
    input  [7:0]                file_fs_error,  // 文件流错误码（FAT 链断、簇号越界等）

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data,

    output     [2:0]            dbg_state,     // 诊断：内部状态（0 空闲 2 读文件头 3 等 SDRAM 应答 4 读像素）

    // 2.2 错误码上报
    output reg [2:0]            bmp_error,     // 最近一次错误码
    output reg                  load_error     // 加载失败单拍脉冲
);

// 2.2 错误码
localparam [2:0] ERR_NONE      = 3'd0;
localparam [2:0] ERR_HEADER    = 3'd1;   // BMP 头校验失败
localparam [2:0] ERR_TIMEOUT   = 3'd2;   // SD 卡读取超时
localparam [2:0] ERR_TRUNCATED = 3'd3;   // 像素数据截断
localparam [2:0] ERR_FS        = 3'd4;   // 第6课：FAT 链错误导致像素不完整
localparam [2:0] ERR_SCALE     = 3'd5;   // R8-5a：缩放来不及（原图过于细长）

localparam integer TIMEOUT_CYCLES = (CLK_FREQ_HZ / 1000) * SD_READ_TIMEOUT_MS;
localparam [9:0]   HDR_BYTES      = 10'd64;      // 第 1 遍收这么多字节就够校验文件头（字段在前 34 字节）

localparam ST_IDLE      = 3'd0;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;

reg [2:0]  state;
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;
reg [11:0] hu;             // R8-5b：高度绝对值（负高度 = 自上而下）
reg        hneg, hhi_ok;
reg [15:0] bit_count;
reg [31:0] compression;
reg [31:0] dib_size;       // 2.1 新增：偏移 14-17
reg [15:0] planes;         // 2.1 新增：偏移 26-27
reg        sd_to;
reg [25:0] sd_timeout_cnt; // 2.4 新增：超时计数（优化 A4：500ms@100MHz < 2^26）
reg [11:0] src_rows;       // R8-5a：已收完的原图行数（取代 2.5 的像素计数）
reg [13:0] row_b;          // R8-5a：行内字节位置
reg [13:0] row_w3;         // 一行像素字节数 = 3W
reg [13:0] row_len;        // 一行字节数（4 字节对齐）
reg [13:0] row_lm1;        // R8-5b 时序：row_len - 1（行尾比较 -3.1ns）
reg        file_end_seen;  // 第 2 遍文件已读完，等 scaler 送完
reg        sc_start;
wire       sc_busy;
wire       sc_overrun;
wire       sc_hold;
reg        src_valid_r;
reg [23:0] src_rgb_r;

reg [23:0] bmp_len_cnt;    // R8-5b 资源：24 位（文件最大 1920x1920x3 约 11MB < 16MB，头校验要求文件大小高 8 位为 0）
reg [1:0]  bmp_byte_idx;
reg        file_start_pend;    // 要启动文件流，等 file_ready 再发 file_start

wire header_match;
wire bmp_data_valid;

assign ready = (state == ST_IDLE);
assign dbg_state = state;

// write_req_ack 来自 SDRAM 写侧（ext_mem_clk 125MHz，frame_fifo_write 的 S_ACK），与本模块 clk 异步。
// 原代码直接拿它做状态跳转（ST_LOAD_WAIT 3'b011 -> ST_LOAD_DATA 3'b100，三位同时翻转），
// 异步沿落在采样窗口里时各状态位可能采到不同值，状态机跳飞，本次加载卡到超时（数码管 E）。
// 先两级同步，状态机只看同步后的电平。应答在对方收到 write_req 撤销前一直保持，晚两拍无影响。
reg  [1:0] write_req_ack_sync;
wire       write_req_ack_s = write_req_ack_sync[1];
always @(posedge clk or posedge rst) begin
    if (rst)
        write_req_ack_sync <= 2'b00;
    else
        write_req_ack_sync <= {write_req_ack_sync[0], write_req_ack};
end
// 第4课严格校验。加了 32 位加法和比较后组合路径超过 10ns（TD GUI 编译 sd_card_clk -0.33ns，
// 上板扫描卡死），所以打一拍寄存。头字段在前 34 字节就解析完，校验结果要到收满 64 字节才使用，
// 晚一拍没有影响。
// R8-5a：宽高范围比较加进来后又超 10ns，再拆一级：先各自比较寄存，下一拍再相与
// R8-5b：高度先取绝对值（再多一级，头字段到收满 64 字节还有 30 多个字节，来得及）
reg hm_dims, hm_off;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        hu      <= 12'd0;
        hneg    <= 1'b0;
        hhi_ok  <= 1'b0;
        hm_dims <= 1'b0;
        hm_off  <= 1'b0;
    end else begin
        hneg    <= height[31];
        hu      <= height[31] ? (~height[11:0] + 12'd1) : height[11:0];
        hhi_ok  <= height[31] ? (&height[31:12] && height[11:0] != 12'd0) : (height[31:12] == 20'd0);
        hm_dims <= (width  >= 32'd8) && (width  <= MAX_SRC) &&
                   hhi_ok && (hu >= 12'd8) && (hu <= MAX_SRC);
        hm_off  <= (pixel_offset >= 32'd54) && (pixel_offset < file_len) && (file_len[31:24] == 8'd0);
    end
end
assign top_down = hneg;
assign src_w    = width[10:0];
assign src_h    = hu[10:0];
reg header_match_r;
always @(posedge clk or posedge rst) begin
    if (rst)
        header_match_r <= 1'b0;
    else
        header_match_r <= (header_0 == "B") &&                       // 签名 B
                          (header_1 == "M") &&                       // 签名 M
                          (dib_size >= 32'd40) &&                    // DIB 头大小 >= 40（新增）
                          hm_dims &&                                 // R8-5a：宽高 8~1920（R8-5b：高度可为负）
                          (planes == 16'd1) &&                       // 平面数 = 1（新增）
                          (bit_count    == 16'd24) &&                // 位深 = 24
                          (compression  == 32'd0) &&                 // 不压缩
                          hm_off;                                    // 54 <= 像素偏移 < 文件大小（新增）
        // 文件够不够长不再用 宽 x 高 x 3 预先算（要乘法器），改为读完时检查行数（ERR_TRUNCATED）
end
assign header_match = header_match_r;
// R8-5a 时序：字节最快隔 1 拍来一个（扇区重放 2 拍 1 字节），计数器变了以后下一拍把比较结果寄存好，
// 下一个字节来时用寄存的结果（和直接比较等价）
reg    in_pix_r, pix_r, row_last_r;
always @(posedge clk) begin
    in_pix_r   <= (bmp_len_cnt >= pixel_offset[23:0]) && (bmp_len_cnt < file_len[23:0]) && (src_rows < hu);
    pix_r      <= (row_b < row_w3);                                 // 行尾填充字节跳过
    row_last_r <= (row_b == row_lm1);
end
wire   in_pixels      = in_pix_r;
assign bmp_data_valid = file_valid && in_pix_r && pix_r;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if (state == ST_LOAD_HDR) begin
        if (file_valid && rd_cnt != 10'h3ff)
            rd_cnt <= rd_cnt + 10'd1;
    end else begin
        rd_cnt <= 10'd0;
    end
end

// R8-5b 时序：文件头字节先寄存一拍再按偏移分发（原来 file_valid / rd_cnt -> 32 个字段的使能一拍，-0.4~-1.9ns）。
//   字段在前 34 字节，校验在收满 64 字节后才用，晚一拍没有影响
// R8-5c 时序：偏移先译码成独热 hsel、清零条件 hclr 也先寄存（原来 hc 译码 + 状态 + load_start -> 字段使能，-0.2~-0.7ns）。
//   load_start 之后要先发文件读命令，第一个字节几十拍后才到，清零晚一拍没有影响
reg        hclr;
reg [33:0] hsel;
reg [7:0]  hb;
integer    hk;
always @(posedge clk) begin
    hclr <= (state == ST_IDLE) && load_start;
    hb   <= file_byte;
    for (hk = 0; hk < 34; hk = hk + 1)
        hsel[hk] <= (state == ST_LOAD_HDR) && file_valid && (rd_cnt == hk);
end
// 新的一次加载：清掉上一张的头字段，文件比 34 字节还短时不会拿旧值误判通过
always @(posedge clk or posedge rst) begin
    if (rst) header_0 <= 8'd0;
    else if (hclr) header_0 <= 8'd0;
    else if (hsel[0]) header_0 <= hb;
end
always @(posedge clk or posedge rst) begin
    if (rst) header_1 <= 8'd0;
    else if (hclr) header_1 <= 8'd0;
    else if (hsel[1]) header_1 <= hb;
end
always @(posedge clk or posedge rst) begin
    if (rst) file_len <= 32'd0;
    else if (hclr) file_len <= 32'd0;
    else if (hsel[2]) file_len[7:0] <= hb;
    else if (hsel[3]) file_len[15:8] <= hb;
    else if (hsel[4]) file_len[23:16] <= hb;
    else if (hsel[5]) file_len[31:24] <= hb;
end
always @(posedge clk or posedge rst) begin
    if (rst) pixel_offset <= 32'd54;
    else if (hclr) pixel_offset <= 32'd54;
    else if (hsel[10]) pixel_offset[7:0] <= hb;
    else if (hsel[11]) pixel_offset[15:8] <= hb;
    else if (hsel[12]) pixel_offset[23:16] <= hb;
    else if (hsel[13]) pixel_offset[31:24] <= hb;
end
always @(posedge clk or posedge rst) begin
    if (rst) dib_size <= 32'd0;
    else if (hclr) dib_size <= 32'd0;
    else if (hsel[14]) dib_size[7:0] <= hb;
    else if (hsel[15]) dib_size[15:8] <= hb;
    else if (hsel[16]) dib_size[23:16] <= hb;
    else if (hsel[17]) dib_size[31:24] <= hb;
end
always @(posedge clk or posedge rst) begin
    if (rst) width <= 32'd0;
    else if (hclr) width <= 32'd0;
    else if (hsel[18]) width[7:0] <= hb;
    else if (hsel[19]) width[15:8] <= hb;
    else if (hsel[20]) width[23:16] <= hb;
    else if (hsel[21]) width[31:24] <= hb;
end
always @(posedge clk or posedge rst) begin
    if (rst) height <= 32'd0;
    else if (hclr) height <= 32'd0;
    else if (hsel[22]) height[7:0] <= hb;
    else if (hsel[23]) height[15:8] <= hb;
    else if (hsel[24]) height[23:16] <= hb;
    else if (hsel[25]) height[31:24] <= hb;
end
always @(posedge clk or posedge rst) begin
    if (rst) planes <= 16'd0;
    else if (hclr) planes <= 16'd0;
    else if (hsel[26]) planes[7:0] <= hb;
    else if (hsel[27]) planes[15:8] <= hb;
end
always @(posedge clk or posedge rst) begin
    if (rst) bit_count <= 16'd0;
    else if (hclr) bit_count <= 16'd0;
    else if (hsel[28]) bit_count[7:0] <= hb;
    else if (hsel[29]) bit_count[15:8] <= hb;
end
always @(posedge clk or posedge rst) begin
    if (rst) compression <= 32'd0;
    else if (hclr) compression <= 32'd0;
    else if (hsel[30]) compression[7:0] <= hb;
    else if (hsel[31]) compression[15:8] <= hb;
    else if (hsel[32]) compression[23:16] <= hb;
    else if (hsel[33]) compression[31:24] <= hb;
end

// 第 2 遍：文件字节偏移（从文件第 0 字节开始数）
always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 24'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (file_valid)
            bmp_len_cnt <= bmp_len_cnt + 24'd1;
    end else begin
        bmp_len_cnt <= 24'd0;
    end
end

// R8-5a：行内字节位置 / 已收行数（取代 2.5 像素计数）。row_w3 / row_len 在等 SDRAM 应答时算好
always @(posedge clk or posedge rst) begin
    if (rst) begin
        src_rows <= 12'd0;
        row_b    <= 14'd0;
        row_w3   <= 14'd0;
        row_len  <= 14'd0;
        row_lm1  <= 14'd0;
    end else if (state == ST_LOAD_WAIT) begin
        src_rows <= 12'd0;
        row_b    <= 14'd0;
        row_w3   <= {width[12:0], 1'b0} + width[12:0];
        row_len  <= ({width[12:0], 1'b0} + width[12:0] + 14'd3) & 14'h3ffc;
        row_lm1  <= row_len - 14'd1;      // 等 SDRAM 应答要好几拍，row_len 早就稳定
    end else if (state == ST_LOAD_DATA && file_valid && in_pixels) begin
        if (row_last_r) begin
            row_b    <= 14'd0;
            src_rows <= src_rows + 12'd1;
        end else begin
            row_b <= row_b + 14'd1;
        end
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid)
            bmp_byte_idx <= (bmp_byte_idx == 2'd2) ? 2'd0 : (bmp_byte_idx + 2'd1);
    end else begin
        bmp_byte_idx <= 2'd0;
    end
end

// BMP 像素按 B、G、R 顺序存放，3 个字节拼成一个 24 位像素 {R, G, B}，交给 bmp_scaler
always @(posedge clk or posedge rst) begin
    if (rst) begin
        src_valid_r <= 1'b0;
        src_rgb_r   <= 24'd0;
    end else if (state == ST_LOAD_DATA && bmp_data_valid) begin
        case (bmp_byte_idx)
            2'd0: begin src_valid_r <= 1'b0; src_rgb_r[7:0]   <= file_byte; end
            2'd1: begin src_valid_r <= 1'b0; src_rgb_r[15:8]  <= file_byte; end
            2'd2: begin src_valid_r <= 1'b1; src_rgb_r[23:16] <= file_byte; end
            default: src_valid_r <= 1'b0;
        endcase
    end else begin
        src_valid_r <= 1'b0;
    end
end

// R8-5a：等比缩放 / 居中黑边，输出固定 OUT_W x OUT_H 个像素给 loader
wire        sc_valid;
wire [23:0] sc_rgb;
bmp_scaler #(
    .OUT_W (OUT_W),
    .OUT_H (OUT_H)
) u_scaler (
    .clk       (clk),
    .rst       (rst),
    .clr       (!sd_init_done || load_abort),
    .start     (sc_start),
    .src_w     (width[11:0]),
    .src_h     (hu),
    .src_td    (hneg),
    .in_valid  (src_valid_r),
    .in_rgb    (src_rgb_r),
    .out_ready (pix_ready),
    .out_valid (sc_valid),
    .out_rgb   (sc_rgb),
    .busy      (sc_busy),
    .hold      (sc_hold),
    .overrun   (sc_overrun)
);
assign src_hold = sc_hold && (state == ST_LOAD_DATA);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
    end else begin
        bmp_data_wr_en <= sc_valid && (state == ST_LOAD_DATA);
        bmp_data       <= sc_rgb;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        write_req         <= 1'b0;
        file_start        <= 1'b0;
        file_abort        <= 1'b0;
        file_start_pend   <= 1'b0;
        sd_to             <= 1'b0;
        sd_timeout_cnt    <= 32'd0;
        bmp_error         <= ERR_NONE;
        load_error        <= 1'b0;
        sc_start          <= 1'b0;
        file_end_seen     <= 1'b0;
    end else if (!sd_init_done || load_abort) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        write_req         <= 1'b0;
        file_start        <= 1'b0;
        file_abort        <= 1'b1;             // 停掉正在进行的文件读取
        file_start_pend   <= 1'b0;
        sd_to             <= 1'b0;
        sd_timeout_cnt    <= 32'd0;
        load_error        <= 1'b0;
        sc_start          <= 1'b0;
        file_end_seen     <= 1'b0;
    end else begin
        load_error <= 1'b0;
        file_start <= 1'b0;
        file_abort <= 1'b0;
        sc_start   <= 1'b0;

        // 流读器就绪后才真正发 file_start（file_abort 复位它后要过 2 拍才出复位）
        if (file_start_pend && file_ready && !file_abort) begin
            file_start      <= 1'b1;
            file_start_pend <= 1'b0;
        end

        // R9 时序：超时比较提前寄存（26 位比较 -> 状态 / file_start_pend 一拍 7 级，-0.3ns）；晚 1 拍报超时没关系
        sd_to <= (sd_timeout_cnt >= TIMEOUT_CYCLES) && ((state == ST_LOAD_HDR) || (state == ST_LOAD_DATA));
        // 2.4 超时计数：只在读文件头 / 读像素时累加，每收到一个字节清零
        if (((state == ST_LOAD_HDR) || (state == ST_LOAD_DATA)) && !file_valid)
            sd_timeout_cnt <= sd_timeout_cnt + 32'd1;
        else
            sd_timeout_cnt <= 32'd0;

        case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                write_req   <= 1'b0;

                if (load_start) begin
                    file_start_pend <= 1'b1;       // 第 1 遍：读文件头
                    state           <= ST_LOAD_HDR;
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;

                if (sd_to) begin
                    bmp_error       <= ERR_TIMEOUT;
                    load_error      <= 1'b1;
                    file_abort      <= 1'b1;
                    file_start_pend <= 1'b0;
                    state           <= ST_IDLE;
                end else if (rd_cnt >= HDR_BYTES || file_done) begin
                    file_abort <= 1'b1;            // 文件头够了，停掉第 1 遍
                    if (header_match) begin
                        write_req <= 1'b1;
                        sc_start  <= 1'b1;         // R8-5a：scaler 算缩放参数（第 2 遍像素来之前早就算完）
                        state     <= ST_LOAD_WAIT;
                    end else begin
                        bmp_error  <= ERR_HEADER;
                        load_error <= 1'b1;
                        state      <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack_s) begin
                    write_req       <= 1'b0;
                    file_start_pend <= 1'b1;       // 第 2 遍：从文件头开始重新读，取像素
                    file_end_seen   <= 1'b0;
                    state           <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;

                if (sd_to) begin
                    bmp_error       <= ERR_TIMEOUT;
                    load_error      <= 1'b1;
                    file_abort      <= 1'b1;
                    file_start_pend <= 1'b0;
                    state           <= ST_IDLE;
                end else if (sc_overrun) begin
                    bmp_error       <= ERR_SCALE;
                    load_error      <= 1'b1;
                    file_abort      <= 1'b1;
                    file_start_pend <= 1'b0;
                    state           <= ST_IDLE;
                end else if (file_done && src_rows < hu) begin
                    bmp_error  <= (file_fs_error != 8'd0) ? ERR_FS : ERR_TRUNCATED;
                    load_error <= 1'b1;
                    state      <= ST_IDLE;
                end else if (file_done) begin
                    file_end_seen <= 1'b1;         // R8-5a：像素都收齐了，等 scaler 把剩下的行 / 黑边送完
                end else if (file_end_seen && !sc_busy) begin
                    state <= ST_IDLE;
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule
