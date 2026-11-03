`timescale 1ns/1ps
// R8-3 频谱自检（只测 audio_spectrum，不跑视频时序，帧周期缩短成 45000 拍，样点每 20 拍一个，所以很快）：
//   P1 抽取 FIR + 环形缓冲：DUT 的 512 点缓冲和测试台自己滤出来的逐位相同
//   P2 加窗：LOAD 后工作 RAM（位反序）= 缓冲 × Hann 窗 >> 14，逐位相同
//   P3 FFT：结果和测试台按浮点算的 DFT / 512 比，误差 ≤ 16（满幅约 65536）
//   P4 单音 1 kHz / 5 kHz：最高的柱落在该频率所在的那根，高度 44~56，离开 4 根以上的柱至少低 24 点（36 dB）
//   P5 双音 300 Hz + 3 kHz：两根对应的柱都是局部最高
//   P6 显示高度：每帧按"快升慢落 + 顶帽停 30 帧"的规则和测试台模型逐帧完全一致；静音后柱子落到 0，顶帽先停 30 帧再落
// 运行（仓库根目录）：bash sim/run_spectrum.sh
module tb_spectrum;
`include "../user_source/hdl_source/include/spectrum_tables.vh"
reg clk = 1'b0; always #20 clk = ~clk;
reg rst_n = 1'b0;
localparam integer FRAME = 45000, SDIV = 20;

reg fs = 0, pv = 0;
reg signed [15:0] pcm = 0;
reg [4:0] rb = 0;
wire [5:0] rh, rc;
audio_spectrum dut (.clk(clk), .rst_n(rst_n), .frame_start(fs), .pcm_valid(pv), .pcm(pcm), .rd_bar(rb), .rd_h(rh), .rd_cap(rc));

// ---------------- 信号源：两个正弦（相位累加 + 1024 点表）----------------
integer sint [0:1023];
integer ti;
initial for (ti = 0; ti < 1024; ti = ti + 1) sint[ti] = $rtoi(32767.0 * $sin(6.283185307 * ti / 1024.0));
integer a1 = 0, a2 = 0;              // 幅度（0~32767）
real    f1 = 1000.0, f2 = 0.0;       // Hz（按 48 kHz 采样）
real    ph1 = 0.0, ph2 = 0.0;
integer fcnt = 0, scnt = 0, nframe = 0;
always @(posedge clk) begin
    fs <= 1'b0; pv <= 1'b0;
    if (rst_n) begin
        fcnt <= (fcnt == FRAME - 1) ? 0 : fcnt + 1;
        if (fcnt == FRAME - 1) begin fs <= 1'b1; nframe <= nframe + 1; end
        scnt <= (scnt == SDIV - 1) ? 0 : scnt + 1;
        if (scnt == SDIV - 1) begin
            pv <= 1'b1;
            pcm <= (a1 * sint[$rtoi(ph1 * 1024.0) % 1024] + a2 * sint[$rtoi(ph2 * 1024.0) % 1024]) / 32767;
            ph1 = ph1 + f1 / 48000.0; if (ph1 >= 1.0) ph1 = ph1 - 1.0;
            ph2 = ph2 + f2 / 48000.0; if (ph2 >= 1.0) ph2 = ph2 - 1.0;
        end
    end
end

// ---------------- 测试台自己的 FIR + 环形缓冲 ----------------
integer xs [0:6];
integer mring [0:511];
integer mwp = 0, mph = 0, k, y;
always @(posedge clk) if (pv) begin
    for (k = 6; k > 0; k = k - 1) xs[k] = xs[k - 1];
    xs[0] = pcm;
    if (mph == 1) begin
        y = (16 * xs[3] + 9 * (xs[2] + xs[4]) - (xs[0] + xs[6]));
        y = (y >= 0) ? y / 32 : -((-y + 31) / 32);          // 算术右移 5
        if (y > 32767) y = 32767; if (y < -32768) y = -32768;
        mring[mwp] = y; mwp = (mwp + 1) % 512;
    end
    mph = 1 - mph;
end
initial for (k = 0; k < 7; k = k + 1) xs[k] = 0;

function [8:0] brev; input [8:0] v; integer q; for (q = 0; q < 9; q = q + 1) brev[q] = v[8 - q]; endfunction
function integer cosf; input integer n;   // round(32767·cos(2πn/512))，和 DUT 一样由 1/4 表取
    integer q, i;
    begin
        q = (n / 128) % 4; i = n % 128;
        case (q)
            0: cosf = $signed(spec_cos(i));
            1: cosf = -$signed(spec_cos(128 - i));
            2: cosf = -$signed(spec_cos(i));
            default: cosf = $signed(spec_cos(128 - i));
        endcase
    end
endfunction

integer errors = 0;
task check(input ok, input [1023:0] what);
    begin if (ok) $display("  ok   %0s", what); else begin $display("  FAIL %0s", what); errors = errors + 1; end end
endtask

