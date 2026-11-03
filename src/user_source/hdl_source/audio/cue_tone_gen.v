`timescale 1ns/1ps

// R7c-1 提示音（video_clk 域，音频链时钟）：急救节拍音 + 按键音，硬件现场合成，不依赖 TF 卡。
//   节拍音：1 kHz 三角波，60 ms，起 / 收各 5 ms 线性斜坡，峰值约半满幅
//   按键音：2 kHz 三角波，25 ms，幅度为节拍音的 1/4（不加包络：从三角波过零点开始，25 ms 正好 50 个周期，结束也在零点）
// 触发：beat_pulse / key_pulse 是 src_clk（sd_card_clk）域单拍，内部 toggle + 2FF 过域；正在响时再触发 = 从头再响。
// 输出：mix_out = 饱和(mix_in + 节拍音 + 按键音)，接在 HDMI 音频链最后一级（固定音量，不受 SW4 / 菜单音量影响）。
// R12 吹气音：blow_level（src_clk 域电平，= 人工呼吸吹气那 1 秒的 LED）为高时节拍音一直响（起音 5 ms 斜坡后满包络），
//   拉低后 5 ms 收音。用节拍音同一套相位 / 包络，只是按住时把剩余计数顶在 255。
// 只用加法 / 移位（节拍音包络 16 级 = 上升 / 下降计数器的高 4 位，按位移位相加），不占 DSP。
module cue_tone_gen #(
    parameter integer SAMPLE_HZ  = 48000,
    parameter integer BEAT_HZ    = 1000,
    parameter integer KEY_HZ     = 2000,
    parameter integer BEAT_MS    = 60,
    parameter integer KEY_MS     = 25,
    parameter integer RAMP_MS    = 5      // 只作说明：起 / 收斜坡固定 = 16 级 × 16 样点（48 kHz 时 5 ms），由计数器高 4 位决定
) (
    input  wire               src_clk,
    input  wire               src_rst_n,
    input  wire               beat_pulse,
    input  wire               key_pulse,
    input  wire               blow_level,        // R12：人工呼吸吹气（电平）

    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,       // 48 kHz 单拍
    input  wire signed [15:0] mix_in,
    output wire signed [15:0] mix_out,
    output wire signed [15:0] cue_sample,        // 只有提示音（仿真 / 调试用）
    output wire               beat_on,
    output wire               key_on
);
    localparam [15:0] BEAT_INC = (65536 * BEAT_HZ) / SAMPLE_HZ;
    localparam [15:0] KEY_INC  = (65536 * KEY_HZ) / SAMPLE_HZ;
    localparam integer BEAT_N  = SAMPLE_HZ / 1000 * BEAT_MS;
    localparam integer KEY_N   = SAMPLE_HZ / 1000 * KEY_MS;
    // 包络：起音 = 上升计数 b_up 的 [7:4]（每 16 个样点升 1 级，240 个样点 = 5 ms 到 15），收音 = 剩余计数 b_left 的 [7:4]

    // ---------------- 过域 ----------------
    reg bt_src, kt_src;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            bt_src <= 1'b0;  kt_src <= 1'b0;
        end else begin
            if (beat_pulse) bt_src <= ~bt_src;
            if (key_pulse)  kt_src <= ~kt_src;
        end
    end
    reg [2:0] bt_s, kt_s;
    reg [1:0] bl_s;
    reg       bt_req, kt_req;          // 等下一个采样节拍再开始
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bt_s <= 3'd0;  kt_s <= 3'd0;  bl_s <= 2'd0;  bt_req <= 1'b0;  kt_req <= 1'b0;
        end else begin
            bt_s <= {bt_s[1:0], bt_src};
            kt_s <= {kt_s[1:0], kt_src};
            bl_s <= {bl_s[0], blow_level};
            if (bt_s[2] ^ bt_s[1]) bt_req <= 1'b1; else if (sample_tick) bt_req <= 1'b0;
            if (kt_s[2] ^ kt_s[1]) kt_req <= 1'b1; else if (sample_tick) kt_req <= 1'b0;
        end
    end

    // ---------------- 两个音：相位 + 包络 ----------------
    function signed [15:0] tri_wave;          // 相位 -> 三角波 -16384 ~ +16383
        input [15:0] ph;
        reg [14:0] t;
        begin
            t   = ph[15] ? ~ph[14:0] : ph[14:0];
            tri_wave = $signed({1'b0, t}) - 16'sd16384;
        end
    endfunction
    function signed [15:0] scale16;      // x × env / 16（env 0~15，移位相加）
        input signed [15:0] x;
        input [3:0] env;
        reg signed [19:0] acc;
        begin
            acc = (env[3] ? {{4{x[15]}}, x} <<< 3 : 20'sd0) + (env[2] ? {{4{x[15]}}, x} <<< 2 : 20'sd0) +
                  (env[1] ? {{4{x[15]}}, x} <<< 1 : 20'sd0) + (env[0] ? {{4{x[15]}}, x} : 20'sd0);
            scale16 = acc[19:4];
        end
    endfunction

    reg [15:0] b_ph, k_ph;
    reg [12:0] b_left, k_left;        // 还剩几个样点
    reg [7:0]  b_up;                  // 起音计数（满 255 停）
    reg        b_on, k_on;
    reg [3:0]  b_env;
    reg signed [15:0] b_smp, k_smp, cue;
    assign beat_on = b_on;
    assign key_on  = k_on;
    assign cue_sample = cue;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_ph <= 16'd0;  k_ph <= 16'd0;  b_left <= 13'd0;  k_left <= 13'd0;  b_up <= 8'd0;  b_on <= 1'b0;  k_on <= 1'b0;
            b_env <= 4'd0;  b_smp <= 16'sd0;  k_smp <= 16'sd0;  cue <= 16'sd0;
        end else if (sample_tick) begin
            // 节拍音
            if (bt_req || (bl_s[1] && !b_on)) begin
                b_on <= 1'b1;  b_left <= BEAT_N - 1;  b_up <= 8'd0;  b_ph <= 16'd0;
            end else if (b_on) begin
                b_ph <= b_ph + BEAT_INC;
                if (b_up != 8'hff) b_up <= b_up + 8'd1;
                if (bl_s[1])               b_left <= 13'd255;      // 吹气中：不收音
                else if (b_left == 13'd0) b_on <= 1'b0;
                else                       b_left <= b_left - 13'd1;
            end
            // 按键音
            if (kt_req) begin
                k_on <= 1'b1;  k_left <= KEY_N - 1;  k_ph <= 16'h4000;           // 三角波过零点
            end else if (k_on) begin
                k_ph <= k_ph + KEY_INC;
                if (k_left == 13'd0) k_on <= 1'b0; else k_left <= k_left - 13'd1;
            end
                    b_env <= !b_on ? 4'd0 : (b_up[7:4] < b_left[7:4] || b_left[12:8] != 5'd0) ? b_up[7:4] : b_left[7:4];
            b_smp <= scale16(tri_wave(b_ph), b_env);
            k_smp <= k_on ? (tri_wave(k_ph) >>> 2) : 16'sd0;
            cue   <= b_smp + k_smp;
        end
    end

    // ---------------- 混音（饱和）----------------
    wire signed [16:0] sum = {mix_in[15], mix_in} + {cue[15], cue};
    assign mix_out = (sum > 17'sd32767) ? 16'sd32767 : (sum < -17'sd32768) ? -16'sd32768 : sum[15:0];
endmodule
