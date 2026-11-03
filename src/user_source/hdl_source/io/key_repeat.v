`timescale 1ns/1ps

// 按键"单击 + 按住连续"事件（功能页菜单的 K3 加 / K4 减用）
//   按下后 REPEAT_START_MS 内松开：松开时给一个 step（单击）
//   按住满 REPEAT_START_MS：立刻给一个 step，之后每 REPEAT_MS 再给一个，松开不再给
// R8-0a：输入改为已消抖的电平（ui_key_router 里每个键只消抖一次），本模块不再自带同步 / 消抖。低有效（按下 = 0）。
// R8-5a 资源：计时改数 1ms 节拍 tick（page_menu_ctrl 共用一个分频器），原来 27 位时钟计数器
module key_repeat #(
    parameter integer REPEAT_START_MS = 500,
    parameter integer REPEAT_MS       = 100
) (
    input  wire clk,
    input  wire rst_n,
    input  wire tick,           // 1ms 单拍
    input  wire key_n,
    output reg  step
);

    // R8-0a 时序：自带复位同步器。原来和整个菜单共用 page_menu_ctrl 的复位，布局时那个复位寄存器（扇出 284）
    //   被塞进本模块计数比较器的加法器 slice，离负载太远，recovery -1.09ns
    wire rst_n_k;
    reset_sync u_reset (.clk(clk), .ext_rst_n(rst_n), .rst_n_sync(rst_n_k));

    reg level_d;
    reg [9:0]  hold_cnt;        // 单位 1ms
    reg repeating;

    always @(posedge clk or negedge rst_n_k) begin
        if (!rst_n_k) begin
            level_d <= 1'b1;  hold_cnt <= 10'd0;
            repeating <= 1'b0;  step <= 1'b0;
        end else begin
            level_d <= key_n;
            step    <= 1'b0;
            if (key_n) begin
                if (!level_d && !repeating)
                    step <= 1'b1;               // 短按松开：单击
                hold_cnt  <= 10'd0;
                repeating <= 1'b0;
            end else if (!tick) begin
                // 按住：只在 1ms 节拍上计时
            end else if (!repeating) begin
                if (hold_cnt >= REPEAT_START_MS - 1) begin
                    step      <= 1'b1;          // 按住满 0.5 秒：开始连续
                    repeating <= 1'b1;
                    hold_cnt  <= 10'd0;
                end else
                    hold_cnt <= hold_cnt + 10'd1;
            end else begin
                if (hold_cnt >= REPEAT_MS - 1) begin
                    step     <= 1'b1;
                    hold_cnt <= 10'd0;
                end else
                    hold_cnt <= hold_cnt + 10'd1;
            end
        end
    end
endmodule