// ---------------- P1 / P2：LOAD 开始和结束时抓 ----------------
integer snap_ring [0:511];
integer xin [0:511];
integer rp0, bad1 = 0, bad2 = 0, nload = 0, w, e, sh;
reg     ld_q = 0, fft_q = 0, fft_q2 = 0;
real    cre [0:511];
real    dre, dim_, er, maxerr, peak;
integer kk, nn, idx;
reg     do_dft = 0;
real    fft_maxerr = 0.0, fft_peak = 0.0;
always @(posedge clk) begin
    ld_q <= (dut.st == 3'd1);
    fft_q <= (dut.st == 3'd2);
    fft_q2 <= fft_q;
    if (dut.st == 3'd1 && !ld_q) begin                     // LOAD 刚开始：rp 已锁存
        rp0 = dut.rp;
        for (k = 0; k < 512; k = k + 1) snap_ring[k] = mring[(rp0 + k) % 512];
        for (k = 0; k < 512; k = k + 1) if ($signed(dut.ring[(rp0 + k) % 512]) !== snap_ring[k]) bad1 = bad1 + 1;
    end
    if (dut.st == 3'd2 && fft_q && !fft_q2) begin          // FFT 第 2 拍：LOAD 最后一个点已写进，工作 RAM 是加窗后的输入
        nload = nload + 1;
        for (k = 0; k < 512; k = k + 1) begin
            w = (32768 - cosf(k)) / 2;
            e = snap_ring[k] * w;
            e = (e >= 0) ? e / 16384 : -((-e + 16383) / 16384);
            xin[k] = $signed(dut.wre[brev(k)]);
            if (xin[k] !== e || $signed(dut.wim[brev(k)]) !== 0) begin
                if (bad2 < 3) $display("    P2 n=%0d ring=%0d w=%0d want %0d got %0d im %0d", k, snap_ring[k], w, e, xin[k], $signed(dut.wim[brev(k)]));
                bad2 = bad2 + 1;
            end
        end
    end
    if (dut.st == 3'd3 && fft_q && do_dft) begin           // FFT 刚完：和 DFT 比
        maxerr = 0.0; peak = 0.0;
        for (kk = 0; kk < 256; kk = kk + 1) begin
            dre = 0.0; dim_ = 0.0;
            for (nn = 0; nn < 512; nn = nn + 1) begin
                idx = (kk * nn) % 512;
                dre = dre + xin[nn] * cre[idx];
                dim_ = dim_ - xin[nn] * cre[(idx + 384) % 512];   // sin(θ) = cos(θ - π/2)
            end
            dre = dre / 512.0; dim_ = dim_ / 512.0;
            er = $signed(dut.wre[kk]) - dre; if (er < 0) er = -er; if (er > maxerr) maxerr = er;
            er = $signed(dut.wim[kk]) - dim_; if (er < 0) er = -er; if (er > maxerr) maxerr = er;
            if (dre * dre + dim_ * dim_ > peak * peak) peak = $sqrt(dre * dre + dim_ * dim_);
        end
        fft_maxerr = maxerr; fft_peak = peak;
        do_dft = 0;
    end
end
initial for (k = 0; k < 512; k = k + 1) cre[k] = $cos(6.283185307 * k / 512.0);

// ---------------- P6：显示高度模型（每帧 frame_start 前抓 stg，之后比）----------------
integer mh [0:31], mc [0:31], ml [0:31], st6 [0:31];
integer bad6 = 0, nf6 = 0, t, nh, dd;
initial for (k = 0; k < 32; k = k + 1) begin mh[k] = 0; mc[k] = 0; ml[k] = 0; end
always @(posedge clk) begin
    if (fcnt == FRAME - 1 && rst_n)                          // 下一拍 frame_start：这一刻的 stg 就是要合进去的
        for (k = 0; k < 32; k = k + 1) st6[k] = dut.stg[k];
    if (fcnt == 300 && nframe > 0 && dut.have && st6[0] !== 32'bx) begin   // 合完了（96 拍）；DUT 第一次算完之前不合
        for (k = 0; k < 32; k = k + 1) begin
            t = st6[k];
            if (t >= mh[k]) nh = t;
            else begin dd = (mh[k] - t) / 8; nh = mh[k] - ((dd == 0) ? 1 : dd); end
            mh[k] = nh;
            if (nh >= mc[k]) begin mc[k] = nh; ml[k] = 30; end
            else if (ml[k] != 0) ml[k] = ml[k] - 1;
            else if (mc[k] != 0) mc[k] = mc[k] - 1;
            if (dut.hd[k] !== mh[k] || dut.cp[k] !== mc[k] || dut.hl[k] !== ml[k]) begin
                if (bad6 < 3) $display("    P6 f%0d bar %0d stg %0d hd %0d/%0d cp %0d/%0d hl %0d/%0d", nf6, k, t, dut.hd[k], mh[k], dut.cp[k], mc[k], dut.hl[k], ml[k]);
                bad6 = bad6 + 1;
            end
        end
        nf6 = nf6 + 1;
    end
end

// ---------------- 工具 ----------------
integer bmax, hmax, i;
task frames(input integer m); integer q; begin for (q = 0; q < m; q = q + 1) begin @(posedge clk); while (!fs) @(posedge clk); end end endtask
task wait_mag_done; begin @(posedge clk); while (dut.st != 3'd4 && !(dut.st == 3'd0 && !dut.go)) @(posedge clk); @(posedge clk); end endtask
function integer bar_of; input integer bin; integer q; begin bar_of = -1; for (q = 0; q < 32; q = q + 1) if (bin >= spec_edge(q) && bin < spec_edge(q + 1)) bar_of = q; end endfunction
task find_max; begin bmax = 0; hmax = 0; for (i = 0; i < 32; i = i + 1) if ($signed({1'b0, dut.stg[i]}) > hmax) begin hmax = dut.stg[i]; bmax = i; end end endtask
task tone_check(input real f, input [255:0] name);
    integer want, far_ok;
    begin
        f1 = f; a1 = 30000; a2 = 0;
        frames(3);                                            // 缓冲里全是新信号
        do_dft = 1;
        frames(1); wait_mag_done;
        find_max;
        want = bar_of($rtoi(f / 46.875 + 0.5));
        far_ok = 1;
        for (i = 0; i < 32; i = i + 1) if ((i - bmax > 3 || bmax - i > 3) && dut.stg[i] > hmax - 24) far_ok = 0;
        check(bmax == want && hmax >= 44 && hmax <= 56 && far_ok,
              {name, ": peak bar = expected, height 44~56, bars 4+ away >= 24 px (36 dB) lower"});
        $display("         最高柱 %0d（期望 %0d）高度 %0d；FFT 对 DFT 最大误差 %0.2f（峰值 %0.0f）", bmax, want, hmax, fft_maxerr, fft_peak);
        check(fft_maxerr <= 16.0 && fft_peak > 10000.0, {name, ": FFT matches float DFT / 512 within 16 LSB"});
    end
endtask

integer b1, b2, ok5, cap0, hold_n, fall_n, z;
initial begin
    #200 rst_n = 1'b1;
    frames(4);
    tone_check(1000.0, "P4 1 kHz");
    tone_check(5000.0, "P4 5 kHz");
    // P5 双音
    f1 = 300.0; a1 = 16000; f2 = 3000.0; a2 = 16000;
    frames(3); do_dft = 1; frames(1); wait_mag_done;
    b1 = bar_of($rtoi(300.0 / 46.875 + 0.5)); b2 = bar_of($rtoi(3000.0 / 46.875 + 0.5));
    ok5 = (dut.stg[b1] >= 40) && (dut.stg[b2] >= 40);
    for (i = 0; i < 32; i = i + 1) if ((i < b1 - 1 || (i > b1 + 1 && i < b2 - 1) || i > b2 + 1) && (dut.stg[i] >= dut.stg[b1] || dut.stg[i] >= dut.stg[b2])) ok5 = 0;
    check(ok5, "P5 300 Hz + 3 kHz: both bars are local peaks");
    $display("         柱 %0d 高 %0d，柱 %0d 高 %0d；FFT 最大误差 %0.2f", b1, dut.stg[b1], b2, dut.stg[b2], fft_maxerr);
    check(fft_maxerr <= 16.0, "P5 FFT matches float DFT / 512 within 16 LSB");
    // P6 静音：柱子慢慢落到 0，顶帽先停 30 帧
    a1 = 0; a2 = 0;
    frames(3);
    cap0 = dut.cp[b2]; hold_n = 0; fall_n = 0;
    for (z = 0; z < 60; z = z + 1) begin
        frames(1); repeat (400) @(posedge clk);
        if (dut.cp[b2] == cap0) hold_n = hold_n + 1; else fall_n = fall_n + 1;
    end
    check(dut.hd[b2] == 0 && dut.stg[b2] == 0, "P6 silence: bars fall to 0");
    check(hold_n >= 25 && hold_n <= 31 && dut.cp[b2] < cap0, "P6 cap holds ~30 frames, then falls");
    $display("         顶帽停 %0d 帧后开始落", hold_n);
    check(bad1 == 0 && nload >= 8, "P1 decimating FIR + ring buffer bit-exact");
    check(bad2 == 0, "P2 Hann window x2, bit-reversed into work RAM, bit-exact");
    check(bad6 == 0 && nf6 >= 60, "P6 display heights / caps / hold follow the IIR + cap model every frame");
    // 读口
    rb = 5'd7; @(posedge clk); @(posedge clk);
    check(rh == dut.hd[7] && rc == dut.cp[7], "read port returns bar height / cap one clock later");
    $display("RESULT: %0s（%0d 个失败）", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
end
initial begin #2_000_000_000; $display("RESULT: FAIL（超时）"); $finish; end
endmodule
