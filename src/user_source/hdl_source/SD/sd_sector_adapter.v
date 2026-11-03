// SD卡扇区读接口适配层（第6课 5.3 节）+ 扇区重放缓冲（移植自参考工程 sd_sector_replay_buffer）
// 把完赛工程FAT32模块的sector_*接口，转换成官方sd_card_top的sd_sec_*接口
//
// 移植修正：原版把卡上读到的字节直接透传给 FAT32 / BMP / WAV，CRC 错了数据也已经写进帧缓存。
// 现在先把整个扇区收进 512 字节缓冲，CRC16 校验通过后才按顺序重放给下游：
//   - CRC 错（或字节数不是 512）：同一扇区重读，最多 MAX_CRC_RETRY 次；下游完全看不到坏数据
//   - 重读都失败：仍然交出最后一次的数据（与原来"第二次仍有 CRC 错就照常使用"的策略一致，
//     防止 CRC 误报时图片永远加载不上），并计入 crc_fail_cnt
//   - 连续 DISTRUST_LIMIT 个扇区都救不回来，判定 CRC 本身不可信，之后不再重读（只计数），
//     避免每个扇区都重读 MAX 次把加载拖到超时
// 重放每 REPLAY_GAP 个时钟出一个字节（原来卡上约 37 个时钟一个），下游时序余量不变。
// 接口与原版相同；sector_error 仍固定为 0（上面的策略决定不向下游报错）。
module sd_sector_adapter #(
    parameter integer MAX_CRC_RETRY  = 3,
    parameter integer DISTRUST_LIMIT = 8,
    parameter integer REPLAY_GAP     = 2       // 2 = 隔一拍出一个字节
) (
    input  wire        clk,
    input  wire        rst_n,               // 低有效复位
    // === 新模块侧（sector接口，FAT32模块用）===
    input  wire        sector_req,           // 读扇区请求（电平，req=1表示请求读）
    input  wire [31:0] sector_lba,           // 扇区号
    output wire        sector_busy,           // 忙（正在读）
    output reg         sector_valid,          // 字节有效脉冲
    output wire [7:0]  sector_byte,           // 当前字节
    output reg  [8:0]  sector_byte_index,     // 字节索引（0~511）
    input  wire        replay_hold,           // R8-5a：1 = 暂停重放（缩放行缓冲满，下游来不及）
    output wire        sector_done,            // 读完成脉冲
    output wire [7:0]  sector_error,           // 错误码（固定0，见上）
    // === 官方sd_card_top侧（sd_sec接口）===
    output reg         sd_sec_read,            // 读扇区请求（电平）
    output reg  [31:0] sd_sec_read_addr,       // 扇区号
    input  wire        sd_sec_read_data_valid,  // 字节有效
    input  wire [7:0]  sd_sec_read_data,       // 当前字节
    input  wire        sd_sec_read_end,         // 读完成
    input  wire        sd_sec_read_crc_err,     // 本扇区 CRC 错（与 sd_sec_read_end 同拍有效）
    // === 诊断 ===
    output reg  [7:0]  crc_retry_cnt,           // 因 CRC 错重读的次数（封顶 255）
    output reg  [7:0]  crc_fail_cnt,            // 重读也救不回来、带错交出的扇区数（封顶 255）
    output reg         crc_trusted              // 0 = 已判定 CRC 不可信，停止重读
);

    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_CAPTURE = 3'd1;
    localparam [2:0] ST_RETRY   = 3'd2;
    localparam [2:0] ST_REPLAY  = 3'd3;
    localparam [2:0] ST_LAST    = 3'd4;
    localparam [2:0] ST_DONE    = 3'd5;

    reg [2:0]  state;
    reg [9:0]  cap_cnt;        // 本次收到的字节数（0~512，多出来的不写）
    reg [1:0]  retry_left_used;
    reg [3:0]  fail_run;       // 连续救不回来的扇区数
    reg [8:0]  rd_addr;
    reg [3:0]  gap_cnt;

    // 缓冲存储：不带复位的独立 always 块，TD 推断成 BRAM
    reg [7:0]  sector_mem [0:511];
    reg [7:0]  mem_q;
    wire       cap_we = (state == ST_CAPTURE) && sd_sec_read_data_valid && !cap_cnt[9];
    always @(posedge clk) begin
        if (cap_we)
            sector_mem[cap_cnt[8:0]] <= sd_sec_read_data;
        mem_q <= sector_mem[rd_addr];
    end
    // R9 时序：BRAM 读出再寄存一拍才给下游（原来 mem_q 直接扇出约 60 个负载到扫描器 / 流读器 / 存档 / WAV，
    //   BRAM 出数慢，扫描器文件名比较、bmp_read 状态等 -0.5~-2.5ns）。
    //   REPLAY_GAP >= 2：rd_addr 在上一字节 valid 那拍更新，下一拍 mem_q、再下一拍 byte_q 有效，正好赶上本字节 valid
    reg [7:0]  byte_q;
    always @(posedge clk)
        byte_q <= mem_q;

    assign sector_busy  = (state != ST_IDLE);
    assign sector_byte  = byte_q;
    assign sector_done  = (state == ST_DONE);
    assign sector_error = 8'd0;

    wire bad_block = sd_sec_read_crc_err || (cap_cnt != 10'd512);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            sd_sec_read       <= 1'b0;
            sd_sec_read_addr  <= 32'd0;
            cap_cnt           <= 10'd0;
            retry_left_used   <= 2'd0;
            fail_run          <= 4'd0;
            rd_addr           <= 9'd0;
            gap_cnt           <= 4'd0;
            sector_valid      <= 1'b0;
            sector_byte_index <= 9'd0;
            crc_retry_cnt     <= 8'd0;
            crc_fail_cnt      <= 8'd0;
            crc_trusted       <= 1'b1;
        end else begin
            sector_valid <= 1'b0;
            case (state)
                // 请求到来时锁存扇区号，发出读请求
                ST_IDLE: if (sector_req) begin
                    sd_sec_read      <= 1'b1;
                    sd_sec_read_addr <= sector_lba;
                    cap_cnt          <= 10'd0;
                    retry_left_used  <= 2'd0;
                    state            <= ST_CAPTURE;
                end

                ST_CAPTURE: begin
                    if (cap_we)
                        cap_cnt <= cap_cnt + 10'd1;
                    if (sd_sec_read_end) begin
                        sd_sec_read <= 1'b0;
                        if (bad_block && crc_trusted && retry_left_used != MAX_CRC_RETRY) begin
                            // 同一扇区重读（sd_sec_read 先拉低一拍，官方状态机回到等待态后再请求）
                            retry_left_used <= retry_left_used + 2'd1;
                            if (crc_retry_cnt != 8'hff)
                                crc_retry_cnt <= crc_retry_cnt + 8'd1;
                            state <= ST_RETRY;
                        end else begin
                            if (bad_block) begin
                                if (crc_fail_cnt != 8'hff)
                                    crc_fail_cnt <= crc_fail_cnt + 8'd1;
                                if (crc_trusted) begin
                                    if (fail_run == DISTRUST_LIMIT - 1)
                                        crc_trusted <= 1'b0;
                                    fail_run <= fail_run + 4'd1;
                                end
                            end else begin
                                fail_run <= 4'd0;
                            end
                            rd_addr <= 9'd0;
                            gap_cnt <= 4'd0;
                            state   <= ST_REPLAY;
                        end
                    end
                end

                ST_RETRY: begin
                    sd_sec_read <= 1'b1;
                    cap_cnt     <= 10'd0;
                    state       <= ST_CAPTURE;
                end

                // 重放：rd_addr 给出后下一拍 mem_q 有效，在 gap 最后一拍打出 valid
                ST_REPLAY: begin
                    if (replay_hold) begin
                        // R8-5a：下游要求暂停，停在当前字节，gap 不走
                    end else if (gap_cnt == REPLAY_GAP - 1) begin
                        gap_cnt           <= 4'd0;
                        sector_valid      <= 1'b1;
                        sector_byte_index <= rd_addr;
                        if (rd_addr == 9'd511)
                            state <= ST_LAST;
                        else
                            rd_addr <= rd_addr + 9'd1;
                    end else begin
                        gap_cnt <= gap_cnt + 4'd1;
                    end
                end

                // 最后一个字节 valid 这一拍；下一拍 done（与原来一样，done 在最后一个字节之后）
                ST_LAST: state <= ST_DONE;

                ST_DONE: state <= ST_IDLE;

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
