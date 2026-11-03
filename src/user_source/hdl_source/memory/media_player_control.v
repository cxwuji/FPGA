`timescale 1ns/1ps

module media_player_control #(
    parameter [31:0] DEFAULT_PERIOD_CYCLES = 32'd250000000,
    parameter [31:0] MIN_PERIOD_CYCLES = 32'd50000000,
    parameter [31:0] MAX_PERIOD_CYCLES = 32'd3000000000
) (
    input  wire        sys_clk,
    input  wire        sys_rst_n,
    input  wire        next_event,
    input  wire        prev_event,          // 移植时加：上一张（K4 长按）
    input  wire        select_event,        // 第14课：缩略图确认，直接切到 select_index（同样帧边界原子提交）
    input  wire [2:0]  select_index,     // R8-1a：轮播图 0~4
    input  wire        toggle_auto_event,
    input  wire        period_cfg_valid,
    input  wire [31:0] period_cfg_cycles,
    input  wire        auto_cfg_valid,
    input  wire        auto_cfg_enabled,
    input  wire [4:0]  image_complete,
    output reg         auto_enabled,
    output reg  [31:0] active_period_cycles,
    output reg  [2:0]  pending_index,
    output reg  [7:0]  control_error,
    output wire        request_busy,
    input  wire        pix_clk,
    input  wire        pix_rst_n,
    input  wire        frame_start,
    output reg  [2:0]  active_index,
    output reg         index_commit
);
    localparam ERR_NONE = 8'h00;
    localparam ERR_PERIOD_RANGE = 8'h51;
    localparam ERR_REQUEST_BUSY = 8'h52;
    localparam ERR_NO_RESOURCE = 8'h53;

    reg [31:0] auto_counter;
    reg [2:0] sys_current_index;
    reg request_toggle;
    reg ack_toggle_pix;
    reg ack_sync1, ack_sync2;
    reg [2:0] index_sync1, index_sync2;
    reg req_sync1, req_sync2;
    reg req_seen_pix;
    reg [2:0] requested_index_pix;
    reg commit_pending_pix;

    assign request_busy = request_toggle != ack_sync2;

    // R8-1a：5 张轮播图，按 mod 5 往后 / 往前找已加载完成的图（返回 {找到, 序号}）
    function [3:0] next_available;
        input [2:0] current;
        input [4:0] complete;
        integer step, c;
        begin
            next_available = {1'b0, current};
            for (step = 1; step <= 5; step = step + 1) begin
                c = current + step;
                if (c >= 5) c = c - 5;
                if (!next_available[3] && complete[c])
                    next_available = {1'b1, c[2:0]};
            end
        end
    endfunction

    // 移植时加：与 next_available 对称，往回找上一张已加载完成的图
    function [3:0] prev_available;
        input [2:0] current;
        input [4:0] complete;
        integer step, c;
        begin
            prev_available = {1'b0, current};
            for (step = 1; step <= 5; step = step + 1) begin
                c = current - step;
                if (c < 0) c = c + 5;
                if (!prev_available[3] && complete[c])
                    prev_available = {1'b1, c[2:0]};
            end
        end
    endfunction

    // R8-2b 时序：下一张 / 上一张每拍预先算好寄存（原来 sys_current_index -> 5 步查找 -> pending_index 一拍走完，-0.16ns）。
    //   从 pending_index 算：不忙时它就是当前图（sys_current_index 下一拍才跟上）；发请求后要忙 >= 4 拍，这里早已更新
    reg [3:0] nxt_r, prv_r;
    always @(posedge sys_clk) begin
        nxt_r <= next_available(pending_index, image_complete);
        prv_r <= prev_available(pending_index, image_complete);
    end

    task issue_request;
        input [3:0] selected;
        begin
            if (request_busy) begin
                control_error <= ERR_REQUEST_BUSY;
            end else if (!selected[3]) begin
                control_error <= ERR_NO_RESOURCE;
            end else begin
                pending_index <= selected[2:0];
                request_toggle <= ~request_toggle;
                auto_counter <= 32'd0;
            end
        end
    endtask

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            auto_enabled <= 1'b0;
            active_period_cycles <= DEFAULT_PERIOD_CYCLES;
            pending_index <= 3'd0;
            control_error <= ERR_NONE;
            auto_counter <= 32'd0;
            sys_current_index <= 3'd0;
            request_toggle <= 1'b0;
            ack_sync1 <= 1'b0;
            ack_sync2 <= 1'b0;
        end else begin
            ack_sync1 <= ack_toggle_pix;
            ack_sync2 <= ack_sync1;
            if (!request_busy)
                sys_current_index <= pending_index;

            if (period_cfg_valid) begin
                if (period_cfg_cycles < MIN_PERIOD_CYCLES ||
                    period_cfg_cycles > MAX_PERIOD_CYCLES) begin
                    control_error <= ERR_PERIOD_RANGE;
                end else begin
                    active_period_cycles <= period_cfg_cycles;
                    auto_counter <= 32'd0;
                end
            end

            if (auto_cfg_valid) begin
                auto_enabled <= auto_cfg_enabled;
                auto_counter <= 32'd0;
            end

            if (toggle_auto_event) begin
                auto_enabled <= ~auto_enabled;
                auto_counter <= 32'd0;
            end

            if (next_event) begin
                issue_request(nxt_r);
            end else if (prev_event) begin
                issue_request(prv_r);
            end else if (select_event) begin
                issue_request({(select_index < 3'd5) && image_complete[select_index], select_index});
            end else if (auto_enabled) begin
                if (request_busy)
                    auto_counter <= 32'd0;
                else if (auto_counter >= active_period_cycles - 1'b1)
                    issue_request(nxt_r);
                else
                    auto_counter <= auto_counter + 1'b1;
            end else begin
                auto_counter <= 32'd0;
            end
        end
    end

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            index_sync1 <= 3'd0;
            index_sync2 <= 3'd0;
            req_sync1 <= 1'b0;
            req_sync2 <= 1'b0;
            req_seen_pix <= 1'b0;
            requested_index_pix <= 3'd0;
            commit_pending_pix <= 1'b0;
            active_index <= 3'd0;
            index_commit <= 1'b0;
            ack_toggle_pix <= 1'b0;
        end else begin
            index_sync1 <= pending_index;
            index_sync2 <= index_sync1;
            req_sync1 <= request_toggle;
            req_sync2 <= req_sync1;
            index_commit <= 1'b0;

            if (req_sync2 != req_seen_pix && !commit_pending_pix) begin
                req_seen_pix <= req_sync2;
                requested_index_pix <= index_sync2;
                commit_pending_pix <= 1'b1;
            end

            if (frame_start && commit_pending_pix) begin
                active_index <= requested_index_pix;
                index_commit <= 1'b1;
                commit_pending_pix <= 1'b0;
                ack_toggle_pix <= req_seen_pix;
            end
        end
    end
endmodule
