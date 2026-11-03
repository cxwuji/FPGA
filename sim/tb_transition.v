`timescale 1ns/1ps
// R2 转场引擎自检：transition_engine 单独跑，假播放器（旧图 A / 新图 B，index_commit 在放行后的下一帧边界）。
// 小分辨率 128x96 便于快速跑完 14 种效果；每种效果逐帧统计 A / B / 黑 像素数，检查：
//   E1 出阶段只有 A 和黑、A 单调不增，最后全黑（HOLD）；进阶段只有 B 和黑、B 单调不增减，结束全是 B
//   E2 方向 / 形状：进阶段一半时，"先出现"的那个点是 B、"后出现"的点还是黑（擦除方向、圆扩 / 圆缩、菱形、百叶、棋盘）
//   E3 溶解一半时 B 约占 50%（30%~70%）；淡入淡出一半时亮度在中间；马赛克一半时块内像素相同
//   E4 硬切：一帧都不黑，直接换；速度 1 比速度 8 快
//   E5 放行时机：next_out 只在全黑之后出现；转场进行中的第二个请求被丢弃
//   E6（R8-2b）预览 preview_in：旧图消失到全黑再出现，还是同一张（不放行、不换图）；硬切预览什么都不做
//   E7（R12c）推移 14 / 15：马上放行换图、一帧都不黑、像素不遮罩；换图后 push_on，push_old = 旧图、push_h 对，
//      push_off 每帧不减、从 0 附近走到 W / H 后收尾；速度同档时帧数约为其他效果单阶段的 2 倍；推移预览不放行、旧图 = 当前图
// 运行（仓库根目录）：bash sim/run_transition.sh
module tb_transition;
localparam integer W = 128, H = 96;
localparam integer HB = 16, VB = 6;             // 消隐
reg cclk = 0; always #5  cclk = ~cclk;          // 100MHz
reg pclk = 0; always #20 pclk = ~pclk;          // 25MHz
reg rst_n = 0;

reg [9:0] hc = 0, vc = 0;
always @(posedge pclk) begin
    if (hc == W + HB - 1) begin hc <= 0; vc <= (vc == H + VB - 1) ? 0 : vc + 1; end
    else hc <= hc + 1;
end
wire de = (hc < W) && (vc < H);
wire [9:0] x = de ? hc : 10'd0;
wire [9:0] y = (vc < H) ? vc : 10'd0;
reg  vs_q = 0;
wire vs = (vc == H + 2);
always @(posedge pclk) vs_q <= vs;
wire frame_start = vs && !vs_q;

// 假播放器：bank 0 = A（红为主），bank 1 = B（蓝为主）；放行后在下一个 frame_start 换图并给 index_commit
reg  bank = 0;
reg  commit = 0, pend_commit = 0;
wire next_out, prev_out, busy;
always @(posedge pclk) begin
    commit <= 1'b0;
    if (frame_start && pend_commit) begin bank <= ~bank; commit <= 1'b1; end
end
reg rel_tgl = 0; reg [2:0] rel_s = 0;
always @(posedge cclk) if (next_out || prev_out) rel_tgl <= ~rel_tgl;
always @(posedge pclk) begin
    rel_s <= {rel_s[1:0], rel_tgl};
    if (rel_s[2] != rel_s[1]) pend_commit <= 1'b1;
    else if (frame_start) pend_commit <= 1'b0;
end

wire [23:0] A = {8'hf0, x[6:0], 1'b0, 8'h10};
wire [23:0] B = {8'h10, y[6:0], 1'b0, 8'hf0};
wire [23:0] rgb_in = bank ? B : A;

reg        req = 0, preq = 0, vreq = 0;
reg  [3:0] eff = 0, spd = 3;
wire [23:0] rgb;
wire [7:0] aa;
wire act;
wire       push_on, push_h;
wire [2:0] push_old;
wire [9:0] push_off;
transition_engine #(.ENABLE(1), .H_ACT(W), .V_ACT(H)) dut (
    .ctrl_clk(cclk), .ctrl_rst_n(rst_n), .next_in(req), .prev_in(preq), .preview_in(vreq), .effect_in(eff), .speed_in(spd),
    .no_transition(1'b0), .next_out(next_out), .prev_out(prev_out), .busy(busy),
    .pix_clk(pclk), .pix_rst_n(rst_n), .player_active(1'b1), .frame_start(frame_start), .index_commit(commit),
    .de(de), .x(x), .y(y), .bri(8'd255), .rgb_in(rgb_in), .rgb_out(rgb), .audio_alpha(aa), .active(act),
    .active_index({2'b00, bank}), .push_on(push_on), .push_h(push_h), .push_old(push_old), .push_off(push_off)
);

// ---------------- 逐帧统计 ----------------
integer na, nb, nk, f_na, f_nb, f_nk;
reg [23:0] snap [0:W*H-1];
always @(posedge pclk) begin
    if (frame_start) begin f_na = na; f_nb = nb; f_nk = nk; na = 0; nb = 0; nk = 0; end
    if (de) begin
        snap[y * W + x] = rgb;
        if (rgb == 24'd0) nk = nk + 1;
        else if (rgb[23:16] > rgb[7:0]) na = na + 1;
        else nb = nb + 1;
    end
end
// 一帧结束后 f_* 是上一帧的统计、snap 是上一帧的画面（下一帧开头才开始覆盖）
task wait_frame; begin @(posedge pclk); while (!frame_start) @(posedge pclk); @(posedge pclk); end endtask
function is_b; input integer px, py; reg [23:0] c; begin c = snap[py * W + px]; is_b = (c != 0) && (c[7:0] > c[23:16]); end endfunction
function is_k; input integer px, py; begin is_k = (snap[py * W + px] == 24'd0); end endfunction

integer errors = 0;
reg trace = 0;
always @(posedge pclk) if (trace && frame_start) $display("    fs t=%0t state=%0d p=%0d bank=%0d pend=%0d busy=%0d na=%0d nb=%0d nk=%0d", $time, dut.g_eng.state, dut.g_eng.p, bank, pend_commit, busy, na, nb, nk);
task check(input ok, input [1023:0] what);
    begin
        if (ok) $display("  ok   %0s", what);
        else begin $display("  FAIL %0s", what); errors = errors + 1; end
    end
endtask

integer e, fr, prev_a, prev_b, out_frames, in_frames, mono_bad, mix_bad, half_done, released_early, total;
integer fast_frames, slow_frames;
reg [23:0] c0, c1;
reg [1023:0] name;
task run_one(input [3:0] ef, input [3:0] sp, output integer frames);
    begin
        eff = ef; spd = sp;
        bank = 0;                       // 每次都从旧图 A 开始（假播放器）
        wait_frame;
        @(posedge cclk); req = 1; @(posedge cclk); req = 0;
        repeat (3) @(posedge cclk); req = 1; @(posedge cclk); req = 0;   // 第二个请求：应被丢弃
        while (dut.g_eng.state == 2'd0) @(posedge pclk);                 // 等像素域接到请求
        prev_a = W * H; prev_b = 0; out_frames = 0; in_frames = 0; mono_bad = 0; mix_bad = 0;
        half_done = 0; released_early = 0; frames = 0;
        // 出阶段
        while (dut.g_eng.state != 2'd2 && dut.g_eng.state != 2'd0) begin
            wait_frame; frames = frames + 1;
            if (dut.g_eng.state == 2'd1 || dut.g_eng.state == 2'd2) begin
                out_frames = out_frames + 1;
                if (f_nb != 0) mix_bad = mix_bad + 1;
                if (f_na > prev_a) mono_bad = mono_bad + 1;
                prev_a = f_na;
                if (f_na != 0 && pend_commit) released_early = released_early + 1;
            end
            if (frames > 200) begin $display("  卡死 state=%0d", dut.g_eng.state); disable run_one; end
        end
        // 进阶段
        while (dut.g_eng.state != 2'd0) begin
            wait_frame; frames = frames + 1;
            if (dut.g_eng.state == 2'd3) begin
                in_frames = in_frames + 1;
                if (f_na != 0) mix_bad = mix_bad + 1;
                if (f_nb < prev_b) mono_bad = mono_bad + 1;
                prev_b = f_nb;
                if (!half_done && dut.g_eng.p >= 9'd128) half_done = 1;   // 下一帧（p≈一半）的画面用来检查形状
            end
            if (frames > 400) begin $display("  卡死 state=%0d", dut.g_eng.state); disable run_one; end
        end
        wait_frame; wait_frame;
    end
endtask

reg [23:0] half [0:W*H-1];
integer hn_b, hn_k, i;
task grab_half2(input [3:0] ef, input out_phase);
    begin
        eff = ef; spd = 8;
        bank = 0;
        wait_frame;
        @(posedge cclk); req = 1; @(posedge cclk); req = 0;
        while (!(dut.g_eng.state == (out_phase ? 2'd1 : 2'd3) && dut.g_eng.p >= 9'd120)) @(posedge pclk);
        wait_frame; wait_frame;          // 完整画完一帧
        hn_b = 0; hn_k = 0;
        for (i = 0; i < W * H; i = i + 1) begin
            half[i] = snap[i];
            if (snap[i] == 0) hn_k = hn_k + 1; else if (snap[i][7:0] > snap[i][23:16]) hn_b = hn_b + 1;
        end
        while (dut.g_eng.state != 2'd0) @(posedge pclk);
        wait_frame;
    end
endtask
function hb; input integer px, py; reg [23:0] c; begin c = half[py * W + px]; hb = (c != 0) && (c[7:0] > c[23:16]); end endfunction
function hk; input integer px, py; begin hk = (half[py * W + px] == 24'd0); end endfunction

initial begin
    #300 rst_n = 1;
    repeat (3) wait_frame;
    // ---- E1 / E5：每种效果的逐帧单调性 ----
`ifdef TRACE
    trace = 1; run_one(4'd0, 4'd3, total); run_one(4'd1, 4'd3, total); trace = 0;
    $display("out %0d in %0d mono %0d mix %0d bank %0d fnb %0d", out_frames, in_frames, mono_bad, mix_bad, bank, f_nb);
    $finish;
