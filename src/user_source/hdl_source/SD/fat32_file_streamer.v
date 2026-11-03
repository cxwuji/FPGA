`timescale 1ns/1ps

module fat32_file_streamer #(
    parameter integer MAX_VISITED_CLUSTERS = 8192
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        file_start,
    input  wire [31:0] first_cluster,
    input  wire [31:0] file_size,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [31:0] fat_start_lba,
    input  wire [31:0] data_start_lba,
    input  wire [31:0] max_cluster,
    output wire        file_busy,
    output reg         file_done,
    output reg         file_valid,
    output reg  [7:0]  file_byte,
    output reg  [31:0] file_byte_offset,
    output reg  [7:0]  fs_error,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);
    localparam ERR_NONE              = 8'h00;
    localparam ERR_SECTOR            = 8'h10;
    localparam ERR_FAT_LOOP          = 8'h23;
    localparam ERR_CLUSTER_RANGE     = 8'h24;
    localparam ERR_EARLY_EOF         = 8'h25;
    localparam ERR_VISITED_EXHAUSTED = 8'h26;

    localparam ST_IDLE       = 4'd0;
    localparam ST_DATA_REQ   = 4'd1;
    localparam ST_DATA_WAIT  = 4'd2;
    localparam ST_FAT_REQ    = 4'd3;
    localparam ST_FAT_WAIT   = 4'd4;
    localparam ST_FAT_PARSE  = 4'd5;
    localparam ST_FAT_PRE    = 4'd6;     // R1.5a 时序：FAT 表项 -> 下一簇扇区号分两拍算好再 PARSE
    localparam ST_FAT_PRE2   = 4'd8;
    localparam ST_FINISH     = 4'd7;

    localparam integer CHAIN_COUNT_WIDTH = $clog2(MAX_VISITED_CLUSTERS + 1);

    reg [3:0] state;
    reg [31:0] current_cluster;
    reg [31:0] next_cluster;
    reg [31:0] remaining_bytes;
    reg [7:0] sector_in_cluster;
    reg [8:0] fat_entry_offset;
    reg [7:0] fat_byte0, fat_byte1, fat_byte2, fat_byte3;
    reg [CHAIN_COUNT_WIDTH-1:0] chain_count;
    reg final_chain_check;

    assign file_busy = (state != ST_IDLE);

    // 时序修改（移植时加）：簇号 -> 扇区号原来用 32x8 乘法，100MHz 下单拍做不完（sd_card_clk -1.8ns）。
    // 每簇扇区数已由 fat32_volume_scanner 校验为 2 的幂，乘法等价于左移。
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

    // 时序（移植时加）：以下几个量的输入在用到之前早就稳定，提前一拍算好寄存：
    //   sectors_per_cluster / data_start_lba / max_cluster 扫描完就不变；first_cluster 在 file_start 前至少 2 拍就已给出。
    //   不接 rst_n：file_abort 复位本模块后紧接着就可能来 file_start，这几个寄存器必须一直有效。
    reg [2:0]  spc_shift_r;     // 查表 + 移位 + 加法放一拍有 8 级（-0.74ns）
    reg [31:0] first_lba_r;     // 起始簇的第一个扇区
    reg [31:0] first_m2_r;      // R8-2b 时序：减 2 / 移位 + 加法拆两拍（原来一拍 7 级，sd_card_clk -0.5~-1.0ns）。
                                //   sd_card_bmp 里 load_cluster 和 load_start_pulse 同拍给出，经 bmp_read 的 pend、file_ready
                                //   两级寄存后 file_start 最早晚 2 拍到，first_lba_r 正好在那一拍有效
    reg        first_bad_r;     // 起始簇号越界（-0.03ns）
    reg        fsz0_r;          // R9 时序：文件大小 = 0（file_size 和 first_cluster 同拍给出；原来 file_start 那拍 32 位比较 -> sector_lba 使能，-0.65ns）
    always @(posedge clk) begin
        spc_shift_r <= spc_shift(sectors_per_cluster);
        first_m2_r  <= first_cluster - 32'd2;
        first_lba_r <= data_start_lba + (first_m2_r << spc_shift_r);
        first_bad_r <= (first_cluster < 2) || (first_cluster > max_cluster) || (sectors_per_cluster == 0);
        fsz0_r      <= (file_size == 32'd0);
    end

    // R1.5a 时序：下一簇的第一个扇区原来在 PARSE 那一拍做 减 2 + 移位 + 加法（8 级，sd_card_clk -0.3~-1.4ns）。
    // 拆成两级寄存：fat_byte 在 sector_done 前已写完，ST_FAT_PRE / PRE2 两拍后 next_lba_r 有效
    reg [31:0] next_m2_r, next_lba_r;
    // R8-5b 时序：PARSE 里的表项判断（结束标记 / 越界 / 自环）也在 PRE / PRE2 预先寄存（原来 fat_byte -> 比较 -> 状态一拍，-0.2~-0.5ns）
    reg        fe_eoc, fe_bad, fe_self;
    always @(posedge clk) begin
        next_m2_r  <= {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} - 32'd2;
        next_lba_r <= data_start_lba + (next_m2_r << spc_shift_r);
        fe_eoc     <= {fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} >= 28'hffffff8;
        fe_bad     <= {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} < 2 ||
                      {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} > max_cluster;
        fe_self    <= {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} == current_cluster;
    end

    // R9 时序：DATA_WAIT 里"簇内还有下一扇区"的比较和 FAT 扇区号加法原来和 sector_lba 选择放一拍（8 级，-0.45ns）。
    //   sector_in_cluster / current_cluster 只在进 ST_DATA_REQ 时改，到 sector_done 至少隔一整个扇区，提前寄存
    reg        sec_more_r;
    reg [31:0] fat_lba_r;
    always @(posedge clk) begin
        sec_more_r <= sector_in_cluster + 1'b1 < sectors_per_cluster;
        fat_lba_r  <= fat_start_lba + (current_cluster >> 7);
    end

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    task advance_to_next_cluster;
        input [31:0] cluster_value;
        begin
            chain_count <= chain_count + 1'b1;
            current_cluster <= cluster_value;
            sector_lba <= next_lba_r;      // = data_start_lba + ((cluster_value - 2) << spc_shift_r)
            state <= ST_DATA_REQ;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            file_done <= 1'b0;
            file_valid <= 1'b0;
            file_byte <= 8'd0;
            file_byte_offset <= 32'd0;
            fs_error <= ERR_NONE;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            current_cluster <= 32'd0;
            next_cluster <= 32'd0;
            remaining_bytes <= 32'd0;
            sector_in_cluster <= 8'd0;
            fat_entry_offset <= 9'd0;
            fat_byte0 <= 8'd0;
            fat_byte1 <= 8'd0;
            fat_byte2 <= 8'd0;
            fat_byte3 <= 8'd0;
            chain_count <= 0;
            final_chain_check <= 1'b0;
        end else begin
            file_done <= 1'b0;
            file_valid <= 1'b0;
            sector_req <= 1'b0;

            if (state == ST_DATA_WAIT && sector_valid && remaining_bytes != 0) begin
                file_valid <= 1'b1;
                file_byte <= sector_byte;
                // R8-5c 省资源：file_byte_offset 没人用，不再算（恒 0）
                remaining_bytes <= remaining_bytes - 1'b1;
            end

            if (state == ST_FAT_WAIT && sector_valid) begin
                if (sector_byte_index == fat_entry_offset)
                    fat_byte0 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 1'b1)
                    fat_byte1 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 2'd2)
                    fat_byte2 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 2'd3)
                    fat_byte3 <= sector_byte;
            end

            case (state)
                ST_IDLE: if (file_start) begin
                    fs_error <= ERR_NONE;
                    file_byte_offset <= 32'd0;
                    remaining_bytes <= file_size;
                    sector_in_cluster <= 8'd0;
                    chain_count <= 1;
                    final_chain_check <= 1'b0;
                    if (fsz0_r) begin
                        state <= ST_FINISH;
                    end else if (first_bad_r) begin
                        finish_with_error(ERR_CLUSTER_RANGE);
                    end else begin
                        current_cluster <= first_cluster;
                        sector_lba <= first_lba_r;
                        state <= ST_DATA_REQ;
                    end
                end
                ST_DATA_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_DATA_WAIT;
                end
                ST_DATA_WAIT: if (sector_done) begin
                    if (sector_error != 0) begin
                        finish_with_error(ERR_SECTOR);
                    end else if (remaining_bytes == 0 ||
                                 (remaining_bytes == 1 && sector_valid)) begin
                        final_chain_check <= 1'b1;
                        sector_in_cluster <= 8'd0;
                        fat_entry_offset <= {current_cluster[6:0], 2'b00};
                        sector_lba <= fat_lba_r;
                        state <= ST_FAT_REQ;
                    end else if (sec_more_r) begin
                        sector_in_cluster <= sector_in_cluster + 1'b1;
                        sector_lba <= sector_lba + 1'b1;
                        state <= ST_DATA_REQ;
                    end else begin
                        sector_in_cluster <= 8'd0;
                        fat_entry_offset <= {current_cluster[6:0], 2'b00};
                        sector_lba <= fat_lba_r;
                        state <= ST_FAT_REQ;
                    end
                end
                ST_FAT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_FAT_WAIT;
                end
                ST_FAT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else
                        state <= ST_FAT_PRE;
                end
                ST_FAT_PRE:  state <= ST_FAT_PRE2;
                ST_FAT_PRE2: state <= ST_FAT_PARSE;
                ST_FAT_PARSE: begin
                    next_cluster <= {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0};
                    if (final_chain_check) begin
                        final_chain_check <= 1'b0;
                        if (fe_eoc)
                            state <= ST_FINISH;
                        else if (fe_bad)
                            finish_with_error(ERR_CLUSTER_RANGE);
                        else
                            finish_with_error(ERR_FAT_LOOP);
                    end else if (fe_eoc) begin
                        finish_with_error(ERR_EARLY_EOF);
                    end else if (fe_bad) begin
                        finish_with_error(ERR_CLUSTER_RANGE);
                    end else if (chain_count >= MAX_VISITED_CLUSTERS) begin
                        finish_with_error(ERR_VISITED_EXHAUSTED);
                    end else if (fe_self) begin
                        finish_with_error(ERR_FAT_LOOP);
                    end else begin
                        advance_to_next_cluster({4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0});
                    end
                end
                ST_FINISH: begin
                    file_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
