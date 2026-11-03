`timescale 1ns/1ps

// 拨码开关电平消抖：2FF 同步 + 连续 DEBOUNCE_MS 稳定才更新。
// R8-5a 资源：计数改数 1ms 节拍 tick（ui_key_router 共用一个分频器），原来每个开关一个 24 位时钟计数器
// 输出 on = 1 表示开关处在"开"位置；开的物理电平由 ON_LEVEL 决定（手册与例程对拨上是 1 还是 0 说法相反，上板实测后改这个参数）。
module switch_debounce #(
    parameter integer DEBOUNCE_MS = 20,
    parameter         ON_LEVEL    = 1'b1
) (
    input  wire clk,
    input  wire rst_n,
    input  wire tick,                  // 1ms 单拍
    input  wire sw_in,
    output reg  on
);
    reg s0, s1;
    reg [5:0] cnt;                     // 单位 1ms
    wire raw_on = (s1 == ON_LEVEL);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0  <= ~ON_LEVEL;
            s1  <= ~ON_LEVEL;
            cnt <= 6'd0;
            on  <= 1'b0;
        end else begin
            s0 <= sw_in;
            s1 <= s0;
            if (raw_on == on) begin
                cnt <= 6'd0;
            end else if (tick) begin
                if (cnt >= DEBOUNCE_MS - 1) begin
                    on  <= raw_on;
                    cnt <= 6'd0;
                end else
                    cnt <= cnt + 6'd1;
            end
        end
    end
endmodule
