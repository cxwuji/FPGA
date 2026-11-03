`timescale 1ns/1ps
// R12d：HDMI 音频时钟再生包（ACR）字节检查。HDMI 1.4b 5.3.3：HB0 = 0x01，HB1 = HB2 = 0；
//   每个子包 SB0 = 0，SB1 = CTS[19:16]，SB2 = CTS[15:8]，SB3 = CTS[7:0]，SB4 = N[19:16]，SB5 = N[15:8]，SB6 = N[7:0]，4 个子包相同。
//   本工程约定低字节 = SB0 / HB0（和音频采样包、InfoFrame 一致）。N = 6144、CTS = 25000：25 MHz × 6144 / (128 × 25000) = 48 kHz。
//   另检查约每 INTERVAL_CYCLES 拍发一个包（计数在等握手时停住，所以间隔 = INTERVAL + 握手的几拍）。
// 运行（仓库根目录）：bash sim/run_acr.sh
module tb_acr;
reg clk = 1'b0; always #20 clk = ~clk;
reg rst_n = 1'b0;
reg ready = 1'b0;
wire        valid;
wire [23:0] hdr; wire [7:0] hecc; wire [223:0] body; wire [31:0] becc;
hdmi_audio_acr_packetizer #(.INTERVAL_CYCLES(100)) dut (
    .clk(clk), .rst_n(rst_n), .packet_valid(valid), .packet_ready(ready),
    .packet_header(hdr), .packet_header_ecc(hecc), .packet_body(body), .packet_body_ecc(becc)
);
integer errors = 0, k, n_pkt = 0, t_last = -1, gap = 0;
reg [7:0] want [0:6];
reg [19:0] n_rx, cts_rx;
task check(input ok, input [1023:0] what);
    begin if (ok) $display("  ok   %0s", what); else begin $display("  FAIL %0s", what); errors = errors + 1; end end
endtask
always @(posedge clk) begin
    ready <= valid && !ready;
    if (valid && ready) begin
        n_pkt = n_pkt + 1;
        if (t_last >= 0) gap = ($time - t_last) / 40;
        t_last = $time;
    end
end
initial begin
    want[0] = 8'h00; want[1] = 8'h00; want[2] = 8'h61; want[3] = 8'ha8;     // CTS = 25000 = 0x061A8
    want[4] = 8'h00; want[5] = 8'h18; want[6] = 8'h00;                      // N   = 6144  = 0x01800
    #100 rst_n = 1'b1;
    #1;
    check(hdr[7:0] == 8'h01 && hdr[15:8] == 8'h00 && hdr[23:16] == 8'h00, "HB0 = 0x01 (ACR), HB1 = HB2 = 0");
    for (k = 0; k < 7; k = k + 1)
        if (body[k*8 +: 8] !== want[k]) begin
            $display("    SB%0d = %h，应为 %h", k, body[k*8 +: 8], want[k]);
            errors = errors + 1;
        end
    check(body[55:0] == {want[6], want[5], want[4], want[3], want[2], want[1], want[0]},
          "subpacket SB0..SB6 = 00 00 61 A8 00 18 00 (HDMI 1.4b order)");
    check(body[111:56] == body[55:0] && body[167:112] == body[55:0] && body[223:168] == body[55:0], "4 subpackets identical");
    cts_rx = {body[11:8], body[23:16], body[31:24]};
    n_rx   = {body[35:32], body[47:40], body[55:48]};
    check(cts_rx == 20'd25000 && n_rx == 20'd6144, "sink decodes CTS = 25000, N = 6144 -> fs = 25 MHz * N / (128 * CTS) = 48 kHz");
    repeat (1000) @(posedge clk);
    check(n_pkt >= 9 && gap >= 100 && gap <= 104, "one packet every ~INTERVAL_CYCLES (100) clocks");
    $display("       （%0d 个包，间隔 %0d 拍）", n_pkt, gap);
    $display("RESULT: %0s（%0d 个失败）", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
end
endmodule
