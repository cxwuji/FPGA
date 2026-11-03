// thumbnail_controller.v —— 第14课练习骨架（完赛工程未实现），按文档 3.2.2 参考答案补完
// 时钟：sd_card_clk（控制域）。frame_start 由顶层从像素域 toggle 同步过来（单拍脉冲）。
// view_mode / focus_index 在像素域还会再于 frame_start 锁存一次（media_video_pipeline），保证整帧一致。
module thumbnail_controller (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        key_right,   // 消抖后单拍：焦点右移
    input  wire        key_left,    // 消抖后单拍：焦点左移
    input  wire        key_confirm, // 消抖后单拍：选中当前焦点
    input  wire        key_mode,    // 消抖后单拍：全屏/缩略图切换
    input  wire [4:0]  image_complete,  // R8-1a：bank0~4；R11：轮播 4 张，焦点在 0~3 之间循环（PIC6 不参与）
    input  wire        frame_start, // 帧边界
    output reg         view_mode,   // 0=全屏 1=缩略图
    output reg [2:0]   focus_index,
    output reg [2:0]   active_index,
    output reg         transition_req
);
    // 复位初值：全屏、焦点0、当前图0
    reg trans_pend;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            view_mode <= 1'b0;  focus_index <= 3'd0;
            active_index <= 3'd0;  transition_req <= 1'b0;  trans_pend <= 1'b0;
        end else begin
            transition_req <= 1'b0;
            if (key_mode) begin
                view_mode <= ~view_mode;        // TODO1：切换模式
                trans_pend <= 1'b1;
            end
            if (view_mode && key_right) begin   // TODO2：缩略图下焦点右移wrap
                focus_index <= (focus_index >= 3'd3) ? 3'd0 : focus_index + 1'b1;
            end
            if (view_mode && key_left) begin
                focus_index <= (focus_index == 3'd0) ? 3'd3 : focus_index - 1'b1;
            end
            if (key_confirm && focus_index <= 3'd3 && image_complete[focus_index]) begin  // TODO3
                active_index <= focus_index;
                view_mode    <= 1'b0;
                trans_pend   <= 1'b1;
            end
            if (frame_start && trans_pend) begin  // TODO4：帧边界统一生效+单拍脉冲
                transition_req <= 1'b1;
                trans_pend <= 1'b0;
            end
        end
    end
endmodule
