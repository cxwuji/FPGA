`timescale 1ns/1ps

// 错误码跨时钟域快照（移植自参考工程 sticky_error_cdc，移植修正见下）
// 多位错误码逐位 2FF 同步时，码值变化那一拍目的域可能看到"半新半旧"的拼凑值（OSD 上显示一个从没出现过的错误码，
// 而 reader_error 还用来决定像素是否输出，拼凑值会让画面错误地黑一下）。这里源域先把码值锁进快照寄存器并翻转请求，
// 目的域看到同步后的请求翻转（此时快照早已稳定）才整组采样，再把应答送回；应答回来之前快照不变。
// 移植修正：参考工程每个复位周期只锁存第一个错误（它的错误码不会清零）；我们的 reader_error 每帧重载清零、
// control_error 成功一次就清零，所以改成"握手后可再次更新"，码值变化后几个时钟内整组送达。
module error_snapshot_cdc (
    input  wire       src_clk,
    input  wire       src_rst_n,
    input  wire [7:0] src_code,
    input  wire       dst_clk,
    input  wire       dst_rst_n,
    output reg  [7:0] dst_code
);
    reg [7:0] snap;
    reg       req_t;
    reg       ack_s1, ack_s2;
    wire      busy = req_t ^ ack_s2;

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            snap   <= 8'd0;
            req_t  <= 1'b0;
            ack_s1 <= 1'b0;
            ack_s2 <= 1'b0;
        end else begin
            ack_s1 <= ack_t;
            ack_s2 <= ack_s1;
            if (!busy && src_code != snap) begin
                snap  <= src_code;
                req_t <= ~req_t;
            end
        end
    end

    reg req_s1, req_s2;
    reg ack_t;
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            req_s1   <= 1'b0;
            req_s2   <= 1'b0;
            ack_t    <= 1'b0;
            dst_code <= 8'd0;
        end else begin
            req_s1 <= req_t;
            req_s2 <= req_s1;
            if (req_s2 != ack_t) begin
                dst_code <= snap;          // 快照从发出请求到收到应答一直不变
                ack_t    <= req_s2;
            end
        end
    end
endmodule
