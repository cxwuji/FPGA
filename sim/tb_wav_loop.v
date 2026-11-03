`timescale 1ns/1ps
// R1.5a WAV 循环 + 暂停自检：wav_stream_player（LOOP=1）+ 假 SD 扇区源。
// 扇区 L 的第 k 个样本 = {L[7:0], k[7:0]}；3 个扇区循环，检查：
//   P0 首轮按 LBA 100,101,102 顺序连续输出；P1 读完最后一扇区无缝回到 100（不进 END）；
//   P2 pause=1 期间只出 0、不消耗；P3 pause 撤销后从暂停前的下一个样本接着放。
// 运行（仓库根目录）：bash sim/run_wav_loop.sh
module tb_wav_loop;
reg wr_clk = 0; always #5  wr_clk = ~wr_clk;     // 100MHz
reg rd_clk = 0; always #20 rd_clk = ~rd_clk;     // 25MHz
reg rst_n = 0;
reg pause = 0;

wire        sd_req;
wire [31:0] sd_lba;
reg         sd_busy = 0, sd_valid = 0, sd_done = 0;
reg  [7:0]  sd_byte = 0;
reg  [8:0]  sd_idx = 0;

// 每 20 个 rd_clk 一个样本节拍（仿真加速）
reg [4:0] tdiv = 0;
wire tick = (tdiv == 5'd19);
always @(posedge rd_clk) tdiv <= tick ? 5'd0 : tdiv + 5'd1;

wire signed [15:0] s;
wire sv, active, ended;
wav_stream_player #(.ADDR_WIDTH(10), .SAMPLES_PER_SECTOR(256), .LOOP(1'b1)) dut (
    .wr_clk(wr_clk), .wr_rst_n(rst_n), .play_enable(1'b1), .loop_en(1'b1), .start_lba(32'd100), .total_sectors(32'd3),
    .sd_req(sd_req), .sd_lba(sd_lba), .sd_busy(sd_busy), .sd_valid(sd_valid), .sd_byte(sd_byte),
    .sd_byte_index(sd_idx), .sd_done(sd_done), .sd_error(8'd0),
    .rd_clk(rd_clk), .rd_rst_n(rst_n), .sample_tick(tick), .sample_out(s), .sample_valid(sv),
    .sample_ready(1'b1), .pause(pause),
    .sample_counter(), .stream_active(active), .stream_end(ended), .buffer_low()
);

// 假 SD：看到 sd_req 就忙，按字节送 512 个，最后一拍 sd_done
integer i;
reg [31:0] lba_l;
initial begin
    wait (rst_n);
    forever begin
        @(posedge wr_clk);
        if (sd_req && !sd_busy) begin
            sd_busy <= 1; @(posedge wr_clk); lba_l = sd_lba;
            for (i = 0; i < 512; i = i + 1) begin
                @(posedge wr_clk);
                sd_valid <= 1; sd_idx <= i;
                sd_byte <= (i[0] == 0) ? i[8:1] : lba_l[7:0];
                @(posedge wr_clk); sd_valid <= 0;
            end
            @(posedge wr_clk); sd_done <= 1;
            @(posedge wr_clk); sd_done <= 0; sd_busy <= 0;
        end
    end
end

integer errors = 0, n = 0, zeros_in_pause = 0, bad_pause = 0, underflow = 0;
reg [15:0] expect;
reg started = 0;
reg [15:0] last;
always @(posedge rd_clk) if (sv) begin
    if (pause) begin
        if (s !== 16'sd0) bad_pause = bad_pause + 1; else zeros_in_pause = zeros_in_pause + 1;
    end else if (!started) begin
        if (s !== 0) begin
            started = 1;
            if (s !== 16'h6400) begin $display("  FAIL first sample %h", s); errors = errors + 1; end
            expect = 16'h6401; n = 1;
        end
    end else if (s === 16'sd0) begin
        underflow = underflow + 1;                     // 欠载静音：不消耗，不算序列
    end else begin
        if (s !== expect) begin
            if (errors < 5) $display("  FAIL sample #%0d = %h, expect %h", n, s, expect);
            errors = errors + 1;
        end
        n = n + 1;
        expect = (expect[7:0] == 8'hff) ? ((expect[15:8] == 8'd102) ? 16'h6400 : {expect[15:8] + 8'd1, 8'h00})
                                        : expect + 16'd1;
    end
end

initial begin
    #200 rst_n = 1;
    wait (n >= 1000);                                  // 3 扇区 = 768 样本：已经回绕过一次
    $display("  ok   P0/P1 %0d samples in order, wrapped 102 -> 100, ended=%0d", n, ended);
    if (ended) errors = errors + 1;
    @(posedge rd_clk); pause = 1;
    repeat (40 * 600) @(posedge rd_clk);               // 暂停约 1200 个节拍（超过缓冲深度，写侧必须停下）
    @(posedge rd_clk); pause = 0;
    wait (n >= 3000);
    if (bad_pause == 0 && zeros_in_pause > 1000) $display("  ok   P2 pause: %0d silent samples, nothing consumed", zeros_in_pause);
    else begin $display("  FAIL P2 pause bad=%0d zeros=%0d", bad_pause, zeros_in_pause); errors = errors + 1; end
    if (underflow == 0) $display("  ok   P4 no underflow after start (pointer wrap handled)");
    else begin $display("  FAIL P4 %0d underflow samples after start", underflow); errors = errors + 1; end
    if (errors == 0) $display("  ok   P3 resume continues from next sample (sequence unbroken across pause)");
    $display("RESULT: %0s（%0d 个失败）", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
end
initial begin #50_000_000; $display("RESULT: FAIL（超时） n=%0d", n); $finish; end
endmodule
