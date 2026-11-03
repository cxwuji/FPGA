`timescale 1ns/1ps
// 音频链路自检：hdmi_audio_tone_i2s_64fs -> I2S_receiver -> audio_arc_calculate
// 时钟按板上实际值：audio_mclk = 750MHz/61 = 12.295082MHz，video_clk = 25MHz
module tb_audio_chain;

// 缩短每个音符时长以便在短仿真里看到换音（板上默认 24000 帧 = 0.5s）
localparam integer NOTE_FRAMES = 2400;    // 50ms
localparam real    MCLK_HALF   = 40.667;  // ns
localparam real    VCLK_HALF   = 20.0;    // ns

reg audio_mclk = 1'b0;
reg video_clk  = 1'b0;
reg rst        = 1'b1;
always #(MCLK_HALF) audio_mclk = ~audio_mclk;
always #(VCLK_HALF) video_clk  = ~video_clk;

wire        bclk, lrck, dout;
wire        audio_valid;
wire [23:0] left, right;
wire        acr_valid;
wire [19:0] acr_cts, acr_n;

hdmi_audio_tone_i2s_64fs #(
    .PHASE_INC        (32'd39370534),
    .AMP              (24'sd2000000),
    .NOTE_HOLD_FRAMES (NOTE_FRAMES)
) u_tone (
    .I_mclk     (audio_mclk),
    .I_rst      (rst),
    .O_i2s_BCLK (bclk),
    .O_i2s_LRCK (lrck),
    .O_i2s_DOUT (dout)
);

I2S_receiver u_rx (
    .I_clk              (video_clk),
    .I_rst              (rst),
    .I_i2s_BCLK         (bclk),
    .I_i2s_LRCK         (lrck),
    .I_i2s_DOUT         (dout),
    .O_audio_valid      (audio_valid),
    .O_audio_left_data  (left),
    .O_audio_right_data (right)
);

audio_arc_calculate #(.ACR_N(6144)) u_acr (
    .I_clk         (video_clk),
    .I_rst         (rst),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ---------------- 统计 ----------------
integer n_valid = 0, n_lr_mismatch = 0, n_bad_amp = 0, n_zero = 0;
integer n_acr = 0, cts_min = 1 << 30, cts_max = 0, n_bad_n = 0;
real    t_first = 0.0, t_last = 0.0;
// 每个音符窗口里统计正负翻转次数，换算方波频率
integer flips = 0, note_win = 0, note_errs = 0;
reg     last_sign = 1'b0;
reg     have_last = 1'b0;
real    expect_hz [0:7];
real    fs_meas, f_meas, err;
integer i;

initial begin
    expect_hz[0] = 261.63; expect_hz[1] = 293.66; expect_hz[2] = 329.63; expect_hz[3] = 349.23;
    expect_hz[4] = 392.00; expect_hz[5] = 440.00; expect_hz[6] = 493.88; expect_hz[7] = 523.25;
end

always @(posedge video_clk) if (!rst && audio_valid) begin
    if (n_valid == 0) t_first = $realtime;
    t_last  = $realtime;
    n_valid = n_valid + 1;
    if (left !== right)                                         n_lr_mismatch = n_lr_mismatch + 1;
    if (left == 24'd0)                                          n_zero = n_zero + 1;
    else if (left !== 24'd2000000 && left !== (-24'sd2000000))  n_bad_amp = n_bad_amp + 1;
    if (left != 24'd0) begin
        if (have_last && (left[23] != last_sign)) flips = flips + 1;
        last_sign = left[23];
        have_last = 1'b1;
    end
end

always @(posedge video_clk) if (!rst && acr_valid) begin
    n_acr = n_acr + 1;
    if (n_acr > 2) begin  // 前两个 CTS 包含复位后的不完整计数，跳过
        if (acr_cts < cts_min) cts_min = acr_cts;
        if (acr_cts > cts_max) cts_max = acr_cts;
    end
    if (acr_n != 20'd6144) n_bad_n = n_bad_n + 1;
end

// 发送端每帧边界：按音符窗口检查频率（跳过第一个窗口里的启动过程）
always @(posedge audio_mclk) if (!rst && u_tone.O_i2s_BCLK && u_tone.S_bit_cnt == 6'd63 && u_tone.O_i2s_LRCK
                                  && u_tone.S_note_frame_cnt == NOTE_FRAMES - 1) begin
    if (note_win > 0) begin
        // 方波每周期 2 次翻转；窗口长 NOTE_FRAMES/fs 秒
        f_meas = flips / 2.0 / (NOTE_FRAMES / 48028.0);
        err    = (f_meas - expect_hz[u_tone.S_note_idx]) / expect_hz[u_tone.S_note_idx];
        $display("  音符 %0d：期望 %7.2f Hz，实测 %7.2f Hz（误差 %+5.1f%%）",
                 u_tone.S_note_idx, expect_hz[u_tone.S_note_idx], f_meas, err * 100.0);
        if (err > 0.03 || err < -0.03) note_errs = note_errs + 1;
    end
    note_win = note_win + 1;
    flips    = 0;
end

initial begin
    #1000 rst = 1'b0;
    // 跑满 8 个音符 + 1 个启动窗口
    wait (note_win == 9);
    fs_meas = (n_valid - 1) / ((t_last - t_first) * 1.0e-9);
    $display("------------------------------------------------");
    $display("采样数 %0d，实测采样率 %.1f Hz（理论 12295082/256 = 48027.7 Hz）", n_valid, fs_meas);
    $display("左右声道不一致 %0d 次，非法幅值 %0d 次，零样本 %0d 次", n_lr_mismatch, n_bad_amp, n_zero);
    $display("ACR 包 %0d 个，CTS 范围 %0d..%0d（理论 25e6*48/48027.7 = 24985.6），N 错误 %0d 次",
             n_acr, cts_min, cts_max, n_bad_n);
    $display("音高超差（>3%%）%0d 个", note_errs);
    if (fs_meas > 47980.0 && fs_meas < 48076.0 && n_lr_mismatch == 0 && n_bad_amp == 0 && n_zero <= 1 &&
        cts_min >= 24980 && cts_max <= 24992 && n_bad_n == 0 && note_errs == 0 && note_win == 9)
        $display("RESULT: PASS");
    else
        $display("RESULT: FAIL");
    $finish;
end

endmodule
