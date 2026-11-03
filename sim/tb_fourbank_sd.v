`timescale 1ns/1ps
// tb_fourbank 用的 SD 卡模型：与 sim/tb_fat32.v 相同的 MBR + FAT32 小卷（连续 / 交错碎片 / 倒序簇链），
// 只是像素内容改成每个像素都不同，便于检查四 bank 地址、上下翻转和整帧切换。
// ---------------- SD 卡行为模型（替换 sd_card_top，接口一致）----------------
module sd_card_top(
    input             clk,
    input             rst,
    output            SD_nCS,
    output            SD_DCLK,
    output            SD_MOSI,
    input             SD_MISO,
    output reg        sd_init_done,
    input             sd_sec_read,
    input  [31:0]     sd_sec_read_addr,
    output reg [7:0]  sd_sec_read_data,
    output reg        sd_sec_read_data_valid,
    output            sd_sec_read_end,
    input             sd_sec_write,
    input  [31:0]     sd_sec_write_addr,
    input  [7:0]      sd_sec_write_data,
    output            sd_sec_write_data_req,
    output            sd_sec_write_end,
    output     [1:0]  dbg_stage,
    output     [7:0]  crc_err_cnt,
    output     [7:0]  rd_retry_cnt,
    output            blk_crc_err
);
assign dbg_stage = 2'd0;
assign crc_err_cnt = 8'd0;
assign rd_retry_cnt = 8'd0;
assign blk_crc_err = 1'b0;
assign {SD_nCS, SD_DCLK, SD_MOSI} = 3'b100;
// R8-4b：写扇区。sd_sec_write 在空闲时优先于读（和 sd_card_sec_read_write 一样）；每个字节先给一拍 data_req，下一拍采数据
assign sd_sec_write_data_req = (st == 3'd4);
assign sd_sec_write_end      = (st == 3'd6);
reg  [7:0]  wsec [0:511];          // 最近一次写入的扇区
reg  [31:0] wsec_lba;
integer     n_writes = 0;
integer     n_bad_wr = 0;          // 写在 SAVE.BIN 以外扇区的次数

localparam integer W = 64, H = 48;
localparam integer FILE_LEN = 54 + W * H * 3;     // 9270 字节 = 19 扇区 = 5 簇
localparam integer PART = 64, SPC = 4, RSV = 4, FATSZ = 8;
localparam integer FAT0 = PART + RSV;             // 68
localparam integer DATA = PART + RSV + 2 * FATSZ; // 84
localparam integer SAVE_CL = 80;                  // R8-4a：SAVE.BIN 所在簇（变体 SAVE / SAVEBAD 才进目录）
`ifdef SAVE
`define SAVE_ANY
`endif
`ifdef SAVEBAD
`define SAVE_ANY
`endif

// 每张图的簇链（5 簇）
function integer chain;
    input integer pic; input integer pos;
    begin
        chain = 0;
        case (pic)
            1: chain = 3 + pos;                                         // 3 4 5 6 7
            2: case (pos) 0: chain = 10; 1: chain = 20; 2: chain = 11; 3: chain = 21; default: chain = 12; endcase
            3: chain = 17 - pos;                                        // 17 16 15 14 13
            4: case (pos) 0: chain = 40; 1: chain = 8;  2: chain = 41; 3: chain = 9;  default: chain = 42; endcase
            5: case (pos) 0: chain = 60; 1: chain = 22; 2: chain = 61; 3: chain = 23; default: chain = 62; endcase
            6: case (pos) 0: chain = 70; 1: chain = 24; 2: chain = 71; 3: chain = 25; default: chain = 72; endcase   // R8-1a PIC6 急救图
            default: chain = 0;
        endcase
    end
endfunction

// FAT[c]
function integer fat_next;
    input integer c;
    integer p, q;
    begin
        fat_next = 0;
        if (c == 0) fat_next = 32'h0ffffff8;
        else if (c == 1 || c == 2 || c == 30) fat_next = 32'h0fffffff;   // 保留 / 根目录 / README
        for (p = 1; p <= 6; p = p + 1)
            for (q = 0; q < 5; q = q + 1)
                if (chain(p, q) == c) fat_next = (q == 4) ? 32'h0fffffff : chain(p, q + 1);
    end
endfunction

function [7:0] b32;
    input [31:0] v; input integer i;
    begin b32 = v >> (8 * i); end
endfunction

// 目录项（32 字节）：name 11 字节 + attr + cluster + size
function [7:0] dirent;
    input integer e; input integer i;
    reg [87:0] nm; reg [7:0] attr; reg [31:0] cl, sz;
    begin
        nm = "           "; attr = 8'h00; cl = 0; sz = 0;
        case (e)
            0: begin nm = "TFCARD     "; attr = 8'h08; end
            1: begin nm = {8'he5, "IC9    BMP"}; attr = 8'h20; cl = 50; sz = FILE_LEN; end   // 已删除
            2: begin nm = {8'h41, "p", 8'h00, "i", 8'h00, "c", 8'h00, "x", 8'h00, "x", 8'h00}; attr = 8'h0f; end
            3: begin nm = "README  TXT"; attr = 8'h20; cl = 30; sz = 100; end
            4: begin nm = "PIC2    BMP"; attr = 8'h20; cl = chain(2, 0); sz = FILE_LEN; end
            5: begin nm = "PIC1    BMP"; attr = 8'h20; cl = chain(1, 0); sz = FILE_LEN; end
            6: begin nm = "PIC4    BMP"; attr = 8'h20; cl = chain(4, 0); sz = FILE_LEN; end
`ifndef MISSING3
            7: begin nm = "PIC3    BMP"; attr = 8'h20; cl = chain(3, 0); sz = FILE_LEN; end
