// 自动生成：python -I tools/gen_badge.py（不要手改）。emg_overlay 每帧按脉动档位 lvl 取：左边 - 1 / 右边 + 1 / 上 / 下 + 1 / Q12 步长；
// 下面 ins_of = 胶囊第 y 行左右缩进（圆角），B_W = 原图宽，B_ICON = 天平所在列（列 < B_ICON 的墨是橙色）
case (lvl)
    3'd0: begin t_xm1 <= 10'd145; t_x1 <= 10'd494; t_y0 <= 10'd397; t_y1 <= 10'd421; t_inv <= 13'd4096; end   // x1.000 348x24
    3'd1: begin t_xm1 <= 10'd142; t_x1 <= 10'd498; t_y0 <= 10'd397; t_y1 <= 10'd422; t_inv <= 13'd4010; end   // x1.021 355x25
    3'd2: begin t_xm1 <= 10'd138; t_x1 <= 10'd502; t_y0 <= 10'd397; t_y1 <= 10'd422; t_inv <= 13'd3928; end   // x1.043 363x25
    3'd3: begin t_xm1 <= 10'd134; t_x1 <= 10'd505; t_y0 <= 10'd396; t_y1 <= 10'd422; t_inv <= 13'd3849; end   // x1.064 370x26
    3'd4: begin t_xm1 <= 10'd130; t_x1 <= 10'd509; t_y0 <= 10'd396; t_y1 <= 10'd422; t_inv <= 13'd3773; end   // x1.086 378x26
    3'd5: begin t_xm1 <= 10'd127; t_x1 <= 10'd513; t_y0 <= 10'd396; t_y1 <= 10'd423; t_inv <= 13'd3700; end   // x1.107 385x27
    3'd6: begin t_xm1 <= 10'd123; t_x1 <= 10'd517; t_y0 <= 10'd396; t_y1 <= 10'd423; t_inv <= 13'd3629; end   // x1.129 393x27
    3'd7: begin t_xm1 <= 10'd119; t_x1 <= 10'd520; t_y0 <= 10'd395; t_y1 <= 10'd423; t_inv <= 13'd3562; end   // x1.150 400x28
endcase