`endif
    for (e = 0; e <= 13; e = e + 1) begin
        run_one(e[3:0], 4'd3, total);
        if (e == 13)
            check(out_frames <= 1 && in_frames == 0 && mix_bad == 0, "E4 effect 13 CUT: no black frames, direct switch");
        else begin
            $sformat(name, "E1 effect %0d: out %0d frames / in %0d frames, monotonic, no A/B mix", e, out_frames, in_frames);
            check(mono_bad == 0 && mix_bad == 0 && out_frames >= 7 && in_frames >= 6, name);
        end
        if (e != 13) check(released_early == 0, "E5 release only after the frame is fully black");
        check(bank == 1'b1, "E5 exactly one switch per request (second request during transition dropped)");
        check(f_nb == W * H, "E1 ends with whole frame = new image");
    end
    // ---- E4：速度 ----
    run_one(4'd1, 4'd1, fast_frames);
    run_one(4'd1, 4'd8, slow_frames);
    $sformat(name, "E4 speed 1 = %0d frames, speed 8 = %0d frames", fast_frames, slow_frames);
    check(fast_frames <= 12 && slow_frames >= 55, name);
    // ---- E2 / E3：半程形状 ----
    grab_half2(4'd1, 0); check(hb(4, 48) && hk(123, 48), "E2 WIPE-R: left revealed first");
    grab_half2(4'd2, 0); check(hk(4, 48) && hb(123, 48), "E2 WIPE-L: right revealed first");
    grab_half2(4'd3, 0); check(hb(64, 3) && hk(64, 92), "E2 WIPE-D: top revealed first");
    grab_half2(4'd4, 0); check(hk(64, 3) && hb(64, 92), "E2 WIPE-U: bottom revealed first");
    grab_half2(4'd5, 0); check(hb(64, 48) && hk(1, 1) && hk(126, 94), "E2 CIRCLE+: centre first, corners last");
    grab_half2(4'd6, 0); check(hk(64, 48) && hb(1, 1) && hb(126, 94), "E2 CIRCLE-: corners first, centre last");
    grab_half2(4'd7, 0); check(hb(64, 48) && hk(1, 1) && hb(64, 30) && hk(1, 47), "E2 DIAMOND: grows from centre");
    grab_half2(4'd8, 0); check(hb(64, 1) && hk(64, 30) && hb(64, 33) && hk(64, 62), "E2 BLIND-H: every 32-row band top half first");
    grab_half2(4'd9, 0); check(hb(1, 40) && hk(62, 40) && hb(65, 40) && hk(126, 40), "E2 BLIND-V: every 64-col band left half first");
    grab_half2(4'd10, 0); check(hb(50, 10) && hk(70, 10) && hk(4, 70), "E2 CHECKER: one colour of cells done, other not started");
    grab_half2(4'd11, 0);
    $sformat(name, "E3 DISSOLVE half: %0d / %0d pixels revealed", hn_b, W * H);
    check(hn_b > W * H * 3 / 10 && hn_b < W * H * 7 / 10, name);
    grab_half2(4'd0, 0);
    c0 = half[48 * W + 64];
    $sformat(name, "E3 FADE half: pixel blue = %0d (full 240)", c0[7:0]);
    check(hn_b == W * H && c0[7:0] > 8'd60 && c0[7:0] < 8'd200, name);
    grab_half2(4'd12, 1);
    c0 = half[0]; c1 = half[1];
    check(hn_k == 0 && c0 == c1 && half[W] == c0, "E3 MOSAIC (out phase): neighbours inside a block identical");
    // ---- E6：同一张图预览 ----
    begin : e6_blk
    eff = 4'd5; spd = 4'd3; bank = 0;
    wait_frame;
    c0 = {23'd0, rel_tgl};
    @(posedge cclk); vreq = 1; @(posedge cclk); vreq = 0;
    while (dut.g_eng.state == 2'd0) @(posedge pclk);
    out_frames = 0; in_frames = 0; mix_bad = 0; mono_bad = 0; prev_a = W * H; total = 0; fr = 0;
    while (dut.g_eng.state != 2'd0) begin
        wait_frame; fr = fr + 1;
        if (dut.g_eng.state == 2'd2) mono_bad = mono_bad + 1;          // 不该进 HOLD
        if (f_nb != 0) mix_bad = mix_bad + 1;                           // 全程不该出现 B
        if (f_nk == W * H) total = total + 1;                           // 全黑帧
        if (dut.g_eng.state == 2'd3) in_frames = in_frames + 1; else out_frames = out_frames + 1;
        if (fr > 200) begin $display("  卡死 state=%0d", dut.g_eng.state); fr = 999; disable e6_blk; end
    end
    end
    wait_frame; wait_frame;
    $sformat(name, "E6 preview: out %0d / in %0d frames, %0d full-black, no HOLD, never image B", out_frames, in_frames, total);
    check(mono_bad == 0 && mix_bad == 0 && out_frames >= 7 && in_frames >= 6 && total >= 1, name);
    check(bank == 1'b0 && rel_tgl == c0[0] && !pend_commit, "E6 preview: no release to player, image unchanged");
    check(f_na == W * H, "E6 preview ends with whole frame = same old image");
    eff = 4'd13; c0 = {23'd0, rel_tgl};
    @(posedge cclk); vreq = 1; @(posedge cclk); vreq = 0;
    repeat (3) wait_frame;
    check(dut.g_eng.state == 2'd0 && !busy && bank == 1'b0 && rel_tgl == c0[0] && f_na == W * H, "E6 CUT preview: nothing happens");
    // ---- E7（R12c）推移 ----
    for (e = 14; e <= 15; e = e + 1) begin : e7_blk
        integer nfr, nblack, npush, off_prev, off_bad, old_bad, h_bad, off_last, off_first;
        eff = e[3:0]; spd = 4'd3; bank = 0;
        wait_frame;
        @(posedge cclk); req = 1; @(posedge cclk); req = 0;
        while (dut.g_eng.state == 2'd0) @(posedge pclk);
        check(dut.g_eng.state == 2'd2, "E7 push: released at once (HOLD, no fade-out phase)");
        nfr = 0; nblack = 0; npush = 0; off_prev = 0; off_bad = 0; old_bad = 0; h_bad = 0; off_first = -1; off_last = 0;
        while (dut.g_eng.state != 2'd0) begin
            @(posedge pclk); while (!frame_start) @(posedge pclk);
            repeat (10) @(posedge pclk);                                   // reader 第 7 拍锁存，这里参数早已稳定
            nfr = nfr + 1;
            if (f_nk != 0) nblack = nblack + 1;
            if (push_on) begin
                npush = npush + 1;
                if (off_first < 0) off_first = push_off;
                if (push_off < off_prev) off_bad = off_bad + 1;
                off_prev = push_off;  off_last = push_off;
                if (push_old != 3'd0) old_bad = old_bad + 1;
                if (push_h != (e == 14)) h_bad = h_bad + 1;
            end
            if (nfr > 300) begin $display("  卡死 state=%0d", dut.g_eng.state); disable e7_blk; end
        end
        wait_frame; wait_frame;
        $sformat(name, "E7 effect %0d: %0d frames, %0d push frames, off %0d -> %0d, no black frame", e, nfr, npush, off_first, off_last);
        check(nblack == 0 && f_nk == 0 && npush >= 12 && npush <= 18 && off_bad == 0 && off_first < 60 &&
              off_last == ((e == 14) ? W : H), name);
        check(old_bad == 0 && h_bad == 0 && bank == 1'b1 && f_nb == W * H, "E7 push: old bank = 0, direction right, ends on new image, one switch");
        check(aa == 8'd255, "E7 push: audio not faded");
    end
    // 推移预览：不放行、旧图 = 当前图
    eff = 4'd14; spd = 4'd3; bank = 0; c0 = {23'd0, rel_tgl};
    wait_frame;
    @(posedge cclk); vreq = 1; @(posedge cclk); vreq = 0;
    while (dut.g_eng.state == 2'd0) @(posedge pclk);
    check(dut.g_eng.state == 2'd3 && push_old == 3'd0, "E7 push preview: straight into the push phase, old = current image");
    while (dut.g_eng.state != 2'd0) @(posedge pclk);
    wait_frame;
    check(bank == 1'b0 && rel_tgl == c0[0] && !pend_commit && f_na == W * H, "E7 push preview: no release, image unchanged");
    $display("RESULT: %0s（%0d 个失败）", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
end
initial begin #2_000_000_000; $display("RESULT: FAIL（超时）"); $finish; end
endmodule
