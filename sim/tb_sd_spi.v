`timescale 1ns/1ps
// SD 卡 SPI 读取自检：真实 sd_card_top（sd_card_sec_read_write + sd_card_cmd + spi_master）
// 对接一个位级 SD 卡模型（SPI 模式 3：SCLK 下降沿出数据，上升沿采样）。
//
// 可调宏：
//   MISO_DELAY  SCLK 下降沿到 MISO 变化的总延迟（ns）= FPGA 输出 + 走线 + 卡 tODLY + FPGA 输入
//               SD 规范默认速度 tODLY 最大 14ns，加上 IO 和走线，实际 15~25ns
//   FAULT       0 无故障；1 第 3 次读不发数据令牌；2 第 4 次读回错误令牌；3 第 5 次读翻转 1 个数据位
//               4 每次读都翻转 1 位（CRC 永远错）；5 第 5~8 次读都翻转（同一扇区连坏 4 次，重读救不回）
//   N_READS     读多少个扇区（默认 8）
// 运行（仓库根目录）：
//   iverilog -g2005 -DMISO_DELAY=5 -DFAULT=0 -o sim/tb_sd.vvp sim/tb_sd_spi.v \
//       src/user_source/hdl_source/SD/sd_card_top.v src/user_source/hdl_source/SD/sd_card_sec_read_write.v \
//       src/user_source/hdl_source/SD/sd_card_cmd.v src/user_source/hdl_source/SD/spi_master.v && vvp -n sim/tb_sd.vvp
`ifndef MISO_DELAY
`define MISO_DELAY 5
`endif
`ifndef FAULT
`define FAULT 0
`endif
`ifndef N_READS
`define N_READS 8
`endif

module tb_sd_spi;

reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;          // 100MHz，与板上 sd_card_clk 一致

wire        sd_ncs, sd_dclk, sd_mosi, sd_miso;
wire        sd_init_done;
reg         sd_sec_read = 1'b0;
reg  [31:0] sd_sec_read_addr = 32'd0;
wire [7:0]  sd_sec_read_data;
wire        sd_sec_read_data_valid;
wire        sd_sec_read_end;
wire [1:0]  dbg_stage;
wire [7:0]  crc_err_cnt;
wire [7:0]  rd_retry_cnt;

sd_card_top dut (
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (sd_ncs),
    .SD_DCLK                (sd_dclk),
    .SD_MOSI                (sd_mosi),
    .SD_MISO                (sd_miso),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (8'd0),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       (),
    .dbg_stage              (dbg_stage),
    .crc_err_cnt            (crc_err_cnt),
    .rd_retry_cnt           (rd_retry_cnt)
);

sd_spi_card_model #(
    .MISO_DELAY (`MISO_DELAY),
    .FAULT      (`FAULT)
) card (
    .cs_n (sd_ncs),
    .sclk (sd_dclk),
    .mosi (sd_mosi),
    .miso (sd_miso)
);

// ---------------- 读扇区并逐字节比对 ----------------
integer n_bad_bytes = 0;
integer n_bytes = 0;
integer rd, k;
reg     hung = 1'b0;

always @(posedge clk) if (sd_sec_read_data_valid) begin
    if (sd_sec_read_data !== card.sector_byte(sd_sec_read_addr, n_bytes[8:0]))
        n_bad_bytes = n_bad_bytes + 1;
    n_bytes = n_bytes + 1;
end

