`timescale 1ns/1ps
// R8-2 色彩（饱和度）自检：brightness_contrast_adjust 单独跑，随机像素 × 亮度 / 对比度 / 4 档色彩，
// 测试台按同样的公式独立算（亮度 ×(b+1)/256、对比度 (x-128)·c/128+128、Y = (77R+150G+29B+128)/256、
// 黑白 Y / 淡 Y+d/2 / 标准 C / 鲜艳 C+d/2，截 0~255），逐位比对；延迟 3 拍、out_de 跟着。
//   S1 标准档 + 亮度 255 / 对比度 128 时逐位直通（主回归整帧比对依赖这一条）
//   S2 4 档 × 3 组亮度 / 对比度，各 20000 个随机像素逐位相同
//   S3 黑白档 R = G = B；灰阶输入在任何档都不变
// 运行（仓库根目录）：bash sim/run_bc_sat.sh
module tb_bc_sat;
reg clk = 1'b0; always #20 clk = ~clk;
reg rst_n = 1'b0;
reg        de = 1'b0;
reg [23:0] rgb = 24'd0;
reg [7:0]  bri = 8'd255, con = 8'd128;
reg [1:0]  sat = 2'd2;
wire       ode;
wire [23:0] orgb;
brightness_contrast_adjust dut (.clk(clk), .rst_n(rst_n), .in_de(de), .rgb_in(rgb), .brightness(bri), .contrast(con),
                                .saturation(sat), .out_de(ode), .rgb_out(orgb));

function integer clip; input integer v; clip = (v < 0) ? 0 : (v > 255) ? 255 : v; endfunction
function integer asr; input integer v, n; asr = (v >= 0) ? (v >> n) : -((-v + (1 << n) - 1) >> n); endfunction
function [23:0] model; input [23:0] c; input integer b, k, m;
    integer ch [0:2], q, x, y, d, o;
    begin
        for (q = 0; q < 3; q = q + 1) begin
            x = c[23 - 8 * q -: 8];
            x = ((x * (b + 1)) >> 8) & 255;
            x = clip(asr((x - 128) * k, 7) + 128);
            ch[q] = x;
        end
        y = (77 * ch[0] + 150 * ch[1] + 29 * ch[2] + 128) >> 8;
        for (q = 0; q < 3; q = q + 1) begin
            d = ch[q] - y;
            case (m)
                0: o = y;
                1: o = y + asr(d, 1);
                2: o = ch[q];
                default: o = ch[q] + asr(d, 1);
            endcase
            ch[q] = clip(o);
        end
        model = {ch[0][7:0], ch[1][7:0], ch[2][7:0]};
    end
endfunction

integer errors = 0;
task check(input ok, input [1023:0] what);
    begin if (ok) $display("  ok   %0s", what); else begin $display("  FAIL %0s", what); errors = errors + 1; end end
endtask

// 输入流水：记下 3 拍前的输入
reg [23:0] h0, h1, h2;
reg        d0, d1, d2;
always @(posedge clk) begin h0 <= rgb; h1 <= h0; h2 <= h1; d0 <= de; d1 <= d0; d2 <= d1; end
integer bad, bad_de, ngray, n, i, m, cfg;
reg [23:0] e;
reg        gray_chk;
task run(input integer m_, input integer b_, input integer k_, input integer cnt);
    begin
        sat = m_; bri = b_; con = k_;
        bad = 0; bad_de = 0;
        for (n = 0; n < cnt; n = n + 1) begin
            @(negedge clk);
            rgb = $random; de = ($random & 7) != 0;
            if (n >= 4) begin
                e = model(h2, b_, k_, m_);
                if (orgb !== e) begin
                    if (bad < 3) $display("    m=%0d b=%0d c=%0d in %h -> %h，期望 %h", m_, b_, k_, h2, orgb, e);
                    bad = bad + 1;
                end
                if (ode !== d2) bad_de = bad_de + 1;
            end
        end
    end
endtask
initial begin
    #100 rst_n = 1'b1;
    run(2, 255, 128, 20000);
    check(bad == 0 && bad_de == 0, "S1 standard + brightness 255 / contrast 128: model");
    // 直通：输出 = 3 拍前输入
    bad = 0;
    for (n = 0; n < 5000; n = n + 1) begin @(negedge clk); rgb = $random; if (n >= 4 && orgb !== h2) bad = bad + 1; end
    check(bad == 0, "S1 standard + 255 / 128 is a bit-exact 3-cycle passthrough");
    for (cfg = 0; cfg < 3; cfg = cfg + 1)
        for (m = 0; m < 4; m = m + 1) begin
            case (cfg)
                0: run(m, 255, 128, 20000);
                1: run(m, 128, 192, 20000);
                default: run(m, 192, 64, 20000);
            endcase
            check(bad == 0 && bad_de == 0, cfg == 0 ? (m == 0 ? "S2 grey (b255 c128) bit-exact vs model" : m == 1 ? "S2 pale (b255 c128) bit-exact vs model" :
                                                       m == 2 ? "S2 standard (b255 c128) bit-exact vs model" : "S2 vivid (b255 c128) bit-exact vs model") :
                                            cfg == 1 ? "S2 4 modes x (b128 c192) bit-exact vs model" : "S2 4 modes x (b192 c64) bit-exact vs model");
        end
    // S3：黑白 R = G = B；灰阶输入任何档不变
    sat = 2'd0; bri = 8'd255; con = 8'd128; bad = 0;
    for (n = 0; n < 5000; n = n + 1) begin
        @(negedge clk); rgb = $random;
        if (n >= 4 && !(orgb[23:16] == orgb[15:8] && orgb[15:8] == orgb[7:0])) bad = bad + 1;
    end
    check(bad == 0, "S3 grey mode: R = G = B");
    bad = 0;
    for (m = 0; m < 4; m = m + 1) begin
        sat = m;
        for (n = 0; n < 300; n = n + 1) begin
            @(negedge clk); i = n % 256; rgb = {i[7:0], i[7:0], i[7:0]};
            if (n >= 4 && orgb !== h2) bad = bad + 1;
        end
    end
    check(bad == 0, "S3 grey input unchanged in every mode");
    $display("RESULT: %0s（%0d 个失败）", errors == 0 ? "PASS" : "FAIL", errors);
    $finish;
end
endmodule
