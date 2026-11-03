`timescale 1ns/1ps
// R9 急救语音排程自检：cpr_flow_ctrl + guide_seq（时钟缩小：CLK_HZ = 1000，1 秒 = 1000 拍）
// R11 时间轴（doc/R11_方案.md）：
//   G1 ①：0 秒段 38 有人晕倒、2 秒段 30、5 秒段 31、7~11 秒倒数 五~一（段 4..0）、12 秒段 32、17 秒段 41；之后停在 ① 不自动进 ②，K3 进 ②
//   G2 ② 第一次：段 33（要领），准备 10 秒不打拍，9 秒段 37 开始按压，10 秒第 1 拍「一」；之后每拍数这一下，有语音的拍不响节拍音
//   G3 人工呼吸 10 秒：0 段 34、6 段 35、8 段 36；R12 换人：「晕倒已过」到偶数分钟整（02:00 / 04:00）在 ② ③ 立即 swap = 1
//      显示 10 秒、不说话；奇数分钟、还在 ① 都不提示
//   G4 ③：段 40，5 秒段 42，不打拍；K3 回 ②：段 39，先准备 3 秒（不打拍、没有滴声），第 1 拍从「一」（段 0）数起；
//      K1 重讲：段 33，准备 10 秒（9 秒段 37）后从「一」数起，被打断的组作废（组数 +1），总按压数不清零
//   G5 K1 长按静音：不再播新段、每拍都是节拍音；再长按恢复。没有 GUIDE.WAV 时同静音
//   G6 每次换段播放器先关 GAP 拍（g_play 低）再开，段号已更新
// 运行（仓库根目录）：bash sim/run_guide.sh
module tb_guide;
localparam integer HZ = 1000;
reg clk = 1'b0;  always #5 clk = ~clk;
reg rst_n = 1'b0;
reg start = 0, step = 0, mode = 0, endk = 0, rep = 0, mute = 0, gok = 1;
wire        act, br, brev, swp, bt, stev, intro, full, m302, aseen;
wire [2:0]  st;
wire [3:0]  brs;
wire [4:0]  cyc;
wire [7:0]  grp;
wire [15:0] cmp, tmr, aedt;
wire [6:0]  ssec;
wire        own, play, muted, beep;
wire [5:0]  seg;
cpr_flow_ctrl u_cpr (
    .clk(clk), .rst_n(rst_n), .ms_tick(1'b1), .start_event(start), .step_event(step), .mode_event(mode), .end_event(endk), .replay_event(rep),
    .cpr_active(act), .state(st), .mode_302(m302), .breath(br), .br_sec(brs), .br_ev(brev), .swap(swp), .cyc(cyc), .grp_bcd(grp),
    .beat(bt), .comp_bcd(cmp), .timer_bcd(tmr), .aed_time_bcd(aedt), .aed_seen(aseen), .step_sec(ssec), .step_ev(stev),
    .intro(intro), .intro_full(full)
);
guide_seq #(.GAP(4)) u_g (
    .clk(clk), .rst_n(rst_n), .guide_ok(gok), .mute_event(mute), .st(st), .step_sec(ssec), .step_ev(stev), .br_sec(brs), .br_ev(brev),
    .intro(intro), .intro_full(full), .breath(br), .beat(bt), .cyc(cyc),
    .g_own(own), .g_play(play), .g_seg(seg), .muted(muted), .beep(beep)
);
// 记录每次播放器重新打开时的段号（= 真正开始播的一段）和时刻
integer nseg = 0, nbeat = 0, nbeep = 0, errors = 0, i;
integer segs [0:1023];
integer segt [0:1023];
reg play_q = 0;
always @(posedge clk) begin
    play_q <= play;
    if (play && !play_q) begin segs[nseg] = seg; segt[nseg] = $time / 10; nseg = nseg + 1; end
    if (bt) nbeat = nbeat + 1;
    if (beep) nbeep = nbeep + 1;
end
task tick(input integer n); begin repeat (n) @(posedge clk); end endtask
`define PULSE(s) begin @(negedge clk) s = 1; @(negedge clk) s = 0; end
task check(input ok, input [1023:0] what);
    begin
        if (ok) $display("  ok   %0s", what);
        else begin $display("  FAIL %0s", what); errors = errors + 1; end
    end
endtask
function seq_is(input integer from, input integer n, input [8*16-1:0] want);   // segs[from..from+n-1] == want（高位起每字节一段）
    integer k;
    begin
        seq_is = (nseg >= from + n);
        for (k = 0; k < n; k = k + 1)
            if (segs[from + k] != want[8 * (n - 1 - k) +: 8]) seq_is = 0;
    end
endfunction
task dump(input integer from);
    integer k;
    begin
        $write("    段：");
        for (k = from; k < nseg; k = k + 1) $write(" %0d@%0d", segs[k], segt[k]);
        $write("\n");
    end
