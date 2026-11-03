// 单键短按 / 长按区分（第2课：KEY 长按 = 上一张）
// 输入是已消抖的按键电平（1=松开，0=按下），输出两种单拍事件：
//   hold_pulse  ：按住满 HOLD_CYCLES 时触发一次，继续按住不会重复触发
//   click_pulse ：松开时触发，且仅当这次按下没有达到长按
// 短按在“松开”时才判定，因为按下那一刻还不知道用户会不会一直按住；
// 若像官方那样在按下沿触发短按，长按就会先误触发一次短按功能。
// R8-5a 资源：长按计时改数 1ms 节拍 tick（原来 28 位时钟计数器），长按时间误差 < 1ms
module key_click_hold #(
    parameter integer HOLD_MS = 1000
)(
    input  wire clk,
    input  wire rst,
    input  wire tick,                 // 1ms 单拍
    input  wire level_n,
    output reg  click_pulse,
    output reg  hold_pulse
);

reg        level_d;
reg [11:0] hold_cnt;              // 单位 1ms，最长 4095ms
reg        hold_fired;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        level_d     <= 1'b1;
        hold_cnt    <= 12'd0;
        hold_fired  <= 1'b0;
        click_pulse <= 1'b0;
        hold_pulse  <= 1'b0;
    end else begin
        level_d     <= level_n;
        click_pulse <= 1'b0;
        hold_pulse  <= 1'b0;

        if (!level_n) begin
            // 按住：计时，到点只触发一次
            if (!hold_fired && tick) begin
                if (hold_cnt >= HOLD_MS - 1) begin
                    hold_pulse <= 1'b1;
                    hold_fired <= 1'b1;
                end else begin
                    hold_cnt <= hold_cnt + 12'd1;
                end
            end
        end else begin
            // 松开沿：没触发过长按才算短按
            if (!level_d && !hold_fired)
                click_pulse <= 1'b1;
            hold_cnt   <= 12'd0;
            hold_fired <= 1'b0;
        end
    end
end

endmodule
