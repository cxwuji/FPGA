`timescale 1ns/1ps

// R4 故障 / 警告判定（sd_card_clk 域）。结果给 page_menu_ctrl 生成正中故障条的文字，cn_text_overlay 闪烁显示。
// 故障（一直显示，原因消失自动撤）：
//   1 未检测到 TF 卡：上电 / 复位后 NOCARD_MS 还没初始化成功（初始化看门狗每 1.5 秒重试，插上卡自动继续）
//   2 TF 卡格式错误：引导扇区签名 / BPB 不对（不是 FAT32）
//   3 TF 卡里没有图片：扫描完一张 PIC1~5.BMP 都没有
//   4 TF 卡读取失败：显示中拔卡（sd_card_bmp tf_lost），或扫描时读扇区出错
//   5 图片格式错误：找到图但一张都没加载成功（不是 640x480 24 位等）
//   上电失败的 2 / 3 / 4 / 5 由 sd_card_bmp 每 2 秒自动重新初始化重试，换好卡就恢复
// 警告（显示 WARN_MS 后消失）：
//   8 缺少图片 PICn.BMP（显示打开时，arg = 第一张缺的）  9 图片 PICn 读取失败（arg = 第一张被放弃的）
//   10 没有背景音乐（显示打开时，或拨上 SW4 时）            11 TF 卡读取不稳定（显示中出现救不回来的 CRC 错扇区）
//   12 缺少急救图 PIC6.BMP                                   13 急救图 PIC6 读取失败（R8-1a 起急救图是 PIC6；显示刚打开时优先报这两条）
// 提示（R12，不是故障，page_menu_ctrl 画成黄框）：
//   14 正在读取图片 n/m：开机扫描完、显示打开前（arg = n - 1，tot = m = 扫描到的轮播图 + PIC6）
module tf_fault_monitor #(
    parameter integer CLKS_PER_MS = 100_000,
    parameter integer EXT_MS      = 0,          // R12b：1 = 用 ms_tick_in（顶层共用的 1ms 节拍）
    parameter integer NOCARD_MS   = 2000,
    parameter integer WARN_MS     = 5000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ms_tick_in,       // R12b：EXT_MS = 1 时用
    input  wire       display_valid,
    input  wire       sd_ready,
    input  wire       boot_done,
    input  wire [7:0] fs_error,
    input  wire [5:0] found_mask,       // bit5 = PIC6
    input  wire [5:0] giveup_mask,      // 按 bank，bit5 = bank5 = PIC6
    input  wire       tf_lost,
    input  wire       music_found,
    input  wire       music_on,         // SW4
    input  wire [7:0] crc_fail_cnt,
    input  wire [2:0] load_idx,         // R12：sd_card_bmp 正在加载的 bank（0~3 轮播图，5 = PIC6）
    input  wire       suppress,         // 急救中故障 / 警告都不显示（R7b-2：场景文档第 5 节，故障条会挡住急救图）
    output reg  [3:0] code,
    output reg  [2:0] arg,              // 8 / 9 号警告：第几张（0~4 = PIC1~5）；14 号：第几张 - 1
    output reg  [2:0] tot               // 14 号：一共几张
);
    localparam [3:0] F_NONE = 4'd0, F_NOCARD = 4'd1, F_FORMAT = 4'd2, F_NOPIC = 4'd3, F_LOST = 4'd4, F_BADIMG = 4'd5,
                     W_MISS = 4'd8, W_BAD = 4'd9, W_NOMUSIC = 4'd10, W_CRC = 4'd11, W_MISS6 = 4'd12, W_BAD6 = 4'd13,
                     I_LOAD = 4'd14;
    // R8-5b 资源：两个计时改数 1ms 节拍（原来 28 / 30 位数时钟），误差 < 1ms；R12b 资源：EXT_MS = 1 时用顶层共用的 1ms 节拍 ms_tick_in（本地再寄存一拍，跨模块长线留一整拍），不再自己分频
    reg [16:0] ms_div;
    reg        ms_tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ms_div <= 17'd0;  ms_tick <= 1'b0;
        end else if (EXT_MS) begin
            ms_tick <= ms_tick_in;
        end else begin
            ms_tick <= (ms_div == CLKS_PER_MS - 1);
            ms_div  <= (ms_div == CLKS_PER_MS - 1) ? 17'd0 : ms_div + 17'd1;
        end
    end

    // 输入先寄存（都是慢变量，断开到 sd_card_bmp 内部的长路径）
    reg       dv, dv_q, rdy, bd, lost, mf, mon, mon_q, sup;
    reg [7:0] fse, crc, crc_q;
    reg [5:0] fm, gm;
    reg [2:0] li;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dv <= 0; dv_q <= 0; rdy <= 0; bd <= 0; lost <= 0; mf <= 0; mon <= 0; mon_q <= 0; sup <= 0;
            fse <= 0; crc <= 0; crc_q <= 0; fm <= 0; gm <= 0; li <= 0;
        end else begin
            dv <= display_valid; dv_q <= dv; rdy <= sd_ready; bd <= boot_done; lost <= tf_lost;
            mf <= music_found; mon <= music_on; mon_q <= mon; sup <= suppress;
            fse <= fs_error; crc <= crc_fail_cnt; crc_q <= crc; fm <= found_mask; gm <= giveup_mask; li <= load_idx;
        end
    end

    // 第 n 个 bank 对应第几张 PIC（缺图时按顺序压紧）
    function [2:0] pic_of_bank;
        input [4:0] m; input [2:0] b;
        integer i; reg [2:0] k; reg [2:0] r;
        begin
            k = 0; r = 3'd0;
            for (i = 0; i < 5; i = i + 1)
                if (m[i]) begin
                    if (k == b) r = i[2:0];
                    k = k + 1;
                end
            pic_of_bank = r;
        end
    endfunction
    function [2:0] first_zero; input [4:0] m;
        first_zero = !m[0] ? 3'd0 : !m[1] ? 3'd1 : !m[2] ? 3'd2 : !m[3] ? 3'd3 : 3'd4;
    endfunction
    function [2:0] first_one; input [4:0] m;
        first_one = m[0] ? 3'd0 : m[1] ? 3'd1 : m[2] ? 3'd2 : m[3] ? 3'd3 : 3'd4;
    endfunction

    reg [12:0] nc_cnt;     // 单位 1ms
    reg [13:0] w_cnt;
    reg [3:0]  w_code;
    reg [2:0]  w_arg;
    reg [3:0]  f_code;
    // R12 开机读图进度：轮播图张数（压紧进 bank0~3），PIC6 排在最后
    wire [2:0] n_car = {2'b00, fm[0]} + {2'b00, fm[1]} + {2'b00, fm[2]} + {2'b00, fm[3]} + {2'b00, fm[4]};
    reg  [2:0] l_arg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nc_cnt <= 13'd0; w_cnt <= 14'd0; w_code <= F_NONE; w_arg <= 3'd0; f_code <= F_NONE;
            code <= F_NONE; arg <= 3'd0; tot <= 3'd0; l_arg <= 3'd0;
        end else begin
            // 故障
            if (rdy || lost)
                nc_cnt <= 13'd0;
            else if (nc_cnt < NOCARD_MS && ms_tick)
                nc_cnt <= nc_cnt + 13'd1;
            if (lost)
                f_code <= F_LOST;
            else if (!rdy)
                f_code <= (nc_cnt >= NOCARD_MS) ? F_NOCARD : F_NONE;
            else if (bd && !dv)
                f_code <= (fse == 8'h10) ? F_LOST :
                          (fse == 8'h20 || fse == 8'h21) ? F_FORMAT :
                          (fse == 8'h22 || fm[4:0] == 5'd0) ? F_NOPIC : F_BADIMG;
            else if (!bd && !dv && fm != 6'd0)                  // R12：扫描完、还在读图
                f_code <= I_LOAD;
            else
                f_code <= F_NONE;
            l_arg <= (li == 3'd5) ? n_car : li;
            tot   <= n_car + {2'b00, fm[5]};

            // 警告
            if (w_cnt != 0) begin
                if (ms_tick) w_cnt <= w_cnt - 14'd1;
            end else
                w_code <= F_NONE;
            if (dv && !dv_q) begin                          // 显示刚打开：急救图缺 / 坏 > 缺图 > 坏图 > 没音乐，只报一个
                if (!fm[5]) begin
                    w_code <= W_MISS6; w_cnt <= WARN_MS;
                end else if (gm[5]) begin
                    w_code <= W_BAD6; w_cnt <= WARN_MS;
                end else if (fm[3:0] != 4'b1111) begin          // R11：轮播 4 张（PIC1~4）
                    w_code <= W_MISS; w_arg <= first_zero(fm[4:0]); w_cnt <= WARN_MS;
                end else if (gm[4:0] != 5'd0) begin
                    w_code <= W_BAD; w_arg <= pic_of_bank(fm[4:0], first_one(gm[4:0])); w_cnt <= WARN_MS;
                end else if (!mf) begin
                    w_code <= W_NOMUSIC; w_cnt <= WARN_MS;
                end
            end else if (dv && mon && !mon_q && !mf) begin
                w_code <= W_NOMUSIC; w_cnt <= WARN_MS;
            end else if (dv && crc != crc_q) begin
                w_code <= W_CRC; w_cnt <= WARN_MS;
            end
            if (!dv)
                w_cnt <= 14'd0;

            code <= sup ? F_NONE : (f_code != F_NONE) ? f_code : w_code;
            arg  <= (f_code == I_LOAD) ? l_arg : w_arg;
        end
    end
endmodule