endtask
integer s0, b0, p0, t0;
initial begin #(10 * 500000); $display("  FAIL 超时（卡在某个 wait）t=%0d st=%0d br=%0d cyc=%0d", $time / 10, st, br, cyc); dump(0); $display("RESULT: FAIL"); $finish; end
initial begin
    tick(5); rst_n = 1;  tick(5);
    // ---- G1 ① ----
    `PULSE(start)
    tick(7500);
    check(st == 3'd1 && seq_is(0, 4, {8'd38, 8'd30, 8'd31, 8'd4}), "G1 0 s 38 有人晕倒 / 2 s 30 / 5 s 31 / 7 s 五");
    tick(10000);
    check(st == 3'd1 && seq_is(0, 10, {8'd38, 8'd30, 8'd31, 8'd4, 8'd3, 8'd2, 8'd1, 8'd0, 8'd32, 8'd41}),
          "G1 part 1 timeline: 38 / 30 / 31 / countdown 五四三二一 (4..0) / 32 / 41 下面进行CPR");
    if (errors) dump(0);
    check(segt[3] - segt[2] > 1900 && segt[3] - segt[2] < 2100 && segt[7] - segt[3] > 3900 && segt[7] - segt[3] < 4100,
          "G1 countdown 五 at 7 s, 一 at 11 s (one per second)");
    check(own && nbeat == 0, "G1 voice owns the player, no beats in part 1");
    s0 = nseg;
    tick(20000);
    check(st == 3'd1 && nseg == s0 && ssec >= 7'd20, "G1 waits in part 1 after 20 s (no auto advance, no more voice)");
    u_cpr.timer_bcd = 16'h0159;
    wait (tmr == 16'h0200); tick(3);
    check(st == 3'd1 && !swp, "G1 02:00 still in part 1: no swap hint");
    `PULSE(step)  tick(2);
    check(st == 3'd2 && full && intro, "G1 K3 -> part 2, full intro");
    // ---- G2 ② 第一次 ----
    s0 = nseg;  b0 = nbeat;
    tick(10);
    check(segs[nseg - 1] == 33 && nbeat == b0, "G2 part 2 entry -> segment 33 (按图片技巧按压两乳头中间三十次)");
    tick(8000);
    check(nbeat == b0 && nseg == s0 + 1, "G2 0~8 s: silent pause, no beat");
    tick(1200);
    check(segs[nseg - 1] == 37 && nbeat == b0 && intro, "G2 9 s -> segment 37 开始按压, still no beat");
    s0 = nseg;
    wait (bt); tick(10);
    check(cyc == 1 && segs[s0] == 0 && !intro, "G2 10 s: first beat says 一 (segment 0)");
    s0 = nseg;  b0 = nbeat;  p0 = nbeep;
    for (i = 0; i < 5; i = i + 1) begin wait (bt); tick(10); end
    check(nbeat == b0 + 5 && nseg == s0 + 5 && segs[s0] == 1 && segs[s0 + 4] == 5 && nbeep == p0,
          "G2 every beat says its count (segments 1..5 = 二..六), no metronome beep while counting");
    if (errors) dump(s0);
    // ---- G3 人工呼吸 ----
    u_cpr.cyc = 5'd28;
    wait (bt); tick(10);
    s0 = nseg;
    wait (bt); tick(10);
    check(segs[s0] == 29 && cyc == 5'd30, "G3 30th compression says 三十 (segment 29)");
    wait (br); tick(10);
    s0 = nseg - 1;
    check(!swp, "G3 no swap hint before 2 minutes");
    tick(9000);
    check(br && seq_is(s0, 3, {8'd34, 8'd35, 8'd36}), "G3 rescue breaths: 0 s 34 / 6 s 35 第二次吹气 / 8 s 36 继续准备按压");
    check(segt[s0 + 1] - segt[s0] > 5900 && segt[s0 + 1] - segt[s0] < 6100 && segt[s0 + 2] - segt[s0] > 7900 && segt[s0 + 2] - segt[s0] < 8100,
          "G3 breath segment timing 0 / 6 / 8 s");
    tick(1100);
    check(!br && grp == 8'h02 && nseg <= s0 + 4, "G3 10 s breaths done -> group 02");
    if (errors) dump(s0);
    // 换人（R12）：计时直接拨到 03:59 -> 04:00 在 ② 立即提示（30:2 不等人工呼吸），显示 10 秒，跨过人工呼吸也不提前撤
    u_cpr.timer_bcd = 16'h0359;
    check(!swp, "G3 03:59 no swap hint");
    s0 = nseg;
    wait (tmr == 16'h0400); tick(3);
    check(swp && !br, "G3 04:00 in part 2 -> swap hint at once (not waiting for the breaths)");
    u_cpr.cyc = 5'd29;                                  // 让人工呼吸落在提示期间
    wait (br); tick(10);
    check(swp && segs[nseg - 1] == 34, "G3 breaths during the hint: voice unchanged (34), hint stays");
    wait (tmr == 16'h0409); tick(3);
    check(swp, "G3 hint still on at 04:09");
    wait (tmr == 16'h0410); tick(3);
    check(!swp, "G3 swap hint off after 10 s (04:10)");
    wait (!br); tick(5);
    u_cpr.timer_bcd = 16'h0459;
    wait (tmr == 16'h0500); tick(3);
    check(!swp, "G3 05:00 (odd minute): no hint");
    // 单纯按压也一样
    `PULSE(mode)  tick(5);
    check(!m302, "G3 K2 -> pure compressions");
    u_cpr.timer_bcd = 16'h0559;
    wait (tmr == 16'h0600); tick(3);
    check(swp, "G3 pure compressions: 06:00 -> swap hint");
    tick(9000);
    check(swp, "G3 pure compressions: hint still on at 9 s");
    tick(1500);
    check(!swp && !br, "G3 pure compressions: hint off after 10 s");
    `PULSE(mode)  tick(5);
    check(m302, "G3 K2 -> back to 30:2");
    // ---- G4 ③ / 回 ② ----
    `PULSE(step)  tick(10);
    check(st == 3'd3 && segs[nseg - 1] == 40, "G4 K3 -> part 3 -> segment 40 (AED到了，打开AED)");
    s0 = nseg;  b0 = nbeat;
    tick(6000);
    check(nseg == s0 + 1 && segs[s0] == 42 && nbeat == b0, "G4 part 3: 5 s -> segment 42 (听AED语音), no beats");
    u_cpr.timer_bcd = 16'h0759;
    wait (tmr == 16'h0800); tick(3);
    check(st == 3'd3 && swp, "G4 08:00 in part 3 (AED analysing) -> swap hint");
    s0 = nseg;  p0 = nbeep;  t0 = cmp;
    `PULSE(step)  tick(10);
    check(st == 3'd2 && !full && segs[nseg - 1] == 39 && nbeat == b0 && cyc == 0, "G4 K3 -> part 2 again: segment 39 继续按压跟我数, no beat yet");
    tick(1900);
    check(nbeat == b0 && nbeep == p0 && nseg == s0 + 1, "G4 re-entry preparation: no beats, no metronome beep");
    s0 = nseg;
    wait (bt); tick(10);
    check(cyc == 1 && nseg == s0 + 1 && segs[s0] == 0 && nbeep == p0, "G4 after preparation counting restarts at 一 (segment 0)");
    check(cmp != t0, "G4 total compressions keep counting (not cleared)");
    for (i = 0; i < 3; i = i + 1) begin wait (bt); tick(10); end
    s0 = nseg;  b0 = nbeat;  t0 = grp;
    `PULSE(rep)  tick(10);
    check(full && cyc == 0 && segs[nseg - 1] == 33 && grp != t0, "G4 K1 replay in part 2: segment 33, group restarts (new group)");
    t0 = $time / 10;
    tick(8000);
    check(nbeat == b0, "G4 replay preparation: no beats for 8 s");
    wait (bt); tick(10);
    // 秒相位不清（总计时不漂），第一秒可能不足 1 秒：准备实际 9~10 秒
    check(cyc == 1 && segs[nseg - 1] == 0 && segs[nseg - 2] == 37 && $time / 10 - t0 > 9000 && $time / 10 - t0 < 10100,
          "G4 replay: 37 开始按压, then counting restarts at 一 after 9~10 s");
    // ---- G5 静音 ----
    `PULSE(mute)  tick(2);
    check(muted && !play, "G5 K1 hold -> muted, player stopped");
    s0 = nseg;  p0 = nbeep;  b0 = nbeat;
    tick(3000);
    check(nseg == s0 && nbeep - p0 == nbeat - b0 && nbeat > b0, "G5 muted: no segments, every beat beeps");
    `PULSE(mute)  tick(2);
    check(!muted, "G5 K1 hold again -> voice back");
    wait (bt); tick(10);
    check(nseg == s0 + 1, "G5 count spoken again after unmute");
    gok = 0;  s0 = nseg;  p0 = nbeep;  b0 = nbeat;
    tick(2000);
    check(nseg == s0 && nbeep - p0 == nbeat - b0, "G5 no GUIDE.WAV: beeps on every beat, no segments");
    gok = 1;
    // ---- G6 交接 / 回待机 ----
    `PULSE(endk)  tick(10);
    check(st == 3'd4 && !play, "G6 K4 hold -> summary, voice off");
    `PULSE(endk)  tick(10);
    check(st == 3'd0 && !own && !muted, "G6 back to standby: player back to music");
    $display("RESULT: %0s（%0d 个失败）", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
end
endmodule
