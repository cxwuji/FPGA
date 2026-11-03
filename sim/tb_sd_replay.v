`timescale 1ns/1ps
// 扇区重放缓冲自检：真实 sd_card_top + sd_sector_adapter（重放缓冲）+ tb_sd_spi.v 里的位级 SD 卡模型。
// 检查：下游看到的字节逐个正确、按 0..511 顺序、每扇区 512 个、done 在最后一个字节之后。
// 运行（仓库根目录）：
//   iverilog -g2005 -DFAULT=3 -s tb_sd_replay -o sim/tb_replay.vvp sim/tb_sd_replay.v sim/tb_sd_spi.v \
//       src/user_source/hdl_source/SD/sd_sector_adapter.v src/user_source/hdl_source/SD/sd_card_top.v \
//       src/user_source/hdl_source/SD/sd_card_sec_read_write.v src/user_source/hdl_source/SD/sd_card_cmd.v \
//       src/user_source/hdl_source/SD/spi_master.v && vvp -n sim/tb_replay.vvp
//   FAULT：0 无故障 3 一次翻转（应被重读救回） 4 每次都翻转（8 个扇区后停止重读） 5 同一扇区连坏 4 次（救不回 1 个）
`ifndef MISO_DELAY
`define MISO_DELAY 15
`endif
`ifndef FAULT
`define FAULT 0
`endif
`ifndef N_READS
`define N_READS 12
`endif

module tb_sd_replay;
reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;

wire        sd_ncs, sd_dclk, sd_mosi, sd_miso;
wire        sd_init_done;
wire        sd_sec_read;
wire [31:0] sd_sec_read_addr;
wire [7:0]  sd_sec_read_data;
wire        sd_sec_read_data_valid, sd_sec_read_end, blk_crc_err;
wire [7:0]  crc_err_cnt, rd_retry_cnt;

sd_card_top dut (
    .clk(clk), .rst(rst), .SD_nCS(sd_ncs), .SD_DCLK(sd_dclk), .SD_MOSI(sd_mosi), .SD_MISO(sd_miso),
    .sd_init_done(sd_init_done), .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data), .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end), .sd_sec_write(1'b0), .sd_sec_write_addr(32'd0),
    .sd_sec_write_data(8'd0), .sd_sec_write_data_req(), .sd_sec_write_end(),
    .dbg_stage(), .crc_err_cnt(crc_err_cnt), .rd_retry_cnt(rd_retry_cnt), .blk_crc_err(blk_crc_err)
);

reg         sector_req = 1'b0;
reg  [31:0] sector_lba = 32'd0;
wire        sector_busy, sector_valid, sector_done;
wire [7:0]  sector_byte, sector_error;
wire [8:0]  sector_byte_index;
wire [7:0]  crc_retry_cnt, crc_fail_cnt;
wire        crc_trusted;

sd_sector_adapter u_adapter (
    .replay_hold            (1'b0),
    .clk(clk), .rst_n(~rst),
    .sector_req(sector_req), .sector_lba(sector_lba), .sector_busy(sector_busy),
    .sector_valid(sector_valid), .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
    .sector_done(sector_done), .sector_error(sector_error),
    .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data_valid(sd_sec_read_data_valid), .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_end(sd_sec_read_end), .sd_sec_read_crc_err(blk_crc_err),
    .crc_retry_cnt(crc_retry_cnt), .crc_fail_cnt(crc_fail_cnt), .crc_trusted(crc_trusted)
);

sd_spi_card_model #(.MISO_DELAY(`MISO_DELAY), .FAULT(`FAULT)) card (
    .cs_n(sd_ncs), .sclk(sd_dclk), .mosi(sd_mosi), .miso(sd_miso)
);

integer n_bad = 0, n_bytes = 0, n_order = 0, n_short = 0, n_err = 0, n_sec_bad = 0;
integer rd, k, bad_this;
reg     hung = 1'b0;
reg     seen_valid_before_done;

always @(posedge clk) begin
    if (sector_valid) begin
        if (sector_byte !== card.sector_byte(sector_lba, n_bytes[8:0])) begin n_bad = n_bad + 1; end
        if (sector_byte_index != n_bytes[8:0]) n_order = n_order + 1;
        n_bytes = n_bytes + 1;
        if (sector_done) n_order = n_order + 1;        // done 必须在最后一个字节之后
    end
    if (sector_error != 0) n_err = n_err + 1;
end

initial begin
    #100 rst = 1'b0;
    wait (sd_init_done);
    for (rd = 1; rd <= `N_READS && !hung; rd = rd + 1) begin
        @(posedge clk);
        sector_lba <= 32'd100 + rd;
        sector_req <= 1'b1;
        @(posedge clk);
        sector_req <= 1'b0;
        n_bytes = 0;
        bad_this = n_bad;
        k = 0;
        while (!sector_done && k < 30_000_000) begin @(posedge clk); k = k + 1; end
        if (!sector_done) begin hung = 1'b1; $display("  第 %0d 个扇区：卡死", rd); end
        else begin
            if (n_bytes != 512) n_short = n_short + 1;
            if (n_bad != bad_this) n_sec_bad = n_sec_bad + 1;
            $display("  第 %0d 个扇区：下游收到 %0d 字节，本扇区错字节 %0d；卡端 CRC 错 %0d，重读 %0d，救不回 %0d，CRC 可信 %0d",
                     rd, n_bytes, n_bad - bad_this, crc_err_cnt, crc_retry_cnt, crc_fail_cnt, crc_trusted);
        end
        @(posedge clk);
    end
    $display("SUMMARY fault=%0d hung=%0d bad_bytes=%0d bad_sectors=%0d order_err=%0d short=%0d sector_error=%0d crc_err=%0d retry=%0d fail=%0d trusted=%0d",
             `FAULT, hung, n_bad, n_sec_bad, n_order, n_short, n_err, crc_err_cnt, crc_retry_cnt, crc_fail_cnt, crc_trusted);
    $finish;
end

initial begin #(600_000_000); $display("SUMMARY fault=%0d hung=1 （看门狗）", `FAULT); $finish; end
endmodule
