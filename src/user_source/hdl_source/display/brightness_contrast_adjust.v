// brightness_contrast_adjust.v —— 第13课练习骨架（完赛工程未单独实现），对比度按文档 3.2.2 参考答案补完
// R8-2：后面加色彩（饱和度）2 级流水：Y = (77R + 150G + 29B + 128) >> 8（移位加法），d = C - Y，
//   0 黑白 = Y、1 淡 = Y + d/2、2 标准 = C（逐位直通）、3 鲜艳 = C + d/2（= Y + 1.5d），再截到 0~255。不用乘法器。
//   整个模块延迟 3 拍（原来 1 拍），out_de 跟着。
module brightness_contrast_adjust (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_de,
    input  wire [23:0] rgb_in,
    input  wire [7:0]  brightness,   // 帧边界锁存后的亮度
    input  wire [7:0]  contrast,     // 帧边界锁存后的对比度
    input  wire [1:0]  saturation,   // R8-2：帧边界锁存后的色彩档
    output reg         out_de,
    output reg  [23:0] rgb_out
);
    // ---- 亮度通路（已给）：每通道 × brightness 后取高8位，即 /256 ----
    // 移植时改：× (brightness+1)，与完赛 media_video_pipeline 的 eff_alpha 同一做法，
    // brightness=255 时逐位直通（满足 3.2.3 第 1 条回归基准；原写法 255 会变成 254）
    wire [8:0]  bri_p1 = {1'b0, brightness} + 9'd1;
    wire [16:0] mul_r = rgb_in[23:16] * bri_p1;
    wire [16:0] mul_g = rgb_in[15:8]  * bri_p1;
    wire [16:0] mul_b = rgb_in[7:0]   * bri_p1;
    wire [7:0] bright_r = mul_r[15:8];
    wire [7:0] bright_g = mul_g[15:8];
    wire [7:0] bright_b = mul_b[15:8];

    // ===== TODO(学员完成)：对比度 + 饱和截断 =====
    // 对 bright_r/g/b 分别做：
    //   center = x - 128;
    //   scaled = center * contrast / 128;   // /128 用算术右移7位 >>>7
    //   y      = scaled + 128;
    //   final  = saturate(y)  即 y<0 取0、y>255 取255，否则取y
    // 注意 center/scaled 是有符号数，请用 signed 声明并给足位宽防止溢出。
    wire signed [8:0]  ctr_r = $signed({1'b0, bright_r}) - 9'sd128;
    wire signed [16:0] sc_r  = (ctr_r * $signed({1'b0, contrast})) >>> 7;
    wire signed [9:0]  sum_r = sc_r + 10'sd128;
    wire [7:0] final_r = (sum_r < 10'sd0)   ? 8'd0   :
                         (sum_r > 10'sd255) ? 8'd255 : sum_r[7:0];

    wire signed [8:0]  ctr_g = $signed({1'b0, bright_g}) - 9'sd128;
    wire signed [16:0] sc_g  = (ctr_g * $signed({1'b0, contrast})) >>> 7;
    wire signed [9:0]  sum_g = sc_g + 10'sd128;
    wire [7:0] final_g = (sum_g < 10'sd0)   ? 8'd0   :
                         (sum_g > 10'sd255) ? 8'd255 : sum_g[7:0];

    wire signed [8:0]  ctr_b = $signed({1'b0, bright_b}) - 9'sd128;
    wire signed [16:0] sc_b  = (ctr_b * $signed({1'b0, contrast})) >>> 7;
    wire signed [9:0]  sum_b = sc_b + 10'sd128;
    wire [7:0] final_b = (sum_b < 10'sd0)   ? 8'd0   :
                         (sum_b > 10'sd255) ? 8'd255 : sum_b[7:0];

    // 第 1 拍：亮度 / 对比度结果
    reg        de1, de2;
    reg [23:0] c1, c2;
    reg [7:0]  y2;
    reg [1:0]  sat2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de1 <= 1'b0;  c1 <= 24'h000000;
        end else begin
            de1 <= in_de;
            c1  <= {final_r, final_g, final_b};
        end
    end
    // 第 2 拍：灰度
    wire [7:0]  r1 = c1[23:16], g1 = c1[15:8], b1 = c1[7:0];
    wire [16:0] ysum = {3'd0, r1, 6'd0} + {6'd0, r1, 3'd0} + {7'd0, r1, 2'd0} + {9'd0, r1}
                     + {2'd0, g1, 7'd0} + {5'd0, g1, 4'd0} + {7'd0, g1, 2'd0} + {8'd0, g1, 1'b0}
                     + {5'd0, b1, 4'd0} + {6'd0, b1, 3'd0} + {7'd0, b1, 2'd0} + {9'd0, b1} + 17'd128;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de2 <= 1'b0;  c2 <= 24'h000000;  y2 <= 8'd0;  sat2 <= 2'd2;
        end else begin
            de2 <= de1;  c2 <= c1;  y2 <= ysum[15:8];  sat2 <= saturation;
        end
    end
    // 第 3 拍：按色彩档混合
    function [7:0] sat_mix;
        input [7:0] c, y;
        input [1:0] m;
        reg signed [9:0] d, o;
        begin
            d = $signed({2'b00, c}) - $signed({2'b00, y});
            case (m)
                2'd0:    o = $signed({2'b00, y});
                2'd1:    o = $signed({2'b00, y}) + (d >>> 1);
                2'd2:    o = $signed({2'b00, c});
                default: o = $signed({2'b00, c}) + (d >>> 1);
            endcase
            sat_mix = (o < 0) ? 8'd0 : (o > 10'sd255) ? 8'd255 : o[7:0];
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_de <= 1'b0;
            rgb_out <= 24'h000000;
        end else begin
            out_de <= de2;
            rgb_out <= {sat_mix(c2[23:16], y2, sat2), sat_mix(c2[15:8], y2, sat2), sat_mix(c2[7:0], y2, sat2)};
        end
    end
endmodule