initial begin
    #100 rst = 1'b0;
    wait (sd_init_done);
    $display("== MISO_DELAY=%0dns FAULT=%0d：初始化完成 t=%0.2f ms", `MISO_DELAY, `FAULT, $realtime / 1.0e6);
    for (rd = 1; rd <= `N_READS && !hung; rd = rd + 1) begin
        @(posedge clk);
        sd_sec_read_addr <= 32'd100 + rd;
        sd_sec_read      <= 1'b1;
        n_bytes = 0;
        // 等本扇区读完；单扇区正常约 0.25ms，给 300ms（超过等令牌超时 100ms 加重试）
        k = 0;
        while (!sd_sec_read_end && k < 30_000_000) begin @(posedge clk); k = k + 1; end
        sd_sec_read <= 1'b0;
        if (!sd_sec_read_end) begin
            hung = 1'b1;
            $display("  第 %0d 次读：卡死（SD 命令层阶段 %0d）", rd, dbg_stage);
        end else
            $display("  第 %0d 次读：收到 %0d 字节，累计错字节 %0d，CRC 错 %0d，重试 %0d",
                     rd, n_bytes, n_bad_bytes, crc_err_cnt, rd_retry_cnt);
        @(posedge clk);
    end
    $display("------------------------------------------------");
    $display("SUMMARY delay=%0d fault=%0d hung=%0d bad_bytes=%0d crc_err=%0d retry=%0d",
             `MISO_DELAY, `FAULT, hung, n_bad_bytes, crc_err_cnt, rd_retry_cnt);
    $finish;
end

// 全局看门狗：初始化或某次读卡死时也要结束
initial begin
    #(300_000_000);     // 300ms 仿真时间
    $display("SUMMARY delay=%0d fault=%0d hung=1 init_done=%0d bad_bytes=%0d crc_err=%0d retry=%0d （看门狗：卡死，SD 命令层阶段 %0d）",
             `MISO_DELAY, `FAULT, sd_init_done, n_bad_bytes, crc_err_cnt, rd_retry_cnt, dbg_stage);
    $finish;
end

endmodule

// =====================================================================
// 位级 SD 卡模型（SPI 模式，只实现初始化和 CMD17 单块读）
// =====================================================================
module sd_spi_card_model #(
    parameter integer MISO_DELAY = 5,
    parameter integer FAULT      = 0
)(
    input      cs_n,
    input      sclk,
    input      mosi,
    output reg miso
);

// 扇区内容：确定性伪随机，含 0xFE 等各种值
function [7:0] sector_byte;
    input [31:0] sec;
    input [8:0]  i;
    begin
        sector_byte = (sec * 8'd37) ^ (i * 8'd13) ^ (i >> 3) ^ 8'h5a;
    end
endfunction

function [15:0] crc16_byte;
    input [15:0] c;
    input [7:0]  d;
    integer b;
    reg [15:0] r;
    begin
        r = c;
        for (b = 7; b >= 0; b = b - 1)
            r = {r[14:0], 1'b0} ^ ((r[15] ^ d[b]) ? 16'h1021 : 16'h0000);
        crc16_byte = r;
    end
endfunction

// 发送字节队列
reg [7:0] txq [0:1023];
integer   q_head = 0, q_tail = 0;
task push(input [7:0] v);
    begin txq[q_tail] = v; q_tail = (q_tail + 1) % 1024; end
endtask

reg [47:0] rx;
integer    rx_bits = 0;            // CS 拉低以来收到的位数
integer    guard   = 0;            // 刚识别到命令后屏蔽一段，防止参数字节被误认成新命令
reg [7:0]  cur;
integer    bit_idx = 0;
integer    n_reads = 0;
integer    acmd41_cnt = 0;
reg [5:0]  cmd_idx;
reg [31:0] arg;
integer    i;
reg [15:0] crc;
reg [7:0]  dbyte;

initial miso = 1'b1;

always @(posedge cs_n) begin
    rx = {48{1'b1}};
    rx_bits = 0;
    guard = 0;
    bit_idx = 0;
end

// 上升沿采样 MOSI，按字节边界识别命令
always @(posedge sclk) if (!cs_n) begin
    rx = {rx[46:0], mosi};
    rx_bits = rx_bits + 1;
    if (guard > 0) guard = guard - 1;
    if ((rx_bits % 8) == 0 && guard == 0 && rx[47:46] == 2'b01 && rx[0] == 1'b1) begin
        cmd_idx = rx[45:40];
        arg     = rx[39:8];
        guard   = 48;
        push(8'hff);                                   // NCR = 1 字节
        case (cmd_idx)
            6'd0:  push(8'h01);
            6'd8:  begin push(8'h01); push(8'h00); push(8'h00); push(8'h01); push(8'haa); end
            6'd55: push(8'h01);
            6'd41: begin
                       acmd41_cnt = acmd41_cnt + 1;
                       push(acmd41_cnt < 3 ? 8'h01 : 8'h00);
                   end
            6'd16: push(8'h00);
            6'd17: begin
                       n_reads = n_reads + 1;
                       push(8'h00);
                       for (i = 0; i < 4; i = i + 1) push(8'hff);   // NAC
                       if (FAULT == 1 && n_reads == 3) begin
                           // 不发数据令牌（模拟令牌被漏收/卡没响应）
                       end else if (FAULT == 2 && n_reads == 4) begin
                           push(8'h08);                               // 数据错误令牌：地址越界
                       end else begin
                           push(8'hfe);
                           crc = 16'd0;
                           for (i = 0; i < 512; i = i + 1) begin
                               dbyte = sector_byte(arg, i);
                               crc   = crc16_byte(crc, dbyte);
                               if (((FAULT == 3 && n_reads == 5) || FAULT == 4 || (FAULT == 5 && n_reads >= 5 && n_reads <= 8)) && i == 100) dbyte = dbyte ^ 8'h10;
                               push(dbyte);
                           end
                           push(crc[15:8]);
                           push(crc[7:0]);
                       end
                   end
            default: push(8'h04);                          // 非法命令
        endcase
    end
end

// 下降沿移出 MISO（带延迟）
always @(negedge sclk) if (!cs_n) begin
    if (bit_idx == 0) begin
        if (q_head != q_tail) begin
            cur = txq[q_head];
            q_head = (q_head + 1) % 1024;
        end else
            cur = 8'hff;
    end
    miso <= #(MISO_DELAY) cur[7 - bit_idx];
    bit_idx = (bit_idx + 1) % 8;
end

endmodule
