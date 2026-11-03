`timescale 1ns/1ps
// R7c-1 提示音自检：cue_tone_gen 单独测。节拍音 1 kHz / 60 ms、按键音 2 kHz / 25 ms / 1/4 幅度、斜坡起收、饱和混音、重触发。
// R12：吹气音（blow_level 电平，吹多久响多久，松开 5 ms 收音）W1~W5。
// 运行（仓库根目录）：bash sim/run_cue_tone.sh
module tb_cue_tone;
reg sd_clk = 0;  always #5  sd_clk  = ~sd_clk;     // 100 MHz
reg pix_clk = 0; always #20 pix_clk = ~pix_clk;    // 25 MHz
reg rst_n = 0;
reg beat = 0, key = 0, blow = 0;
reg signed [15:0] mix_in = 0;

reg [24:0] acc = 0;
wire tick = (acc >= 25'd25_000_000 - 25'd48_000);
always @(posedge pix_clk) acc <= tick ? acc + 25'd48_000 - 25'd25_000_000 : acc + 25'd48_000;

wire signed [15:0] mix_out, cue;
wire beat_on, key_on;
cue_tone_gen dut (
    .src_clk(sd_clk), .src_rst_n(rst_n), .beat_pulse(beat), .key_pulse(key), .blow_level(blow),
    .clk(pix_clk), .rst_n(rst_n), .sample_tick(tick), .mix_in(mix_in), .mix_out(mix_out),
    .cue_sample(cue), .beat_on(beat_on), .key_on(key_on)
);

integer errors = 0;
task check(input ok, input [1023:0] what);
    begin
        if (ok) $display("  ok   %0s", what);
        else begin $display("  FAIL %0s", what); errors = errors + 1; end
    end
endtask
task pulse_beat; begin @(posedge sd_clk) beat = 1; @(posedge sd_clk) beat = 0; end endtask
task pulse_key;  begin @(posedge sd_clk) key = 1;  @(posedge sd_clk) key = 0;  end endtask

// 每个样点统计：非零样点数、峰值、过零次数、开头 / 结尾 5 ms 内的最大值
integer n_nz, peak, n_zc, first_nz, last_nz, idx, head_max, tail_max;
reg signed [15:0] prev;
reg counting = 0;
always @(posedge pix_clk) if (tick && counting) begin
    idx = idx + 1;
    if (cue != 0) begin
        n_nz = n_nz + 1;
        if (first_nz < 0) first_nz = idx;
        last_nz = idx;
        if ((cue < 0 ? -cue : cue) > peak) peak = (cue < 0 ? -cue : cue);
        if (prev != 0 && (prev < 0) != (cue < 0)) n_zc = n_zc + 1;
        prev = cue;
    end
end
task measure_start; begin n_nz = 0; peak = 0; n_zc = 0; first_nz = -1; last_nz = -1; idx = 0; prev = 0; counting = 1; end endtask
task wait_samples(input integer n); begin repeat (n) @(posedge tick); @(posedge pix_clk); end endtask

integer i, s0, m;
initial begin
    #200 rst_n = 1;
    wait_samples(10);

    // ---- 节拍音 ----
    measure_start; pulse_beat; wait_samples(3200); counting = 0;
    $display("  节拍音：非零 %0d 样点，峰值 %0d，过零 %0d 次", n_nz, peak, n_zc);
    check(n_nz >= 2840 && n_nz <= 2880, "B1 beat lasts 60 ms (2880 samples, first / last 16 at envelope 0)");
    check(n_zc >= 116 && n_zc <= 122, "B2 beat is 1 kHz (about 120 zero crossings in 60 ms)");
    check(peak >= 14000 && peak <= 16384, "B3 beat peak about half scale");
    check(!beat_on, "B4 beat finished");

    // 斜坡：开头 5 ms 内的样点幅度逐渐增大
    measure_start; pulse_beat;
    head_max = 0;
    for (i = 0; i < 60; i = i + 1) begin
        @(posedge tick); @(posedge pix_clk);
        if (i < 40 && (cue < 0 ? -cue : cue) > head_max) head_max = (cue < 0 ? -cue : cue);
    end
    check(head_max < 4000, "B5 attack ramp: first 40 samples below 1/4 of peak (no click)");
    wait_samples(3000); counting = 0;

    // ---- 按键音 ----
    measure_start; pulse_key; wait_samples(1400); counting = 0;
    $display("  按键音：非零 %0d 样点，峰值 %0d，过零 %0d 次", n_nz, peak, n_zc);
    check(n_nz >= 1160 && n_nz <= 1200, "K1 key click lasts 25 ms (1200 samples)");
    check(n_zc >= 96 && n_zc <= 102, "K2 key click is 2 kHz (about 100 zero crossings in 25 ms)");
    check(peak >= 3500 && peak <= 4100, "K3 key click peak = 1/4 of beat");

    // ---- 重触发：响到一半再触发 = 从头再响 ----
    measure_start; pulse_beat; wait_samples(1000); pulse_beat; wait_samples(3200); counting = 0;
    check(n_nz >= 1000 + 2830 && n_nz <= 1000 + 2880, "R1 retrigger restarts the beat");

    // ---- R12 吹气音：blow 电平 1 秒（48000 样点）----
    wait_samples(3200);
    measure_start; blow = 1; wait_samples(48000); blow = 0; wait_samples(600); counting = 0;
    $display("  吹气音：非零 %0d 样点，峰值 %0d，过零 %0d 次", n_nz, peak, n_zc);
    check(n_nz >= 47800 && n_nz <= 48500, "W1 blow tone lasts as long as blow_level (1 s) + 5 ms release");
    check(peak >= 14000 && peak <= 16384, "W2 blow tone peak about half scale (same as beat)");
    check(n_zc >= 1990 && n_zc <= 2010, "W3 blow tone is 1 kHz (about 2000 zero crossings in 1 s)");
    check(!beat_on, "W4 blow tone stops after release");
    measure_start; wait_samples(2000); counting = 0;
    check(n_nz == 0, "W5 silent after release (no stuck tone)");

    // ---- 同时响 + 饱和混音 ----
    mix_in = 16'sd30000;
    pulse_beat; pulse_key;
    m = 0;
    for (i = 0; i < 2000; i = i + 1) begin
        @(posedge tick); @(posedge pix_clk);
        if (mix_out > m) m = mix_out;
        if (mix_out < 16'sd30000 - 16'sd20000) m = -1;           // 不应出现回绕到负数
    end
    check(m == 32767, "S1 mix saturates at +32767 (no wrap-around)");
    mix_in = -16'sd30000;
    wait_samples(3000);
    pulse_beat;
    m = 0;
    for (i = 0; i < 2000; i = i + 1) begin
        @(posedge tick); @(posedge pix_clk);
        if (mix_out < m) m = mix_out;
    end
    check(m == -32768, "S2 mix saturates at -32768");
    mix_in = 16'sd1234;
    wait_samples(3000);
    check(mix_out == 16'sd1234, "S3 silent cue -> mix_out = mix_in");

    $display("RESULT: %0s（%0d 个失败）", (errors == 0) ? "PASS" : "FAIL", errors);
    $finish;
end
initial begin repeat (3) #1_000_000_000; $display("RESULT: FAIL（超时）"); $finish; end
endmodule
