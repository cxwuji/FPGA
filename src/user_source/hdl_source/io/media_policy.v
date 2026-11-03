`timescale 1ns/1ps

module media_policy (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       next_event,
    input  wire       menu_up,
    input  wire       menu_down,
    input  wire       menu_select,
    input  wire [3:0] image_complete,
    output reg  [1:0] media_id,
    output reg  [1:0] audio_id,
    output reg  [7:0] menu_state,
    output reg        linked_event
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            media_id <= 2'd0;
            audio_id <= 2'd0;
            menu_state <= 8'd0;
            linked_event <= 1'b0;
        end else begin
            linked_event <= 1'b0;
            if (next_event && image_complete != 0) begin
                media_id <= media_id + 1'b1;
                audio_id <= audio_id + 1'b1;
                linked_event <= 1'b1;
            end
            if (menu_up)
                menu_state <= menu_state + 1'b1;
            else if (menu_down)
                menu_state <= menu_state - 1'b1;
            if (menu_select)
                menu_state[7] <= ~menu_state[7];
        end
    end
endmodule