`endif
            8: begin nm = "PIC5    BMP"; attr = 8'h20; cl = chain(5, 0); sz = FILE_LEN; end
`ifndef MISSING6
            9: begin nm = "PIC6    BMP"; attr = 8'h20; cl = chain(6, 0); sz = FILE_LEN; end   // R8-1a 急救图
`endif
`ifdef SAVE_ANY
            10: begin nm = "SAVE    BIN"; attr = 8'h20; cl = SAVE_CL; sz = 512; end          // R8-4a 存档
`endif
            default: nm = {8'h00, 80'd0};
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

function [7:0] file_byte;
    input integer pic; input integer off;
    integer k, fr;
    begin
        file_byte = 8'h00;
        if      (off == 0) file_byte = "B";
        else if (off == 1) file_byte = "M";
        else if (off >= 2  && off < 6)  file_byte = b32(FILE_LEN, off - 2);
        else if (off >= 10 && off < 14) file_byte = b32(54, off - 10);
        else if (off >= 14 && off < 18) file_byte = b32(40, off - 14);
        else if (off >= 18 && off < 22) file_byte = b32(W, off - 18);
`ifdef TOPDOWN
        // R8-5b：PIC2 存成负高度 BMP（自上而下），行顺序反过来；loader 不翻转后显示结果和其它变体完全一样
        else if (off >= 22 && off < 26) file_byte = b32((pic == 2) ? -H : H, off - 22);
`else
        else if (off >= 22 && off < 26) file_byte = b32(H, off - 22);
`endif
        else if (off == 26) file_byte = 8'd1;
        else if (off == 28) file_byte = 8'd24;
        else if (off >= 54 && off < FILE_LEN) begin
            // 第8课：每个像素都不同。像素按 B、G、R 存：B = {图号, 文件内行号}，G = 列号，R = 0xA0 + 图号
            k  = (off - 54) / 3;
            fr = k / W;
`ifdef TOPDOWN
            if (pic == 2) fr = H - 1 - fr;
`endif
            case ((off - 54) % 3)
                0: file_byte = {pic[1:0], fr[5:0]};
                1: file_byte = k % W;
                default: file_byte = 8'ha0 + pic;
            endcase
        end
    end
endfunction

// R8-4a：SAVE.BIN 内容（格式见 doc/R8-4_方案.md 第 3 节）
function [7:0] save_byte;
    input integer i;
    reg [7:0] x; integer k;
    reg [255:0] img;
    begin
        // 字节 0 在最低位
        img = 256'd0;
        img[31:0]    = {"S", "R", "P", "C"};
        img[39:32]   = 8'd1;
        img[47:40]   = 8'd128;      // 亮度
        img[55:48]   = 8'd192;      // 对比度
        img[63:56]   = 8'd3;        // 色彩 鲜艳
        img[71:64]   = 8'd5;        // 字幕颜色
        img[79:72]   = 8'd0;        // 间隔 1 秒
        img[87:80]   = 8'h0b;       // 状态栏 / 字幕 / 镜像 开，轮播关
        img[95:88]   = 8'd2;        // 频谱
        img[103:96]  = 8'd5;        // 转场效果
        img[111:104] = 8'd6;        // 转场速度
        img[119:112] = 8'd4;        // 音量
        img[127:120] = 8'd2;        // 当前图 bank2
        img[143:128] = 16'h0532;    // R8-4b 上次急救 05:32
        img[159:144] = 16'h0312;    //   按压 312 次
        img[199:192] = 8'd1;        //   累计 1 次
        x = 8'd0;
        for (k = 0; k < 31; k = k + 1) x = x ^ img[k*8 +: 8];
`ifdef SAVEBAD
        x = ~x;
`endif
        img[255:248] = x;
        save_byte = (i < 32) ? img[i*8 +: 8] : 8'h00;
    end
endfunction

