`timescale 1ns/1ps

// CPR 急救流程状态机（R9：三部分急救，见 doc/R9_急救改版方案.md；R11 时间轴见 doc/R11_方案.md）
// 时钟：sd_card_clk（控制域）。
//
//   STANDBY ──K4 单击──▶ ① CALL 判断呼救（时间轴：0 有人晕倒 / 2 拍肩喊 / 5 看呼吸 / 7~11 倒数 5..1 / 12 打 120 取 AED /
//      ▲  ▲                   │ K4 长按 2 秒 = 误触取消      17「下面进行CPR按压和人工呼吸」/ 20 起正中提示「准备好后按K3」，停在 ① 等 K3）
//      │  └───────────────────┘                                                 │ K3
//      │                                                                        ▼
//      │                     ③ AED（K3 ⇄）② CPR 心肺复苏：30 次按压 → 10 秒人工呼吸 → 循环（默认 30:2，K2 单击切单纯按压）
//      └──── K4 长按 2 秒 ──── SUMMARY 交接（计时 / 计数冻结）◀── K4 长按 2 秒（② ③ 任意时刻）
//
// - 每次进入 ② 先准备（不打拍、不计数），然后第 1 拍从「一」数起：
//     第一次进入 / K1 重讲（intro_full）PREP_FULL_S = 10 秒：0「按图片技巧，按压两乳头中间三十次」、停顿、9「开始按压」
//     从 ③ 回来 PREP_S = 3 秒：「继续按压，跟我数」
// - 节拍只在 ② 走（③ AED 分析 / 电击时不打拍，防止有人跟着节拍继续按）；110 次/分 ≈ 545 ms，开始按压立刻打第 1 拍
// - cyc = 本组第几下（1~30），单纯按压也 30 下一组循环（语音数数 / 字幕 nn/30 用）；grp_bcd = 当前第几组
// - 30:2：第 30 下之后的那一拍位置进入人工呼吸 BREATH_S = 10 秒，br_sec 0~9：
//     0「下面进行人工呼吸，捏鼻包嘴，吹气两次，第一次，开始」 5 第 1 口  6「第二次吹气」 7 第 2 口  8「继续准备按压」—— 之后新的一组
// - 换人提示 swap（R12，不说话，正中黄框「到了两分钟，建议换人」）：跟左上「晕倒已过」对齐，计时到 02:00 / 04:00 / 06:00…
//   那一秒在 ② 或 ③（AED 分析时正好换人），立即显示 SWAP_SHOW_S 秒；还在 ① 就不提示。（R11 按 ② 里累计 120 秒、等下一次人工呼吸才显示，
//   屏上要到 2:30~2:50 才出现，用户 10-30 上板看 2:00 没提示）
// - replay_event（K1 单击）：① 重放时间轴；② ③ 重讲本部分要领（step_sec 清零，intro_full = 1）
// - step_ev / br_ev：step_sec / br_sec 每变一次（含清零）给一拍，guide_seq 按它排语音
// - 计时全部数 1 ms 节拍 ms_tick（ui_key_router 共用，省 3 个 27 位时钟计数器）：节拍用累加器
//   acc += BPM（每 ms），满 60000 打一拍 —— 间隔 545 / 546 ms 交替，平均正好 110 次/分
module cpr_flow_ctrl #(
    parameter integer PREP_S         = 3,
    parameter integer PREP_FULL_S    = 10,
    parameter integer BPM            = 110,
    parameter integer BREATH_S       = 10,
    parameter integer SWAP_SHOW_S    = 10
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ms_tick,           // 1 ms 单拍
    input  wire        start_event,       // K4 单击（待机）：开始急救
    input  wire        step_event,        // K3 单击：① -> ②，② -> ③（AED 到了），③ -> ②（AED 说继续 CPR）
    input  wire        mode_event,        // K2 单击：② ③ 里切换 单纯按压 / 30:2
    input  wire        end_event,         // K4 长按 2 秒：① 取消 / ② ③ -> 交接页 / 交接页 -> 待机
    input  wire        replay_event,      // K1 单击：重放本部分
    output wire        cpr_active,        // 1 = 不在待机（含交接页）
    output reg  [2:0]  state,
    output reg         mode_302,
    output reg         breath,            // 人工呼吸中
    output reg  [3:0]  br_sec,            // 人工呼吸第几秒 0~9
    output reg         br_ev,
    output reg         swap,              // R11：正中显示「到了两分钟，建议换人」
    output reg  [4:0]  cyc,               // 本组第几下 0~30（0 = 还没开始按）
    output reg  [7:0]  grp_bcd,           // 第几组（BCD 2 位，99 封顶）
    output reg         beat,              // 单拍：打一拍（节拍音 / 语音数数 / 角标脉动）
    output reg  [15:0] comp_bcd,          // 累计按压次数（BCD 4 位，9999 封顶）
    output reg  [15:0] timer_bcd,         // {m 十位, m 个位, s 十位, s 个位}
    output reg  [15:0] aed_time_bcd,      // 第一次 AED 送到（第一次进 ③）的时刻
    output reg         aed_seen,
    output reg  [6:0]  step_sec,          // 本部分已过秒数（换部分 / 重放清零）
    output reg         step_ev,
    output reg         intro,             // ② 开头准备中（讲要领 / 「继续按压」，不打拍、不数数）
    output reg         intro_full         // ② 这次讲完整要领（第一次进入或 K1 重放），否则只说「继续按压」
);
    localparam [2:0] S_STANDBY = 3'd0;
    localparam [2:0] S_CALL    = 3'd1;
    localparam [2:0] S_CPR     = 3'd2;
    localparam [2:0] S_AED     = 3'd3;
    localparam [2:0] S_SUMMARY = 3'd4;

    localparam [15:0] BEAT_FULL = 16'd60000 - BPM;             // acc 到这里，下一个 ms 打拍

    assign cpr_active = (state != S_STANDBY);
    wire running = (state == S_CALL) || (state == S_CPR) || (state == S_AED);

    reg [9:0]  tick_cnt;                 // ms
    reg [15:0] beat_acc;
    reg [9:0]  br_cnt;                   // ms
    reg        prep;                     // 进 ②：准备中，不打拍
    reg [3:0]  swap_s;                   // 换人提示还剩几秒
    reg        sec_q;                    // 秒节拍晚一拍（timer_bcd 已是新值）

    wire sec_tick = ms_tick && (tick_cnt == 10'd999);
    wire beating  = (state == S_CPR) && !prep;
    wire beat_due = ms_tick && (beat_acc >= BEAT_FULL);
    reg  step_clr;

    // mm:ss BCD 加一秒（99:59 封顶）
    function [15:0] bcd_inc;
        input [15:0] t;
        begin
            bcd_inc = t;
            if (t != 16'h9959) begin
                if (t[3:0] != 4'd9)        bcd_inc[3:0]   = t[3:0] + 4'd1;
                else begin
                    bcd_inc[3:0] = 4'd0;
                    if (t[7:4] != 4'd5)    bcd_inc[7:4]   = t[7:4] + 4'd1;
                    else begin
                        bcd_inc[7:4] = 4'd0;
                        if (t[11:8] != 4'd9) bcd_inc[11:8] = t[11:8] + 4'd1;
                        else begin
                            bcd_inc[11:8]  = 4'd0;
                            bcd_inc[15:12] = t[15:12] + 4'd1;
                        end
                    end
                end
            end
        end
    endfunction

    // 4 位 BCD 加一（9999 封顶）
    function [15:0] bcd4_inc;
        input [15:0] t;
        integer d;
        reg c;
        begin
            bcd4_inc = t;
            c = 1'b1;
            if (t != 16'h9999)
                for (d = 0; d < 4; d = d + 1)
                    if (c) begin
                        if (t[d*4 +: 4] == 4'd9) bcd4_inc[d*4 +: 4] = 4'd0;
                        else begin
                            bcd4_inc[d*4 +: 4] = t[d*4 +: 4] + 4'd1;
                            c = 1'b0;
                        end
                    end
        end
    endfunction

    // 2 位 BCD 加一（99 封顶）
    function [7:0] bcd2_inc;
        input [7:0] t;
        begin
            if (t == 8'h99)          bcd2_inc = t;
            else if (t[3:0] == 4'd9) bcd2_inc = {t[7:4] + 4'd1, 4'd0};
            else                     bcd2_inc = {t[7:4], t[3:0] + 4'd1};
        end
    endfunction

    // R9 时序：按压数加一每拍预先算好（原来 状态 -> 节拍 -> 4 位 BCD 进位链 一拍 8 级，-0.7~-1.2ns）。
    //   comp_bcd 只在节拍（beat_due，ms_tick 对齐，至少隔 1ms）和开始急救时变，下一拍 comp_nxt 就是新值
    //   组数同理（grp_bcd 在呼吸结束 / 单纯按压满 30 下 / AED 到了 / 切模式时加一，这几件事不会隔一拍连着发生）
    //   人工呼吸计满 1 秒（br_cnt == 999）同理
    reg [15:0] comp_nxt;
    reg [7:0]  grp_nxt;
    reg        br_end;
    always @(posedge clk) begin
        comp_nxt <= bcd4_inc(comp_bcd);
        grp_nxt  <= bcd2_inc(grp_bcd);
        br_end   <= (br_cnt == 10'd999);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_STANDBY;
            mode_302     <= 1'b1;
            breath       <= 1'b0;
            br_sec       <= 4'd0;
            br_ev        <= 1'b0;
            swap         <= 1'b0;
            cyc          <= 5'd0;
            grp_bcd      <= 8'h01;
            beat         <= 1'b0;
            comp_bcd     <= 16'd0;
            tick_cnt     <= 10'd0;
            step_sec     <= 7'd0;
            step_ev      <= 1'b0;
            beat_acc     <= BEAT_FULL;
            br_cnt       <= 10'd0;
            timer_bcd    <= 16'd0;
            aed_time_bcd <= 16'd0;
            aed_seen     <= 1'b0;
            prep         <= 1'b0;
            swap_s       <= 4'd0;
            sec_q        <= 1'b0;
            intro        <= 1'b0;
            intro_full   <= 1'b0;
        end else begin
            beat    <= 1'b0;
            br_ev   <= 1'b0;
            step_ev <= 1'b0;
            step_clr = 1'b0;
            intro   <= (state == S_CPR) && prep;
            sec_q   <= running && sec_tick;

            // 秒计时（只在急救进行中走）
            if (running && ms_tick) begin
                tick_cnt <= (tick_cnt == 10'd999) ? 10'd0 : tick_cnt + 10'd1;
                if (sec_tick) begin
                    timer_bcd <= bcd_inc(timer_bcd);
                    if (step_sec != 7'd127) begin
                        step_sec <= step_sec + 7'd1;
                        step_ev  <= 1'b1;
                    end
                    // 不预寄存：进 ② 那一拍 step_sec 刚清零，下一拍就可能是秒节拍
                    if (prep && step_sec + 7'd1 >= (intro_full ? PREP_FULL_S : PREP_S))
                        prep <= 1'b0;
                    if (swap_s != 4'd0) begin            // 换人提示倒计时
                        swap_s <= swap_s - 4'd1;
                        if (swap_s == 4'd1)
                            swap <= 1'b0;
                    end
                end
            end
            // 换人提示：计时刚变成偶数分钟整（分钟个位是偶数 = 总分钟数是偶数，且不是 00:00），在 ② ③ 就显示
            if (sec_q && timer_bcd[7:0] == 8'h00 && !timer_bcd[8] && timer_bcd[15:8] != 8'h00 &&
                (state == S_CPR || state == S_AED)) begin
                swap   <= 1'b1;
                swap_s <= SWAP_SHOW_S;
            end
            if (!running) begin                      // 待机 / 交接页：不提示
                swap   <= 1'b0;
                swap_s <= 4'd0;
            end

            // 节拍 / 人工呼吸（只在 ② 按压时走）
            if (!beating) begin
                beat_acc <= BEAT_FULL;                         // 开始按压后第一个 ms 就打第 1 拍
                br_cnt   <= 10'd0;
            end else if (breath) begin
                if (ms_tick && br_end) begin
                    br_cnt <= 10'd0;
                    if (br_sec == BREATH_S - 1) begin      // 人工呼吸结束：新的一组
                        breath   <= 1'b0;
                        br_sec   <= 4'd0;
                        cyc      <= 5'd0;
                        grp_bcd  <= grp_nxt;
                        beat_acc <= BEAT_FULL;
                    end else begin
                        br_sec <= br_sec + 4'd1;
                        br_ev  <= 1'b1;
                    end
                end else if (ms_tick)
                    br_cnt <= br_cnt + 10'd1;
            end else begin
                if (ms_tick)
                    beat_acc <= beat_due ? beat_acc + BPM - 16'd60000 : beat_acc + BPM;
                if (beat_due) begin
                    if (cyc >= 5'd30) begin                    // 一组 30 下满了
                        if (mode_302) begin                    // 第 31 拍的位置：改成人工呼吸
                            breath <= 1'b1;
                            br_sec <= 4'd0;
                            br_ev  <= 1'b1;
                            br_cnt <= 10'd0;
                        end else begin                         // 单纯按压：直接开始下一组的第 1 下
                            beat     <= 1'b1;
                            comp_bcd <= comp_nxt;
                            cyc      <= 5'd1;
                            grp_bcd  <= grp_nxt;
                        end
                    end else begin
                        beat     <= 1'b1;
                        comp_bcd <= comp_nxt;
                        cyc      <= cyc + 5'd1;
                    end
                end
            end

            case (state)
                S_STANDBY: begin
                    if (start_event) begin
                        // 新的一次急救：计时、计数、AED 时刻全部清零，默认 30:2
                        state        <= S_CALL;
                        mode_302     <= 1'b1;
                        breath       <= 1'b0;
                        cyc          <= 5'd0;
                        grp_bcd      <= 8'h01;
                        comp_bcd     <= 16'd0;
                        tick_cnt     <= 10'd0;
                        step_clr      = 1'b1;
                        timer_bcd    <= 16'd0;
                        aed_time_bcd <= 16'd0;
                        aed_seen     <= 1'b0;
                        prep         <= 1'b0;
                        intro_full   <= 1'b0;
                    end
                end
                S_SUMMARY: begin
                    if (end_event)
                        state <= S_STANDBY;
                end
                S_CALL: begin
                    if (end_event)
                        state <= S_STANDBY;                  // 误触取消：不进交接页
                    else if (step_event) begin               // R11：不再超时自动进 ②，讲完停在 ① 等 K3
                        state      <= S_CPR;
                        step_clr    = 1'b1;
                        prep       <= 1'b1;
                        intro_full <= 1'b1;
                    end else if (replay_event)
                        step_clr = 1'b1;
                end
                S_CPR: begin
                    if (end_event) begin
                        state  <= S_SUMMARY;
                        breath <= 1'b0;
                        prep   <= 1'b0;
                    end else if (step_event) begin           // AED 到了
                        state      <= S_AED;
                        step_clr    = 1'b1;
                        prep       <= 1'b0;
                        intro_full <= 1'b0;
                        breath     <= 1'b0;
                        cyc        <= 5'd0;
                        if (cyc != 5'd0 || breath)           // 这一组被打断：回来时算新的一组
                            grp_bcd <= grp_nxt;
                        if (!aed_seen) begin
                            aed_seen     <= 1'b1;
                            aed_time_bcd <= timer_bcd;
                        end
                    end else if (replay_event) begin       // K1 重讲要领：和第一次进入一样准备 PREP_FULL_S 秒，组内从「一」重新数
                        step_clr    = 1'b1;
                        intro_full <= 1'b1;
                        prep       <= 1'b1;
                        breath     <= 1'b0;
                        cyc        <= 5'd0;
                        if (cyc != 5'd0 || breath)           // 这一组被打断：算新的一组
                            grp_bcd <= grp_nxt;
                    end
                end
                S_AED: begin
                    if (end_event)
                        state <= S_SUMMARY;
                    else if (step_event) begin               // AED 说继续 CPR：先准备 3 秒（「继续按压，跟我数」），再从「一」数起
                        state    <= S_CPR;
                        step_clr  = 1'b1;
                        prep     <= 1'b1;
                        intro_full <= 1'b0;
                    end else if (replay_event)
                        step_clr = 1'b1;
                end
                default: state <= S_STANDBY;
            endcase

            if ((state == S_CPR || state == S_AED) && mode_event) begin
                mode_302 <= ~mode_302;
                breath   <= 1'b0;
                if (cyc != 5'd0 || breath)
                    grp_bcd <= grp_nxt;
                cyc      <= 5'd0;
            end

            if (step_clr) begin                      // 秒相位不清（总计时不漂），所以清零后第一秒可能不足 1 秒
                step_sec <= 7'd0;
                step_ev  <= 1'b1;
            end
        end
    end
endmodule
