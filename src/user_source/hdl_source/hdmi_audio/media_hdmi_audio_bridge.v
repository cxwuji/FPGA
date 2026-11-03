`timescale 1ns/1ps

// Player-owned boundary between the registered video bundle and the verified
// Route B HDMI packet/symbol chain. The EG4 DDR PHY remains in the board Top so
// this bridge can be exercised in ordinary RTL simulation without vendor pads.
// media_id drives the per-image tone selection and volume scales the output,
// turning the tone source into the audio half of the AV-linked feature.
module media_hdmi_audio_bridge (
    input  wire        pixel_clk,
    input  wire        pixel_rst_n,
    input  wire        video_hsync,
    input  wire        video_vsync,
    input  wire        video_de,
    input  wire [9:0]  video_x,
    input  wire [23:0] video_rgb,
    input  wire [1:0]  media_id,
    input  wire [7:0]  volume,
    // 第11课：WAV 流（同一 pixel_clk 域，每个 48kHz 节拍一个 sample_valid 脉冲）
    input  wire        wav_valid,
    input  wire signed [15:0] wav_sample,
    input  wire        wav_active,
    input  wire [7:0]  fade_gain,       // sync_fade_gain：图像淡出时声音同步变小
    // R7c-1 提示音（节拍音 / 按键音）：src_clk 域单拍，cue_tone_gen 里过域；固定音量，最后一级饱和混入
    input  wire        cue_src_clk,
    input  wire        cue_src_rst_n,
    input  wire        beat_pulse,
    input  wire        key_pulse,
    input  wire        blow_level,      // R12：人工呼吸吹气（src_clk 域电平），吹多久响多久
    input  wire        sample_tick,     // 48 kHz
    output wire [9:0]  channel0_symbol,
    output wire [9:0]  channel1_symbol,
    output wire [9:0]  channel2_symbol,
    output wire        sequence_error,
    output wire        tone_overflow,
    output wire        pcm_contract_error,
    output wire        blip_active,
    output wire        pcm_tap_valid,
    output wire signed [15:0] pcm_tap_left
);
    wire source_valid;
    wire source_ready;
    wire signed [15:0] source_left;
    wire signed [15:0] source_right;
    wire sample_valid;
    wire sample_ready;
    wire signed [15:0] sample_left;
    wire signed [15:0] sample_right;

    reg video_hsync_q;
    reg video_vsync_q;
    reg video_de_q;
    reg [9:0] video_x_q;
    reg [23:0] video_rgb_q;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            video_hsync_q <= 1'b1;
            video_vsync_q <= 1'b1;
            video_de_q <= 1'b0;
            video_x_q <= 10'd0;
            video_rgb_q <= 24'h000000;
        end else begin
            video_hsync_q <= video_hsync;
            video_vsync_q <= video_vsync;
            video_de_q <= video_de;
            video_x_q <= video_x;
            video_rgb_q <= video_de ? video_rgb : 24'h000000;
        end
    end

    // R8-0a：没有 WAV 时的替补音源由琶音（pcm_media_tone）改为静音：每个 48kHz 节拍给一个 0 样本，
    //   保证 HDMI 音频包和提示音（节拍音 / 按键音）照常有样本流；下游忙时最多攒 1 个（静音丢样本听不出来）
    reg silence_valid;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n)
            silence_valid <= 1'b0;
        else if (sample_tick)
            silence_valid <= 1'b1;
        else if (source_ready)
            silence_valid <= 1'b0;
    end
    assign source_valid = silence_valid;
    assign source_left  = 16'sd0;
    assign source_right = 16'sd0;
    assign tone_overflow = 1'b0;
    assign blip_active   = 1'b0;

    // ---- 第11课：WAV 小 FIFO ----
    // wav_stream_player 只在 48kHz 节拍上给一个 valid 脉冲、不等 ready；音频封包器攒满 4 个样本后
    // 要等数据岛把包送走才收下一个（sample_ready 会低一段时间），所以先进 8 深 FIFO，避免丢样本
    reg signed [15:0] wav_fifo [0:7];
    reg [2:0] wav_wp, wav_rp;
    reg [3:0] wav_cnt;
    wire wav_fifo_valid = (wav_cnt != 0);
    wire wav_fifo_ready;
    wire wav_pop  = wav_fifo_valid && wav_fifo_ready;
    wire wav_push = wav_valid && (wav_cnt != 4'd8 || wav_pop);
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            wav_wp <= 3'd0; wav_rp <= 3'd0; wav_cnt <= 4'd0;
        end else begin
            if (wav_push) begin
                wav_fifo[wav_wp] <= wav_sample;
                wav_wp <= wav_wp + 1'b1;
            end
            if (wav_pop)
                wav_rp <= wav_rp + 1'b1;
            case ({wav_push, wav_pop})
                2'b10: wav_cnt <= wav_cnt + 1'b1;
                2'b01: wav_cnt <= wav_cnt - 1'b1;
                default: wav_cnt <= wav_cnt;
            endcase
        end
    end

    // ---- 第11课：音源选择（WAV 优先，没有 WAV 或播完回到静音） ----
    wire mux_valid;
    wire mux_ready;
    wire signed [15:0] mux_left;
    wire signed [15:0] mux_right;
    audio_source_mux u_audio_source_mux (
        .clk(pixel_clk), .rst_n(pixel_rst_n),
        .wav_valid(wav_fifo_valid), .wav_ready(wav_fifo_ready),
        .wav_left(wav_fifo[wav_rp]), .wav_right(wav_fifo[wav_rp]),
        .wav_active(wav_active),
        .arp_valid(source_valid), .arp_ready(source_ready),
        .arp_left(source_left), .arp_right(source_right),
        .force_arpeggio(1'b0),
        .out_valid(mux_valid), .out_ready(mux_ready),
        .out_left(mux_left), .out_right(mux_right)
    );

    // ---- 第11课：转场增益（gain=255 时为 255/256，听不出差别） ----
    // R1.5a：WAV 乘音量（R8-0a 起替补音源是静音，乘不乘都一样）；合成增益寄存一拍，两个增益都是慢变量
    reg  [7:0]  total_gain;
    wire [15:0] fade_x_vol = fade_gain * volume;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) total_gain <= 8'd0;
        else              total_gain <= wav_active ? fade_x_vol[15:8] : fade_gain;
    end
    wire signed [24:0] gain_left  = mux_left  * $signed({1'b0, total_gain});
    wire signed [24:0] gain_right = mux_right * $signed({1'b0, total_gain});
    wire signed [15:0] faded_left  = gain_left[23:8];
    wire signed [15:0] faded_right = gain_right[23:8];

    wire signed [15:0] mixed_left, mixed_right;
    cue_tone_gen u_cue (
        .src_clk(cue_src_clk), .src_rst_n(cue_src_rst_n), .beat_pulse(beat_pulse), .key_pulse(key_pulse),
        .blow_level(blow_level),
        .clk(pixel_clk), .rst_n(pixel_rst_n), .sample_tick(sample_tick),
        .mix_in(faded_left), .mix_out(mixed_left), .cue_sample(), .beat_on(), .key_on()
    );
    assign mixed_right = mixed_left;        // 单声道素材，左右相同（右声道原来也是同一个样本）

    m06_pcm_contract_adapter u_m06_pcm_contract (
        .clk(pixel_clk), .rst_n(pixel_rst_n),
        .source_valid(mux_valid), .source_ready(mux_ready),
        .source_left(mixed_left), .source_right(mixed_right),
        .pcm_valid(sample_valid), .pcm_ready(sample_ready),
        .pcm_left(sample_left), .pcm_right(sample_right),
        .contract_error(pcm_contract_error)
    );

    hdmi_audio_symbol_core u_symbol_core (
        .pixel_clk(pixel_clk), .rst_n(pixel_rst_n),
        .video_hsync(video_hsync_q), .video_vsync(video_vsync_q),
        .video_de(video_de_q), .video_x(video_x_q), .video_rgb(video_rgb_q),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .sample_left(sample_left), .sample_right(sample_right),
        .channel0_symbol(channel0_symbol),
        .channel1_symbol(channel1_symbol),
        .channel2_symbol(channel2_symbol),
        .sequence_error(sequence_error)
    );

    assign pcm_tap_valid = sample_valid && sample_ready;
    assign pcm_tap_left = sample_left;
endmodule