function [7:0] disk_byte;
    input integer s; input integer i;
    integer c, si, p, q;
    begin
        disk_byte = 8'ha5;                                   // 默认：垃圾
`ifndef NOFAT
        if (s == 0) begin                                    // MBR
            disk_byte = 8'h00;
            if (i == 450) disk_byte = 8'h0c;
            else if (i >= 454 && i < 458) disk_byte = b32(PART, i - 454);
            else if (i == 510) disk_byte = 8'h55;
            else if (i == 511) disk_byte = 8'haa;
        end else
`endif
        if (s == PART) begin                                 // 引导扇区 / BPB
            disk_byte = 8'h00;
            case (i)
                0: disk_byte = 8'heb;  1: disk_byte = 8'h58;  2: disk_byte = 8'h90;
                11: disk_byte = 8'h00; 12: disk_byte = 8'h02;          // 512 字节/扇区
                13: disk_byte = SPC;
                14: disk_byte = RSV;
                16: disk_byte = 8'd2;                                   // 2 个 FAT
                32: disk_byte = 8'h00; 33: disk_byte = 8'h10;          // 总扇区 4096
                36: disk_byte = FATSZ;
                44: disk_byte = 8'd2;                                   // 根目录簇 2
                510: disk_byte = 8'h55; 511: disk_byte = 8'haa;
                default: ;
            endcase
        end else if (s >= FAT0 && s < FAT0 + 2 * FATSZ) begin  // FAT1 / FAT2
            disk_byte = b32(fat_next(((s - FAT0) % FATSZ) * 128 + i / 4), i % 4);
        end else if (s >= DATA) begin
            c  = (s - DATA) / SPC + 2;
            si = (s - DATA) % SPC;
            if (c == 2) begin
                disk_byte = (si == 0) ? dirent(i / 32, i % 32) : 8'h00;
            end else if (c == SAVE_CL) begin
                disk_byte = (si == 0) ? save_byte(i) : 8'h00;
            end else begin
                for (p = 1; p <= 6; p = p + 1)
                    for (q = 0; q < 5; q = q + 1)
                        if (chain(p, q) == c) disk_byte = file_byte(p, (q * SPC + si) * 512 + i);
            end
        end
    end
endfunction

reg [2:0]  st;
reg [9:0]  cnt;
reg [31:0] sec;
reg [7:0]  init_cnt;
integer    n_reads = 0;
assign sd_sec_read_end = (st == 3'd3);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        init_cnt <= 0; sd_init_done <= 1'b0; st <= 0; cnt <= 0; sec <= 0;
        sd_sec_read_data <= 0; sd_sec_read_data_valid <= 1'b0;
    end else begin
        // R4：tb_fourbank.card_in = 0 时模拟没插卡 / 拔卡：初始化不完成，正在进行的读一直不结束
        if (!tb_fourbank.card_in) init_cnt <= 8'd0;
        else if (init_cnt < 8'd200) init_cnt <= init_cnt + 1'b1; else sd_init_done <= 1'b1;
        sd_sec_read_data_valid <= 1'b0;
        if (tb_fourbank.card_in) case (st)
            3'd0: if (sd_sec_write) begin
                      wsec_lba <= sd_sec_write_addr; cnt <= 0; st <= 3'd4; n_writes = n_writes + 1;
                      if (sd_sec_write_addr != DATA + (SAVE_CL - 2) * SPC) n_bad_wr = n_bad_wr + 1;
                  end else if (sd_sec_read) begin sec <= sd_sec_read_addr; cnt <= 0; st <= 3'd1; n_reads = n_reads + 1; end
            3'd4: st <= 3'd7;
            3'd7: begin
                      wsec[cnt] <= sd_sec_write_data;
                      if (cnt == 10'd511) st <= 3'd6; else begin cnt <= cnt + 1'b1; st <= 3'd4; end
                  end
            3'd6: begin
                      st <= 3'd0;
                      $display("  [t=%0d us] 写扇区 #%0d lba=%0d bri=%0d flags=%h pic=%0d rec=%h%h:%h%h n=%0d cpr_st=%0d cur=%0d",
                               $time / 1000, n_writes, wsec_lba, wsec[5], wsec[10], wsec[15], wsec[17], wsec[16], wsec[19], wsec[18],
                               wsec[24], tb_fourbank.cpr_state, tb_fourbank.active_index);
                  end
            3'd1: if (cnt == 10'd19) begin cnt <= 0; st <= 3'd2; end else cnt <= cnt + 1'b1;
            3'd2: begin
                      sd_sec_read_data       <= disk_byte(sec, cnt);
                      sd_sec_read_data_valid <= 1'b1;
                      if (cnt == 10'd511) st <= 3'd5; else cnt <= cnt + 1'b1;
                  end
            3'd5: st <= 3'd3;
            3'd3: st <= 3'd0;
            default: st <= 3'd0;
        endcase
    end
end
endmodule
