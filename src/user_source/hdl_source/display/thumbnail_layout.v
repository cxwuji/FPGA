`timescale 1ns/1ps

// R11：2x2 缩略图格子（R8-1a 的 3x2 每格只有 214x160、3 取 1 点采样，字断成点）。只算"这个像素属于哪一格、要不要显示、要不要画边框"，
// 缩小本身在 media_frame_reader 里做（每行读左右两格 bank 的同一源行，横向两点平均、纵向隔行）。
//   格子 W/2 x H/2（640x480 时 320x240），铺满全屏；格序：上排 PIC1 PIC2（bank0 / 1），下排 PIC3 PIC4（bank2 / 3）。
//   PIC6（急救专用）不进缩略图，emg_border 恒 0（端口保留）
module thumbnail_layout #(
    parameter integer DISPLAY_WIDTH = 640,
    parameter integer DISPLAY_HEIGHT = 480
) (
    input  wire        in_de,
    input  wire [11:0] pixel_x,
    input  wire [11:0] pixel_y,
    input  wire [2:0]  focus_index,      // 0~3
    input  wire [5:0]  cell_valid,       // bit0~4 = bank0~4 加载完成，bit5 = PIC6（emg_ok）
    output reg         thumb_de,
    output reg         focus_border,     // 焦点格黄边
    output reg         emg_border        // R11：恒 0（PIC6 不进缩略图）
);
    localparam integer TW = DISPLAY_WIDTH / 2;
    localparam integer TH = DISPLAY_HEIGHT / 2;
    reg [2:0]  ci;
    reg [11:0] lx, ly;
    reg        on_edge;
    always @* begin
        thumb_de = 1'b0;
        focus_border = 1'b0;
        emg_border = 1'b0;
        ci = 3'd0;
        lx = 12'd0;
        ly = 12'd0;
        on_edge = 1'b0;
        if (in_de && pixel_x < DISPLAY_WIDTH && pixel_y < DISPLAY_HEIGHT) begin
            if (pixel_x < TW) begin
                ci = 3'd0;  lx = pixel_x;
            end else begin
                ci = 3'd1;  lx = pixel_x - TW;
            end
            if (pixel_y >= TH) begin
                ci = ci + 3'd2;
                ly = pixel_y - TH;
            end else
                ly = pixel_y;
            on_edge = lx < 2 || ly < 2 || lx >= TW - 2 || ly >= TH - 2;
            if (cell_valid[ci]) begin
                thumb_de = 1'b1;
                focus_border = on_edge && ci == focus_index;
            end
        end
    end
endmodule
