`timescale 1ns/1ps

// R9 急救语音排程（sd_card_clk 域）：按急救流程的时刻，决定 GUIDE.WAV 播第几段；没有语音时节拍音顶上。
// GUIDE.WAV（tools/make_guide_wav.py 生成）：48 kHz 16 位单声道，第 n 段固定 1024 个扇区（5.46 秒，不够补静音），
//   段 n 起始扇区 = 数据起点 + n × 1024（顶层算）。段号：
//     0~29 数字「一」~「三十」（每拍数一个；① 倒数 5..1 也用 0~4）
//     30 拍他双肩，大声喊：你怎么了   31 看胸口有没有起伏   32 没有呼吸！一人打120，一人去取AED，位置看黄条
//     33 按图片技巧，按压两乳头中间，三十次   34 下面进行人工呼吸，捏鼻包嘴，吹气两次，第一次，开始   35 第二次吹气
//     36 继续准备按压   37 开始按压   38 这里有人晕倒了   39 继续按压，跟我数   40 AED到了，打开AED，照图做
//     41 下面进行CPR按压和人工呼吸   42 听AED语音，别碰患者（R11 换了 33~38 / 41 的内容，共 43 段，和底栏逐句对齐；没有提示音）
// 时刻表（R11，doc/R11_方案.md）：
//   ①  step_sec 0 → 38，2 → 30，5 → 31，7~11 → 倒数 五~一（按秒查表），12 → 32，17 → 41；之后不说话，等 K3
//   ②  第一次进入 / K1 重讲（intro_full，准备 10 秒）：0 → 33，9 → 37；从 ③ 回来（准备 3 秒）：0 → 39；
//       按压时每一拍数这一下（cyc = 1~30 → 段 0~29）；人工呼吸 br_sec 0 → 34，6 → 35，8 → 36（两分钟换人只在屏幕上提示，不说话）
//   ③  进入 / 重放 → 40，5 秒 → 42，之后不说话（听 AED 机器的语音）
// 新的一段到来立即打断正在播的（播放器先关 GAP 拍清缓冲，再从新段起点读）。
// 节拍音 beep：这一拍没有语音数数（没有 GUIDE.WAV / 静音）时才响，数数和节拍音不叠在一起（② 开头讲要领时不打拍，也就没有"滴"）。
module guide_seq #(
    parameter integer GAP = 4096                   // 换段时播放器关掉的拍数（41 us，读侧一个 48 kHz 样点以上）
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        guide_ok,                   // TF 卡里有 GUIDE.WAV，且 SD 口已经交给播放器
    input  wire        mute_event,                 // K1 长按：语音 静音 / 恢复
    input  wire [2:0]  st,
    input  wire [6:0]  step_sec,
    input  wire        step_ev,
    input  wire [3:0]  br_sec,
    input  wire        br_ev,
    input  wire        intro,
    input  wire        intro_full,
    input  wire        breath,
    input  wire        beat,
    input  wire [4:0]  cyc,
    output reg         g_own,                      // 1 = 急救中，播放器归语音（音乐停）
    output reg         g_play,                     // 播放器使能（换段时先拉低 GAP 拍）
    output reg  [5:0]  g_seg,
    output reg         muted,
    output reg         beep                        // 单拍：节拍音
);
    wire active = (st != 3'd0);
    reg        req;                                // 单拍：要播 nseg
    reg  [5:0] nseg;
    always @* begin
        req = 1'b0;  nseg = 6'd0;
        if (step_ev) begin
            case (st)
                3'd1: case (step_sec)
                    7'd0:  begin req = 1'b1;  nseg = 6'd38; end
                    7'd2:  begin req = 1'b1;  nseg = 6'd30; end
                    7'd5:  begin req = 1'b1;  nseg = 6'd31; end
                    7'd7:  begin req = 1'b1;  nseg = 6'd4;  end    // 五（R11：倒数按秒查表，不用减法）
                    7'd8:  begin req = 1'b1;  nseg = 6'd3;  end
                    7'd9:  begin req = 1'b1;  nseg = 6'd2;  end
                    7'd10: begin req = 1'b1;  nseg = 6'd1;  end
                    7'd11: begin req = 1'b1;  nseg = 6'd0;  end    // 一
                    7'd12: begin req = 1'b1;  nseg = 6'd32; end
                    7'd17: begin req = 1'b1;  nseg = 6'd41; end
                    default: ;
                endcase
                3'd2: if (step_sec == 7'd0) begin req = 1'b1;  nseg = intro_full ? 6'd33 : 6'd39; end
                      else if (step_sec == 7'd9 && intro_full && intro) begin req = 1'b1;  nseg = 6'd37; end
                3'd3: if (step_sec == 7'd0) begin req = 1'b1;  nseg = 6'd40; end
                      else if (step_sec == 7'd5) begin req = 1'b1;  nseg = 6'd42; end
                default: ;
            endcase
        end else if (br_ev && st == 3'd2) begin
            case (br_sec)
                4'd0:       begin req = 1'b1;  nseg = 6'd34; end
                4'd6:       begin req = 1'b1;  nseg = 6'd35; end
                4'd8:       begin req = 1'b1;  nseg = 6'd36; end
                default: ;
            endcase
        end else if (beat && st == 3'd2 && !intro && !breath && cyc != 5'd0) begin
            req = 1'b1;  nseg = {1'b0, cyc} - 6'd1;
        end
    end
    // 时序：要播哪段先寄存一拍（req / nseg 由十几个状态输入组合出来），再进 gap / g_seg
    reg        req_q;
    reg  [5:0] nseg_q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin req_q <= 1'b0;  nseg_q <= 6'd0; end
        else        begin req_q <= req;   nseg_q <= nseg; end
    wire voice = guide_ok && !muted;
    // 这一拍要不要节拍音：有语音数数就不响（讲要领 / 静音 / 没有 GUIDE.WAV 时响）
    wire count_ok = voice && (st == 3'd2) && !intro && !breath;

    reg [12:0] gap;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g_own <= 1'b0;  g_play <= 1'b0;  g_seg <= 6'd0;  muted <= 1'b0;  beep <= 1'b0;  gap <= 13'd0;
        end else begin
            g_own <= active;
            beep  <= beat && !count_ok;
            if (!active) begin
                muted  <= 1'b0;
                g_play <= 1'b0;
                gap    <= 13'd0;
            end else begin
                if (mute_event)
                    muted <= ~muted;
                if (mute_event && !muted) begin    // 刚静音：停掉正在播的
                    g_play <= 1'b0;
                    gap    <= 13'd0;
                end else if (req_q && voice) begin // 新的一段：先关 GAP 拍
                    g_seg  <= nseg_q;
                    g_play <= 1'b0;
                    gap    <= GAP[12:0];
                end else if (gap != 13'd0) begin
                    gap <= gap - 13'd1;
                    if (gap == 13'd1)
                        g_play <= 1'b1;
                end
                if (st == 3'd4)                    // 交接页：不说话
                    g_play <= 1'b0;
            end
        end
    end
endmodule
