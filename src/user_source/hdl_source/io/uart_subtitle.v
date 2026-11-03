`timescale 1ns/1ps

// R8-1c 电脑串口替换字幕（sd_card_clk 域）。板载 CH340（Type-C），RXD = F12（FPGA 收）、TXD = D12，115200 8N1。
// 电脑端 tools/uart_subtitle.py 把整条字幕画成 512x16 黑白点阵（每字节 8 点，最高位在左，地址 = 行 × 64 + 列字节），
// 连同参数一起发过来；本模块收下后直接写进 layer_compositor 的字幕点阵 RAM（1 KB），字幕条从那里取点。
// 帧格式：A5 5A CMD P1 P2 [点阵 1024 字节，只有 CMD=01 有] CS，CS = CMD + P1 + P2 + 点阵各字节 的低 8 位
//   CMD 01 替换字幕：P1 = {2'b0, 速度-1[1:0], 全部图[0], 运动[1:0], 显示[0]}（运动 0 静止 1 弹跳 2 滚动），P2 = {5'b0, 颜色[2:0]}
//   CMD 02 恢复片内默认字幕（P1 P2 不用）
//   CMD 03（R9）急救位置条点阵（512x16，格式同字幕点阵，P1 P2 不用）：边收边写进位置点阵 RAM（emg_overlay + sd_card_bmp 各一份），
//     校验对了发 ev_loc（sd_card_bmp 把它写进 SAVE.BIN 第 2、3 扇区，断电不丢）
// 收到 CMD 01 就先撤掉替换（字幕回到片内默认，不显示写到一半的点阵）；校验对了才生效，回 "OK\r\n"，
// 校验错 / 两字节间隔超过 GAP_CLKS（10 ms）/ 停止位错 都整帧作废，回 "ER\r\n"。
// 作用范围"只替换当前这张图"：记下收完时的当前图号，layer_compositor 里只有这张图才用替换字幕。
module uart_subtitle #(
    parameter integer CLKS_PER_BIT = 868,          // 100 MHz / 115200
    parameter integer GAP_CLKS     = 1_000_000     // 10 ms
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx_in,                      // 引脚，异步
    output reg         tx_out,
    input  wire [2:0]  cur_pic,                    // 当前第几张（0 起，已同步到本时钟域）
    // 字幕点阵 RAM 写口（layer_compositor）
    output reg         bm_we,
    output reg  [9:0]  bm_addr,
    output reg  [7:0]  bm_data,
    output reg         loc_we,                     // R9：位置点阵写（地址 / 数据同 bm_addr / bm_data）
    output reg         ev_loc,                     // R9：单拍，位置点阵收完且校验对
    // 字幕参数（电平，layer_compositor 里跨到 video_clk）
    output reg         sub_ovr,                    // 替换字幕生效
    output reg         sub_all,                    // 1 = 全部图都用，0 = 只有 sub_pic 这张
    output reg  [2:0]  sub_pic,
    output reg  [2:0]  sub_color,                  // 0 白 1 黄 2 红 3 绿 4 青 5 橙 6 粉 7 蓝
    output reg  [1:0]  sub_speed,                  // 滚动每帧 1~4 点（0~3）
    // 事件（单拍，page_menu_ctrl：改图层页的字幕 显示 / 运动，弹提示条）
    output reg         ev_upd,
    output reg         ev_rst,
    output reg         ev_show,
    output reg  [1:0]  ev_mot
);
    wire rst_n_u;
    reset_sync u_reset (.clk(clk), .ext_rst_n(rst_n), .rst_n_sync(rst_n_u));

    // ---------------- 接收：2FF 同步，起始位中点确认，每位中点采样 ----------------
    (* async_reg = "true" *) reg rx_s1, rx_s2;
    reg        rx_busy;
    reg [15:0] rx_cnt;
    reg [3:0]  rx_bit;
    reg [7:0]  rx_sh;
    reg        rx_done, rx_ferr;                   // 单拍：收完一个字节 / 停止位错
    reg [7:0]  rx_byte;
    always @(posedge clk or negedge rst_n_u) begin
        if (!rst_n_u) begin
            rx_s1 <= 1'b1;  rx_s2 <= 1'b1;  rx_busy <= 1'b0;  rx_cnt <= 16'd0;  rx_bit <= 4'd0;
            rx_sh <= 8'd0;  rx_done <= 1'b0;  rx_ferr <= 1'b0;  rx_byte <= 8'd0;
        end else begin
            rx_s1 <= rx_in;  rx_s2 <= rx_s1;
            rx_done <= 1'b0;  rx_ferr <= 1'b0;
            if (!rx_busy) begin
                if (!rx_s2) begin
                    rx_busy <= 1'b1;  rx_cnt <= CLKS_PER_BIT / 2;  rx_bit <= 4'd0;
                end
            end else if (rx_cnt != 16'd0)
                rx_cnt <= rx_cnt - 16'd1;
            else begin
                rx_cnt <= CLKS_PER_BIT - 1;
                if (rx_bit == 4'd0) begin
                    if (rx_s2) rx_busy <= 1'b0;              // 起始位中点又变高：毛刺
                    else rx_bit <= 4'd1;
                end else if (rx_bit != 4'd9) begin
                    rx_sh <= {rx_s2, rx_sh[7:1]};            // 低位先发
                    rx_bit <= rx_bit + 4'd1;
                end else begin
                    rx_busy <= 1'b0;
                    if (rx_s2) begin rx_done <= 1'b1;  rx_byte <= rx_sh; end
                    else rx_ferr <= 1'b1;
                end
            end
        end
    end

    // ---------------- 帧解析 ----------------
    localparam [2:0] S_H1 = 3'd0, S_H2 = 3'd1, S_CMD = 3'd2, S_P1 = 3'd3, S_P2 = 3'd4, S_DAT = 3'd5, S_CS = 3'd6;
    reg [2:0]  st;
    reg        cmd_set;                            // 1 = CMD 01 / 03（带点阵），0 = CMD 02
    reg        cmd_loc;                            // R9：1 = CMD 03
    reg [7:0]  p1, p2, sum;
    reg [9:0]  dcnt;
    reg [20:0] gap;
    reg        rep_req, rep_ok;                    // 单拍：回 OK / ER
    always @(posedge clk or negedge rst_n_u) begin
        if (!rst_n_u) begin
            st <= S_H1;  cmd_set <= 1'b0;  cmd_loc <= 1'b0;  p1 <= 8'd0;  p2 <= 8'd0;  sum <= 8'd0;  dcnt <= 10'd0;  gap <= 21'd0;
            loc_we <= 1'b0;  ev_loc <= 1'b0;
            rep_req <= 1'b0;  rep_ok <= 1'b0;
            bm_we <= 1'b0;  bm_addr <= 10'd0;  bm_data <= 8'd0;
            sub_ovr <= 1'b0;  sub_all <= 1'b1;  sub_pic <= 3'd0;  sub_color <= 3'd0;  sub_speed <= 2'd1;
            ev_upd <= 1'b0;  ev_rst <= 1'b0;  ev_show <= 1'b1;  ev_mot <= 2'd2;
        end else begin
            bm_we <= 1'b0;  rep_req <= 1'b0;  ev_upd <= 1'b0;  ev_rst <= 1'b0;  loc_we <= 1'b0;  ev_loc <= 1'b0;
            if (st == S_H1 || rx_done)
                gap <= 21'd0;
            else if (gap != GAP_CLKS)
                gap <= gap + 21'd1;
            if (st != S_H1 && (rx_ferr || gap == GAP_CLKS)) begin
                st <= S_H1;                                   // 断帧：整帧作废
                if (st >= S_P1) begin rep_req <= 1'b1;  rep_ok <= 1'b0; end
            end else if (rx_done) begin
                case (st)
                    S_H1:  if (rx_byte == 8'ha5) st <= S_H2;
                    S_H2:  st <= (rx_byte == 8'h5a) ? S_CMD : (rx_byte == 8'ha5) ? S_H2 : S_H1;
                    S_CMD: begin
                        sum <= rx_byte;  cmd_set <= (rx_byte == 8'h01) || (rx_byte == 8'h03);  cmd_loc <= (rx_byte == 8'h03);
                        if (rx_byte == 8'h01 || rx_byte == 8'h02 || rx_byte == 8'h03) st <= S_P1; else st <= S_H1;
                        if (rx_byte == 8'h01) sub_ovr <= 1'b0;   // 写点阵期间先回到片内默认字幕
                    end
                    S_P1:  begin p1 <= rx_byte;  sum <= sum + rx_byte;  st <= S_P2; end
                    S_P2:  begin
                        p2 <= rx_byte;  sum <= sum + rx_byte;  dcnt <= 10'd0;
                        st <= cmd_set ? S_DAT : S_CS;
                    end
                    S_DAT: begin
                        bm_we <= !cmd_loc;  loc_we <= cmd_loc;  bm_addr <= dcnt;  bm_data <= rx_byte;
                        sum <= sum + rx_byte;  dcnt <= dcnt + 10'd1;
                        if (dcnt == 10'd1023) st <= S_CS;
                    end
                    default: begin                             // S_CS
                        st <= S_H1;  rep_req <= 1'b1;  rep_ok <= (rx_byte == sum);
                        if (rx_byte == sum) begin
                            if (cmd_loc)
                                ev_loc <= 1'b1;
                            else if (cmd_set) begin
                                sub_ovr <= 1'b1;  sub_all <= p1[3];  sub_pic <= cur_pic;
                                sub_color <= p2[2:0];  sub_speed <= p1[5:4];
                                ev_upd <= 1'b1;  ev_show <= p1[0];  ev_mot <= (p1[2:1] == 2'd3) ? 2'd2 : p1[2:1];
                            end else begin
                                sub_ovr <= 1'b0;  sub_color <= 3'd0;  sub_speed <= 2'd1;
                                ev_rst <= 1'b1;
                            end
                        end
                    end
                endcase
            end
        end
    end

    // ---------------- 发送：回 "OK\r\n" / "ER\r\n" ----------------
    reg        tx_busy, tx_ok, tx_last;
    reg [1:0]  tx_k;                               // 第几个字节
    reg [3:0]  tx_bit;                             // 0~9 正在发第几位，10 = 这个字节发完
    reg [15:0] tx_cnt;
    reg [9:0]  tx_sh;
    wire [7:0] tx_ch = (tx_k == 2'd0) ? (tx_ok ? "O" : "E") : (tx_k == 2'd1) ? (tx_ok ? "K" : "R") :
                       (tx_k == 2'd2) ? 8'h0d : 8'h0a;
    always @(posedge clk or negedge rst_n_u) begin
        if (!rst_n_u) begin
            tx_out <= 1'b1;  tx_busy <= 1'b0;  tx_ok <= 1'b0;  tx_last <= 1'b0;  tx_k <= 2'd0;  tx_bit <= 4'd10;
            tx_cnt <= 16'd0;  tx_sh <= 10'h3ff;
        end else if (!tx_busy) begin
            tx_out <= 1'b1;
            if (rep_req) begin
                tx_busy <= 1'b1;  tx_ok <= rep_ok;  tx_last <= 1'b0;  tx_k <= 2'd0;  tx_bit <= 4'd10;  tx_cnt <= 16'd0;
            end
        end else if (tx_cnt != 16'd0)
            tx_cnt <= tx_cnt - 16'd1;
        else if (tx_bit == 4'd10) begin                // 上一个字节（含停止位）已发满
            if (tx_last) tx_busy <= 1'b0;
            else begin tx_sh <= {1'b1, tx_ch, 1'b0};  tx_bit <= 4'd0; end
        end else begin
            tx_out <= tx_sh[0];  tx_sh <= {1'b1, tx_sh[9:1]};  tx_cnt <= CLKS_PER_BIT - 1;
            if (tx_bit == 4'd9) begin
                tx_bit <= 4'd10;
                if (tx_k == 2'd3) tx_last <= 1'b1; else tx_k <= tx_k + 2'd1;
            end else
                tx_bit <= tx_bit + 4'd1;
        end
    end
endmodule
