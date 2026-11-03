`timescale 1ns/1ps

module fat32_volume_scanner (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scan_start,
    output wire        scan_busy,
    output reg         scan_done,
    output reg  [7:0]  fs_error,
    output reg  [31:0] partition_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [31:0] fat_start_lba,
    output reg  [31:0] data_start_lba,
    output reg  [31:0] max_cluster,
    output reg  [5:0]  resource_valid,     // R8-1a：bit0~4 = PIC1~5（轮播），bit5 = PIC6（急救专用图）；R11：轮播只用 PIC1~4，bit4 恒 0
    output reg  [31:0] resource0_cluster,
    output reg  [31:0] resource1_cluster,
    output reg  [31:0] resource2_cluster,
    output reg  [31:0] resource3_cluster,
    output reg  [31:0] resource4_cluster,
    output reg  [31:0] resource5_cluster,
    output reg  [31:0] resource0_size,
    output reg  [31:0] resource1_size,
    output reg  [31:0] resource2_size,
    output reg  [31:0] resource3_size,
    output reg  [31:0] resource4_size,
    output reg  [31:0] resource5_size,
    output reg         music_valid,        // 第11课：根目录有 MUSIC.WAV
    output reg  [31:0] music_cluster,
    output reg  [31:0] music_size,
    output reg         save_valid,         // R8-4a：根目录有 SAVE.BIN（大小 >= 512）
    output reg  [27:0] save_cluster,
    output reg         save_big,           // R9：SAVE.BIN >= 1536 字节（第 2、3 扇区放急救位置条）
    output reg         guide_valid,        // R9：根目录有 GUIDE.WAV（急救语音，>= 1024 字节）
    output reg  [27:0] guide_cluster,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);

    localparam ERR_NONE            = 8'h00;
    localparam ERR_SECTOR          = 8'h10;
    localparam ERR_BOOT_SIGNATURE  = 8'h20;
    localparam ERR_UNSUPPORTED_BPB = 8'h21;
    localparam ERR_RESOURCE_MISSING= 8'h22;

    localparam ST_IDLE       = 4'd0;
    localparam ST_READ0_REQ  = 4'd1;
    localparam ST_READ0_WAIT = 4'd2;
    localparam ST_BOOT_PARSE = 4'd3;
    localparam ST_BOOT_REQ   = 4'd4;
    localparam ST_BOOT_WAIT  = 4'd5;
    localparam ST_ROOT_REQ   = 4'd6;
    localparam ST_ROOT_WAIT  = 4'd7;
    localparam ST_DIR_SCAN   = 4'd8;
    localparam ST_FINISH     = 4'd9;
    localparam ST_BOOT_LAYOUT= 4'd10;
    localparam ST_BOOT_ROOT  = 4'd11;
    localparam ST_BOOT_CHECK = 4'd12;   // R7c-1 时序：先寄存 BPB 校验结果，下一拍再解析
    localparam ST_BOOT_SPAN  = 4'd13;   // R8-0a 时序：fat_span 改从已寄存的 BPB 字段算（原来扇区缓冲 -> 移位 -> 选择一拍，-0.07ns）
    localparam ST_BOOT_ROFF  = 4'd14;   // R8-0a 时序：根目录簇偏移先寄存，下一拍再加数据区起点（原来一拍减 + 移位 + 加，-0.33ns）
    localparam ST_BOOT_SHIFT = 4'd15;   // R8-5b 资源：两个按每簇扇区数的移位改成每拍移 1 位（原来两个 32 位桶形移位器，上电只用一次）

    reg [3:0] state;
    // R8-5a 资源：原来整扇区 512 字节存成寄存器（4096 个触发器 + 512 路写使能译码，sd_card_clk 拥塞的大头），
    // 解析只用到下面 30 个固定偏移的字节，收数据时按偏移直接存进对应寄存器，行为不变
    reg [7:0] sb0;
    reg [7:0] sb11;
    reg [7:0] sb12;
    reg [7:0] sb13;
    reg [7:0] sb14;
    reg [7:0] sb15;
    reg [7:0] sb16;
    reg [7:0] sb17;
    reg [7:0] sb18;
    reg [7:0] sb22;
    reg [7:0] sb23;
    reg [7:0] sb32;
    reg [7:0] sb33;
    reg [7:0] sb34;
    reg [7:0] sb35;
    reg [7:0] sb36;
    reg [7:0] sb37;
    reg [7:0] sb38;
    reg [7:0] sb39;
    reg [7:0] sb44;
    reg [7:0] sb45;
    reg [7:0] sb46;
    reg [7:0] sb47;
    reg [7:0] sb450;
    reg [7:0] sb454;
    reg [7:0] sb455;
    reg [7:0] sb456;
    reg [7:0] sb457;
    reg [7:0] sb510;
    reg [7:0] sb511;
    reg [4:0] directory_entry_index;
    reg [31:0] root_cluster;
    reg [31:0] total_sectors;
    reg [31:0] fat_sectors;
    reg [7:0] fat_count;
    reg [15:0] reserved_sectors;
    reg [31:0] root_lba;
    reg [31:0] data_sector_count;
    reg [31:0] fat_span;
    reg [31:0] root_off;                // R8-0a：(root_cluster - 2) << 每簇扇区数
    reg [2:0] sectors_per_cluster_shift;
    reg [2:0] sh_n;                     // R8-5b：还要移几位
    reg       bpb_bad;                  // R7c-1：BPB 不支持（ST_BOOT_CHECK 寄存）
    // R9 时序：文件名逐字节比较、累计到 4 个"仍匹配"标志（原来第 11 字节一拍比 11 字节 x 4 个名字，sd_card_clk -0.1~-1.7ns）
    reg       nm_pic, nm_mus, nm_sav, nm_gui;
    reg       dir_entry_match;
    reg       dir_music_match;
    reg       dir_save_match;           // R8-4a
    reg       dir_guide_match;          // R9
    reg [2:0] dir_resource_index;
    reg [15:0] dir_cluster_high;
    reg [15:0] dir_cluster_low;
    reg [31:0] dir_file_size;

    assign scan_busy = (state != ST_IDLE);

    function [7:0] sbyte;
        input integer offset;
        begin
            case (offset)
                0: sbyte = sb0;
                11: sbyte = sb11;
                12: sbyte = sb12;
                13: sbyte = sb13;
                14: sbyte = sb14;
                15: sbyte = sb15;
                16: sbyte = sb16;
                17: sbyte = sb17;
                18: sbyte = sb18;
                22: sbyte = sb22;
                23: sbyte = sb23;
                32: sbyte = sb32;
                33: sbyte = sb33;
                34: sbyte = sb34;
                35: sbyte = sb35;
                36: sbyte = sb36;
                37: sbyte = sb37;
                38: sbyte = sb38;
                39: sbyte = sb39;
                44: sbyte = sb44;
                45: sbyte = sb45;
                46: sbyte = sb46;
                47: sbyte = sb47;
                450: sbyte = sb450;
                454: sbyte = sb454;
                455: sbyte = sb455;
                456: sbyte = sb456;
                457: sbyte = sb457;
                510: sbyte = sb510;
                511: sbyte = sb511;
                default: sbyte = 8'h00;
            endcase
        end
    endfunction

    function [15:0] le16;
        input integer offset;
        begin
            le16 = {sbyte(offset+1), sbyte(offset)};
        end
    endfunction

    function [31:0] le32;
        input integer offset;
        begin
            le32 = {sbyte(offset+3), sbyte(offset+2),
                    sbyte(offset+1), sbyte(offset)};
        end
    endfunction

    function valid_spc;
        input [7:0] value;
        begin
            valid_spc = value != 0 && ((value & (value - 1'b1)) == 0);
        end
    endfunction

    function [2:0] spc_shift;
        input [7:0] value;
        begin
            case (value)
                8'd2:   spc_shift = 3'd1;
                8'd4:   spc_shift = 3'd2;
                8'd8:   spc_shift = 3'd3;
                8'd16:  spc_shift = 3'd4;
                8'd32:  spc_shift = 3'd5;
                8'd64:  spc_shift = 3'd6;
                8'd128: spc_shift = 3'd7;
                default: spc_shift = 3'd0;
            endcase
        end
    endfunction

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    // 扇区字节捕获：不带复位（和原来的扇区缓冲一样）
    always @(posedge clk) begin
        if (sector_valid && state != ST_ROOT_WAIT) begin
            case (sector_byte_index)
            9'd0: sb0 <= sector_byte;
            9'd11: sb11 <= sector_byte;
            9'd12: sb12 <= sector_byte;
            9'd13: sb13 <= sector_byte;
            9'd14: sb14 <= sector_byte;
            9'd15: sb15 <= sector_byte;
            9'd16: sb16 <= sector_byte;
            9'd17: sb17 <= sector_byte;
            9'd18: sb18 <= sector_byte;
            9'd22: sb22 <= sector_byte;
            9'd23: sb23 <= sector_byte;
            9'd32: sb32 <= sector_byte;
            9'd33: sb33 <= sector_byte;
            9'd34: sb34 <= sector_byte;
            9'd35: sb35 <= sector_byte;
            9'd36: sb36 <= sector_byte;
            9'd37: sb37 <= sector_byte;
            9'd38: sb38 <= sector_byte;
            9'd39: sb39 <= sector_byte;
            9'd44: sb44 <= sector_byte;
            9'd45: sb45 <= sector_byte;
            9'd46: sb46 <= sector_byte;
            9'd47: sb47 <= sector_byte;
            9'd450: sb450 <= sector_byte;
            9'd454: sb454 <= sector_byte;
            9'd455: sb455 <= sector_byte;
            9'd456: sb456 <= sector_byte;
            9'd457: sb457 <= sector_byte;
            9'd510: sb510 <= sector_byte;
            9'd511: sb511 <= sector_byte;
            default: ;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            scan_done <= 1'b0;
            fs_error <= ERR_NONE;
            partition_lba <= 32'd0;
            sectors_per_cluster <= 8'd0;
            fat_start_lba <= 32'd0;
            data_start_lba <= 32'd0;
            max_cluster <= 32'd0;
            resource_valid <= 6'd0;
            resource0_cluster <= 32'd0;
            resource1_cluster <= 32'd0;
            resource2_cluster <= 32'd0;
            resource3_cluster <= 32'd0;
            resource4_cluster <= 32'd0;
            resource5_cluster <= 32'd0;
            resource0_size <= 32'd0;
            resource1_size <= 32'd0;
            resource2_size <= 32'd0;
            resource3_size <= 32'd0;
            resource4_size <= 32'd0;
            resource5_size <= 32'd0;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            directory_entry_index <= 5'd0;
            root_cluster <= 32'd0;
            total_sectors <= 32'd0;
            fat_sectors <= 32'd0;
            fat_count <= 8'd0;
            reserved_sectors <= 16'd0;
            root_lba <= 32'd0;
            data_sector_count <= 32'd0;
            fat_span <= 32'd0;
            root_off <= 32'd0;
            sectors_per_cluster_shift <= 3'd0;
            sh_n <= 3'd0;
            bpb_bad <= 1'b0;
            nm_pic <= 1'b0;
            nm_mus <= 1'b0;
            nm_sav <= 1'b0;
            nm_gui <= 1'b0;
            dir_entry_match <= 1'b0;
            dir_music_match <= 1'b0;
            dir_save_match <= 1'b0;
            save_valid <= 1'b0;
            save_cluster <= 28'd0;
            save_big <= 1'b0;
            dir_guide_match <= 1'b0;
            guide_valid <= 1'b0;
            guide_cluster <= 28'd0;
            music_valid <= 1'b0;
            music_cluster <= 32'd0;
            music_size <= 32'd0;
            dir_resource_index <= 3'd3;
            dir_cluster_high <= 16'd0;
            dir_cluster_low <= 16'd0;
            dir_file_size <= 32'd0;
        end else begin
            scan_done <= 1'b0;
            sector_req <= 1'b0;

            if (sector_valid && state == ST_ROOT_WAIT) begin
                case (sector_byte_index[4:0])
                    5'd0: begin
                        nm_pic <= sector_byte == "P";
                        nm_mus <= sector_byte == "M";
                        nm_sav <= sector_byte == "S";
                        nm_gui <= sector_byte == "G";
                        dir_entry_match <= 1'b0;
                        dir_music_match <= 1'b0;
                        dir_save_match <= 1'b0;
                        dir_guide_match <= 1'b0;
                    end
                    //           PIC?    BMP / MUSIC   WAV / SAVE    BIN / GUIDE   WAV
                    5'd1: begin
                        nm_pic <= nm_pic && sector_byte == "I";
                        nm_mus <= nm_mus && sector_byte == "U";
                        nm_sav <= nm_sav && sector_byte == "A";
                        nm_gui <= nm_gui && sector_byte == "U";
                    end
                    5'd2: begin
                        nm_pic <= nm_pic && sector_byte == "C";
                        nm_mus <= nm_mus && sector_byte == "S";
                        nm_sav <= nm_sav && sector_byte == "V";
                        nm_gui <= nm_gui && sector_byte == "I";
                    end
                    5'd3: begin
                        nm_pic <= nm_pic && sector_byte >= "1" && sector_byte <= "6" && sector_byte != "5";   // R11：不认 PIC5
                        dir_resource_index <= sector_byte - "1";   // 只在 dir_entry_match 时用
                        nm_mus <= nm_mus && sector_byte == "I";
                        nm_sav <= nm_sav && sector_byte == "E";
                        nm_gui <= nm_gui && sector_byte == "D";
                    end
                    5'd4: begin
                        nm_pic <= nm_pic && sector_byte == " ";
                        nm_mus <= nm_mus && sector_byte == "C";
                        nm_sav <= nm_sav && sector_byte == " ";
                        nm_gui <= nm_gui && sector_byte == "E";
                    end
                    5'd5, 5'd6, 5'd7: begin
                        nm_pic <= nm_pic && sector_byte == " ";
                        nm_mus <= nm_mus && sector_byte == " ";
                        nm_sav <= nm_sav && sector_byte == " ";
                        nm_gui <= nm_gui && sector_byte == " ";
                    end
                    5'd8: begin
                        nm_pic <= nm_pic && sector_byte == "B";
                        nm_mus <= nm_mus && sector_byte == "W";
                        nm_sav <= nm_sav && sector_byte == "B";
                        nm_gui <= nm_gui && sector_byte == "W";
                    end
                    5'd9: begin
                        nm_pic <= nm_pic && sector_byte == "M";
                        nm_mus <= nm_mus && sector_byte == "A";
                        nm_sav <= nm_sav && sector_byte == "I";
                        nm_gui <= nm_gui && sector_byte == "A";
                    end
                    5'd10: begin
                        nm_pic <= nm_pic && sector_byte == "P";
                        nm_mus <= nm_mus && sector_byte == "V";
                        nm_sav <= nm_sav && sector_byte == "N";
                        nm_gui <= nm_gui && sector_byte == "V";
                    end
                    5'd11: begin
                        dir_entry_match <= nm_pic && sector_byte == 8'h20;
                        dir_music_match <= nm_mus && sector_byte == 8'h20;
                        dir_save_match  <= nm_sav && sector_byte == 8'h20;
                        dir_guide_match <= nm_gui && sector_byte == 8'h20;
                    end
                    5'd20: dir_cluster_high[7:0] <= sector_byte;
                    5'd21: dir_cluster_high[15:8] <= sector_byte;
                    5'd26: dir_cluster_low[7:0] <= sector_byte;
                    5'd27: dir_cluster_low[15:8] <= sector_byte;
                    5'd28: dir_file_size[7:0] <= sector_byte;
                    5'd29: dir_file_size[15:8] <= sector_byte;
                    5'd30: dir_file_size[23:16] <= sector_byte;
                    5'd31: begin
                        // R8-5c 省资源：图片簇号按 FAT32 规定只取低 28 位；大小只存 24 位，>= 16MB 记成 16MB-1
                        //   （BMP 最大 1920x1080 约 6MB；这么大的文件头里的 file_len 也 >= 16MB，bmp_read 照样报格式错）
                        dir_file_size[31:24] <= sector_byte;
                        if (dir_music_match) begin
                            music_cluster <= {dir_cluster_high, dir_cluster_low};
                            music_size <= {sector_byte, dir_file_size[23:0]};
                            music_valid <= 1'b1;
                        end
                        // R8-4a：存档只用文件第一个扇区，大小 >= 512 即可
                        if (dir_save_match && (sector_byte != 8'd0 || dir_file_size[23:9] != 15'd0)) begin
                            save_cluster <= {dir_cluster_high[11:0], dir_cluster_low};
                            save_valid <= 1'b1;
                            save_big <= (sector_byte != 8'd0) || (dir_file_size[23:11] != 13'd0) || (dir_file_size[10:9] == 2'b11);
                        end
                        if (dir_guide_match && (sector_byte != 8'd0 || dir_file_size[23:10] != 14'd0)) begin
                            guide_cluster <= {dir_cluster_high[11:0], dir_cluster_low};
                            guide_valid <= 1'b1;
                        end
                        if (dir_entry_match) begin
                            case (dir_resource_index)
                                3'd0: begin
                                    resource0_cluster <= {4'd0, dir_cluster_high[11:0], dir_cluster_low};
                                    resource0_size <= {8'd0, (sector_byte != 8'd0) ? 24'hFFFFFF : dir_file_size[23:0]};
                                    resource_valid[0] <= 1'b1;
                                end
                                3'd1: begin
                                    resource1_cluster <= {4'd0, dir_cluster_high[11:0], dir_cluster_low};
                                    resource1_size <= {8'd0, (sector_byte != 8'd0) ? 24'hFFFFFF : dir_file_size[23:0]};
                                    resource_valid[1] <= 1'b1;
                                end
                                3'd2: begin
                                    resource2_cluster <= {4'd0, dir_cluster_high[11:0], dir_cluster_low};
                                    resource2_size <= {8'd0, (sector_byte != 8'd0) ? 24'hFFFFFF : dir_file_size[23:0]};
                                    resource_valid[2] <= 1'b1;
                                end
                                3'd3: begin
                                    resource3_cluster <= {4'd0, dir_cluster_high[11:0], dir_cluster_low};
                                    resource3_size <= {8'd0, (sector_byte != 8'd0) ? 24'hFFFFFF : dir_file_size[23:0]};
                                    resource_valid[3] <= 1'b1;
                                end
                                3'd4: ;                    // R12b 资源：PIC5 名字上就不认（R11），这档不登记，resource4_* 恒 0 综合时删掉
                                default: begin
                                    resource5_cluster <= {4'd0, dir_cluster_high[11:0], dir_cluster_low};
                                    resource5_size <= {8'd0, (sector_byte != 8'd0) ? 24'hFFFFFF : dir_file_size[23:0]};
                                    resource_valid[5] <= 1'b1;
                                end
                            endcase
                        end
                    end
                    default: begin end
                endcase
            end

            case (state)
                ST_IDLE: if (scan_start) begin
                    fs_error <= ERR_NONE;
                    partition_lba <= 32'd0;
                    resource_valid <= 6'd0;
                    music_valid <= 1'b0;
                    save_valid <= 1'b0;
                    guide_valid <= 1'b0;
                    state <= ST_READ0_REQ;
                end
                ST_READ0_REQ: if (!sector_busy) begin
                    sector_lba <= 32'd0;
                    sector_req <= 1'b1;
                    state <= ST_READ0_WAIT;
                end
                ST_READ0_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (sb510 != 8'h55 || sb511 != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else if (sb0 == 8'heb || sb0 == 8'he9) begin
                        partition_lba <= 32'd0;
                        state <= ST_BOOT_CHECK;
                    end else if (sb450 == 8'h0b || sb450 == 8'h0c) begin
                        partition_lba <= le32(454);
                        sector_lba <= le32(454);
                        state <= ST_BOOT_REQ;
                    end else begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end
                end
                ST_BOOT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_BOOT_WAIT;
                end
                ST_BOOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (sb510 != 8'h55 || sb511 != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else
                        state <= ST_BOOT_CHECK;
                end
                ST_BOOT_CHECK: begin
                    // R7c-1 时序：原来校验和 20 多个寄存器的使能在同一拍（扇区缓冲 -> 比较 -> 使能，-0.3~-1.3ns）
                    bpb_bad <= le16(11) != 16'd512 || !valid_spc(sb13) ||
                               le16(14) == 0 || (sb16 != 1 && sb16 != 2) ||
                               le16(17) != 0 || le16(22) != 0 || le32(32) == 0 ||
                               le32(36) == 0 || le32(44) < 2;
                    state <= ST_BOOT_PARSE;
                end
                ST_BOOT_PARSE: begin
                    if (bpb_bad) begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end else begin
                        sectors_per_cluster <= sb13;
                        reserved_sectors <= le16(14);
                        fat_count <= sb16;
                        total_sectors <= le32(32);
                        fat_sectors <= le32(36);
                        root_cluster <= le32(44);
                        sectors_per_cluster_shift <= spc_shift(sb13);
                        fat_start_lba <= partition_lba + le16(14);
                        state <= ST_BOOT_SPAN;
                    end
                end
                ST_BOOT_SPAN: begin
                    fat_span <= (fat_count == 8'd2) ? (fat_sectors << 1) : fat_sectors;
                    state <= ST_BOOT_LAYOUT;
                end
                ST_BOOT_LAYOUT: begin
                    data_start_lba <= partition_lba + reserved_sectors + fat_span;
                    data_sector_count <= total_sectors - reserved_sectors - fat_span;
                    state <= ST_BOOT_ROFF;
                end
                ST_BOOT_ROFF: begin
                    // max_cluster / root_off 先放未移位的值，ST_BOOT_SHIFT 里逐位移（最多 7 拍）
                    max_cluster <= data_sector_count;
                    root_off <= root_cluster - 2;
                    sh_n <= sectors_per_cluster_shift;
                    state <= ST_BOOT_SHIFT;
                end
                ST_BOOT_SHIFT: begin
                    if (sh_n != 3'd0) begin
                        max_cluster <= {1'b0, max_cluster[31:1]};
                        root_off <= {root_off[30:0], 1'b0};
                        sh_n <= sh_n - 3'd1;
                    end else begin
                        max_cluster <= max_cluster + 1'b1;
                        state <= ST_BOOT_ROOT;
                    end
                end
                ST_BOOT_ROOT: begin
                    root_lba <= data_start_lba + root_off;
                    sector_lba <= data_start_lba + root_off;
                    state <= ST_ROOT_REQ;
                end
                ST_ROOT_REQ: if (!sector_busy) begin
                    resource_valid <= 6'd0;
                    music_valid <= 1'b0;
                    save_valid <= 1'b0;
                    guide_valid <= 1'b0;
                    dir_entry_match <= 1'b0;
                    dir_music_match <= 1'b0;
                    dir_save_match <= 1'b0;
                    sector_req <= 1'b1;
                    state <= ST_ROOT_WAIT;
                end
                ST_ROOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else begin
                        directory_entry_index <= 5'd0;
                        state <= ST_DIR_SCAN;
                    end
                end
                ST_DIR_SCAN: begin
                    // 缺图错误码只看 PIC1~4（轮播图，R11）；缺 PIC6 由 tf_fault_monitor 单独报警告
                    if (resource_valid[3:0] == 4'hf)
                        state <= ST_FINISH;
                    else
                        finish_with_error(ERR_RESOURCE_MISSING);
                end
                ST_FINISH: begin
                    scan_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
