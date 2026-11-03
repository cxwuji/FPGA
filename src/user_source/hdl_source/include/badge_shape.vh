// 自动生成：python -I tools/gen_badge.py（不要手改）。角标常数和胶囊每行缩进（emg_overlay 模块内 include）
localparam [9:0] B_W = 10'd348;
localparam [9:0] B_ICON = 10'd33;
function [4:0] ins_of;
    input [4:0] r;
    case (r)
        5'd0: ins_of = 5'd9;
        5'd1: ins_of = 5'd7;
        5'd2: ins_of = 5'd5;
        5'd3: ins_of = 5'd4;
        5'd4: ins_of = 5'd3;
        5'd5: ins_of = 5'd2;
        5'd6: ins_of = 5'd2;
        5'd7: ins_of = 5'd1;
        5'd8: ins_of = 5'd1;
        5'd9: ins_of = 5'd0;
        5'd10: ins_of = 5'd0;
        5'd11: ins_of = 5'd0;
        5'd12: ins_of = 5'd0;
        5'd13: ins_of = 5'd0;
        5'd14: ins_of = 5'd0;
        5'd15: ins_of = 5'd1;
        5'd16: ins_of = 5'd1;
        5'd17: ins_of = 5'd2;
        5'd18: ins_of = 5'd2;
        5'd19: ins_of = 5'd3;
        5'd20: ins_of = 5'd4;
        5'd21: ins_of = 5'd5;
        5'd22: ins_of = 5'd7;
        5'd23: ins_of = 5'd9;
        default: ins_of = 5'd31;
    endcase
endfunction
