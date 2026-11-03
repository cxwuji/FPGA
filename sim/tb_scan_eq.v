`timescale 1ns/1ps
// R9 时序改动回归：fat32_volume_scanner 新版（文件名逐字节匹配）和旧版（第 11 字节一拍比完）喂同一张卡，输出必须完全一样。
// 根目录放 MUSIC / GUIDE / SAVE / PIC1~6 和只差一个字母的干扰名、已删除项、长文件名项、只读属性项。
// 旧版由 sim/run_scan_eq.sh 从 git 取出改名为 fat32_volume_scanner_old。变体 VB：换一套目录（缺 MUSIC、GUIDE 太小、PIC6 超 16MB）。
module tb_scan_eq;

localparam integer PART = 64, SPC = 4, RSV = 4, FATSZ = 8;
localparam integer DATA = PART + RSV + 2 * FATSZ;

reg clk = 1'b0, rst_n = 1'b0, start = 1'b0;
always #5 clk = ~clk;

function [7:0] b32;
    input [31:0] v; input integer k;
    b32 = v[8 * k +: 8];
endfunction

function [7:0] dirent;
    input integer e; input integer i;
    reg [87:0] nm; reg [7:0] attr; reg [31:0] cl, sz;
    begin
        nm = {8'h00, 80'd0}; attr = 8'h20; cl = 100 + e; sz = 9270;
        case (e)
`ifndef VB
            0:  begin nm = "TFCARD     "; attr = 8'h08; end
            1:  begin nm = "MUSIC   WAV"; sz = 5000000; end
            2:  nm = "MUSIC   WAX";
            3:  begin nm = "GUIDE   WAV"; cl = 32'h0123_4567; sz = 21500000; end
            4:  nm = "GUIDF   WAV";
            5:  begin nm = "SAVE    BIN"; sz = 1536; end
            6:  nm = "SAVE    BIM";
            7:  nm = "PIC1    BMP";
            8:  nm = "PIC7    BMP";
            9:  nm = "PIC0    BMP";
            10: begin nm = "PIC3    BMP"; attr = 8'h21; end
            11: begin nm = "PIC6    BMP"; sz = 921654; end
            12: nm = "PIC2X   BMP";
            13: begin nm = {8'h41, "p", 8'h00, "i", 8'h00, "c", 8'h00, "x", 8'h00, "x", 8'h00}; attr = 8'h0f; end
            14: nm = {8'he5, "UIDE   WAV"};
            15: nm = "PIC4    BMP";
`else
            0:  nm = "PIC5    BMP";
            1:  nm = "PIC2    BMP";
            2:  begin nm = "GUIDE   WAV"; sz = 1000; end          // 太小，不算
            3:  nm = "PIC3    BMP";
            4:  begin nm = "SAVE    BIN"; sz = 600; end           // >= 512 但 < 1536
            5:  nm = "MUSI    WAV";
            6:  begin nm = "PIC6    BMP"; sz = 32'h0120_0000; end  // > 16MB
            7:  nm = "PIC1    BMP";
            8:  nm = "PIC4    BMP";
            9:  nm = "AUSIC   WAV";
            10: nm = "PIC4   BMP ";
            11: begin nm = "GUIDE   WAV"; cl = 32'h0fff_fff0; sz = 4096; end
            12: nm = "PIC1    BMP";                                // 重复：后一个覆盖
            13: begin nm = "SAVE    BIN"; sz = 600; end
            14: nm = "PIC     BMP";
            15: nm = "PIC5    BMQ";
`endif
            default: ;
        endcase
        dirent = 8'h00;
        if (i < 11)        dirent = nm[87 - 8 * i -: 8];
        else if (i == 11)  dirent = attr;
        else if (i == 20)  dirent = cl[23:16];
        else if (i == 21)  dirent = cl[31:24];
        else if (i == 26)  dirent = cl[7:0];
        else if (i == 27)  dirent = cl[15:8];
        else if (i >= 28)  dirent = b32(sz, i - 28);
    end
endfunction

function [7:0] disk_byte;
    input integer s; input integer i;
    begin
        disk_byte = 8'ha5;
        if (s == 0) begin
            disk_byte = 8'h00;
            if (i == 450) disk_byte = 8'h0c;
            else if (i >= 454 && i < 458) disk_byte = b32(PART, i - 454);
            else if (i == 510) disk_byte = 8'h55;
            else if (i == 511) disk_byte = 8'haa;
        end else if (s == PART) begin
            disk_byte = 8'h00;
            case (i)
                0: disk_byte = 8'heb;  1: disk_byte = 8'h58;  2: disk_byte = 8'h90;
                11: disk_byte = 8'h00; 12: disk_byte = 8'h02;
                13: disk_byte = SPC;
                14: disk_byte = RSV;
                16: disk_byte = 8'd2;
                32: disk_byte = 8'h00; 33: disk_byte = 8'h10;
                36: disk_byte = FATSZ;
                44: disk_byte = 8'd2;
                510: disk_byte = 8'h55; 511: disk_byte = 8'haa;
                default: ;
            endcase
        end else if (s == DATA) begin
            disk_byte = dirent(i / 32, i % 32);
        end
    end
endfunction

// 扇区模型：sector_req 后等几拍，每 2 拍出一个字节，最后 sector_done
reg        busy = 1'b0, sv = 1'b0, sdone = 1'b0;
reg [7:0]  sbyte = 8'd0;
reg [8:0]  sidx = 9'd0;
wire       req_n, req_o;
wire [31:0] lba_n, lba_o;
integer k;
// 两个 DUT 同步运行（旧版、新版状态机拍数一样），只用新版的请求驱动模型，另外检查两边请求一致
always @(posedge clk) begin
    if (req_n) begin
        busy <= 1'b1;
        repeat (5) @(posedge clk);
        for (k = 0; k < 512; k = k + 1) begin
            sv <= 1'b1; sbyte <= disk_byte(lba_n, k); sidx <= k;
            @(posedge clk); sv <= 1'b0;
            @(posedge clk);
        end
        sdone <= 1'b1; @(posedge clk); sdone <= 1'b0; busy <= 1'b0;
    end
end

`define SCAN_PORTS(sfx) \
    .clk(clk), .rst_n(rst_n), .scan_start(start), .scan_busy(), .scan_done(done_``sfx), .fs_error(err_``sfx), \
    .partition_lba(), .sectors_per_cluster(), .fat_start_lba(), .data_start_lba(), .max_cluster(), \
    .resource_valid(rv_``sfx), \
    .resource0_cluster(c_``sfx[0]), .resource1_cluster(c_``sfx[1]), .resource2_cluster(c_``sfx[2]), \
    .resource3_cluster(c_``sfx[3]), .resource4_cluster(c_``sfx[4]), .resource5_cluster(c_``sfx[5]), \
    .resource0_size(z_``sfx[0]), .resource1_size(z_``sfx[1]), .resource2_size(z_``sfx[2]), \
    .resource3_size(z_``sfx[3]), .resource4_size(z_``sfx[4]), .resource5_size(z_``sfx[5]), \
    .music_valid(mv_``sfx), .music_cluster(mc_``sfx), .music_size(ms_``sfx), \
    .save_valid(sav_``sfx), .save_cluster(sac_``sfx), .save_big(sab_``sfx), \
    .guide_valid(gv_``sfx), .guide_cluster(gc_``sfx), \
    .sector_req(req_``sfx), .sector_lba(lba_``sfx), .sector_busy(busy), .sector_valid(sv), \
    .sector_byte(sbyte), .sector_byte_index(sidx), .sector_done(sdone), .sector_error(8'd0)

wire        done_n, done_o, mv_n, mv_o, sav_n, sav_o, sab_n, sab_o, gv_n, gv_o;
wire [7:0]  err_n, err_o;
wire [5:0]  rv_n, rv_o;
wire [31:0] c_n [0:5], c_o [0:5], z_n [0:5], z_o [0:5];
wire [31:0] mc_n, mc_o, ms_n, ms_o;
wire [27:0] sac_n, sac_o, gc_n, gc_o;

fat32_volume_scanner     u_new (`SCAN_PORTS(n));
fat32_volume_scanner_old u_old (`SCAN_PORTS(o));

integer errs = 0, j;
always @(posedge clk) if (req_n !== req_o || (req_n && lba_n !== lba_o)) begin
    errs = errs + 1; $display("FAIL 扇区请求不一致 t=%0t", $time);
end

task chk; input ok; input [8*40-1:0] what;
    if (!ok) begin errs = errs + 1; $display("FAIL %0s", what); end
endtask

initial begin
    repeat (5) @(posedge clk); rst_n = 1'b1;
    repeat (5) @(posedge clk); start = 1'b1; @(posedge clk); start = 1'b0;
    wait (done_n); @(posedge clk);
    chk(done_o === 1'b0 || done_o === 1'b1, "done");
    chk(err_n === err_o, "fs_error");
    chk(rv_n === rv_o, "resource_valid");
    for (j = 0; j < 6; j = j + 1) begin
        chk(c_n[j] === c_o[j], "resource cluster");
        chk(z_n[j] === z_o[j], "resource size");
    end
    chk({mv_n, mc_n, ms_n} === {mv_o, mc_o, ms_o}, "music");
    chk({sav_n, sac_n, sab_n} === {sav_o, sac_o, sab_o}, "save");
    chk({gv_n, gc_n} === {gv_o, gc_o}, "guide");
    $display("新版：err=%h rv=%b music=%b/%0d/%0d save=%b/%0d/%b guide=%b/%h",
             err_n, rv_n, mv_n, mc_n, ms_n, sav_n, sac_n, sab_n, gv_n, gc_n);
    for (j = 0; j < 6; j = j + 1) $display("  PIC%0d cl=%0d size=%0d", j + 1, c_n[j], z_n[j]);
`ifndef VB
    chk(mv_n && mc_n == 101, "期望 MUSIC 在 101");
    chk(gv_n && gc_n == 28'h123_4567, "期望 GUIDE 簇 0x1234567");
    chk(sav_n && sac_n == 105 && sab_n, "期望 SAVE 105 big");
    chk(rv_n == 6'b101001, "期望 PIC1 4 6");
`else
    chk(!mv_n, "期望无 MUSIC");
    chk(gv_n && gc_n == 28'hfff_fff0, "期望 GUIDE 取后一个");
    chk(sav_n && sac_n == 113 && !sab_n, "期望 SAVE 取 113 非 big");
    chk(rv_n == 6'b111111 && z_n[5] == 32'hffffff && c_n[0] == 112, "期望 PIC 全 / PIC6 截断 / PIC1 取后一个");
`endif
    if (errs == 0) $display("PASS scan_eq"); else $display("FAIL scan_eq %0d 处", errs);
    $finish;
end

initial begin #20_000_000; $display("FAIL 超时"); $finish; end
endmodule
