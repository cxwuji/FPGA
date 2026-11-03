`timescale 1ns/1ps
// R8-5a：bmp_read + bmp_scaler 逐像素比对（期望值由 tools/scaler_ref.py 生成）
//   vvp sim/tb_bmp_scaler.vvp +CASE=sim/scaler_cases/p1920x1080
// 文件流模型：字节每 2 拍一个（同扇区重放缓冲），每 512 字节停 GAP 拍（比真卡短，输入更密、更严）；
// loader 反压用伪随机 ready（约 1/4 时间不收）。
module tb_bmp_scaler;
localparam integer MAXB = 7_000_000;
localparam integer NPIX = 640 * 480;
localparam integer GAP  = 120;

reg clk = 0;
always #5 clk = ~clk;
reg rst = 1;

reg [7:0]  fmem [0:MAXB-1];
reg [23:0] emem [0:NPIX-1];
integer    flen;

reg         load_start = 0;
wire        write_req;
wire        file_start, file_abort;
reg         file_ready = 1;
reg         file_valid = 0;
reg  [7:0]  file_byte = 0;
reg         file_done = 0;
wire        wr_en;
wire [23:0] wr_data;
wire [2:0]  bmp_error;
wire        load_error;
wire        ready;
wire        src_hold;
reg         pix_ready = 1;

bmp_read dut (
    .clk(clk), .rst(rst), .ready(ready),
    .load_start(load_start), .load_abort(1'b0), .sd_init_done(1'b1), .state_code(),
    .bmp_width(16'd640), .bmp_height(16'd480), .pix_ready(pix_ready), .src_hold(src_hold), .top_down(),
    .write_req(write_req), .write_req_ack(write_req),
    .file_start(file_start), .file_abort(file_abort), .file_ready(file_ready),
    .file_valid(file_valid), .file_byte(file_byte), .file_done(file_done), .file_fs_error(8'd0),
    .bmp_data_wr_en(wr_en), .bmp_data(wr_data), .dbg_state(),
    .bmp_error(bmp_error), .load_error(load_error)
);

// ---------- 文件流模型（src_hold 时暂停；和真链路一样，出字节后还要过一级寄存器）----------
integer pos;
integer ph;          // 0 空闲 1 发数据
integer gapc;
reg     s1_v = 0, s1_d = 0;
reg [7:0] s1_b = 0;
always @(posedge clk) begin
    s1_v <= 0;
    s1_d <= 0;
    file_valid <= s1_v;
    file_byte  <= s1_b;
    file_done  <= s1_d;
    if (file_abort) begin
        ph <= 0;
    end else if (file_start) begin
        ph <= 1; pos <= 0; gapc <= 30;
    end else if (ph == 1 && !src_hold) begin
        if (gapc > 0) begin
            gapc <= gapc - 1;
        end else if (pos == flen) begin
            s1_d <= 1; ph <= 0;
        end else begin
            s1_v <= 1;
            s1_b <= fmem[pos];
            pos  <= pos + 1;
            gapc <= ((pos + 1) % 512 == 0) ? GAP : 1;
        end
    end
end

// ---------- loader 反压 ----------
reg [15:0] lfsr = 16'hACE1;
always @(posedge clk) begin
    lfsr      <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    pix_ready <= (lfsr[1:0] != 2'b00);
end

// ---------- 比对 ----------
integer nout = 0, nerr = 0;
always @(posedge clk) begin
    if (wr_en) begin
        if (nout < NPIX && wr_data !== emem[nout]) begin
            if (nerr < 10)
                $display("  MISMATCH px %0d (row %0d col %0d): got %06h exp %06h", nout, nout / 640, nout % 640, wr_data, emem[nout]);
            nerr = nerr + 1;
        end
        nout = nout + 1;
    end
end

reg [1023:0] cs;
reg [1023:0] fn;
integer i, t0;
initial begin
    if (!$value$plusargs("CASE=%s", cs)) begin
        $display("need +CASE=..."); $finish;
    end
    for (i = 0; i < MAXB; i = i + 1) fmem[i] = 8'hxx;
    $sformat(fn, "%0s.hex", cs);
    $readmemh(fn, fmem);
    flen = 0;
    while (flen < MAXB && fmem[flen] !== 8'hxx) flen = flen + 1;
    $sformat(fn, "%0s.exp", cs);
    $readmemh(fn, emem);
    ph = 0;
    repeat (5) @(posedge clk);
    rst = 0;
    repeat (5) @(posedge clk);
    load_start = 1;
    @(posedge clk);
    load_start = 0;
    t0 = $time;
    // 等回到空闲
    repeat (50) @(posedge clk);
    while (!ready && ($time - t0) / 10 < 60_000_000) @(posedge clk);
    if (!ready)
        $display("  TIMEOUT: state=%0d pst=%0d sq_run=%0d sk=%0d sc=%0d rdy=%b src_rows=%0d file_end=%0d", dut.state, dut.u_scaler.pst,
                 dut.u_scaler.sq_run, dut.u_scaler.sk, dut.u_scaler.sc, dut.u_scaler.rdy, dut.src_rows, dut.file_end_seen);
    repeat (20) @(posedge clk);
    if (nout == NPIX && nerr == 0 && bmp_error == 0)
        $display("RESULT PASS %0s  (%0d bytes, %0d px, %0d cycles)", cs, flen, nout, ($time - t0) / 10);
    else
        $display("RESULT FAIL %0s  out=%0d err=%0d bmp_error=%0d overrun=%0d", cs, nout, nerr, bmp_error, dut.u_scaler.overrun);
    $finish;
end
endmodule
