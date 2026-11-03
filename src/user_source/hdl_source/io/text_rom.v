`timescale 1ns/1ps

// R8-0b 文字 ROM（4096 × 8，BRAM；R9 地址口 13 位，最高位恒 0）：菜单 / 状态栏 / 提示条 / 故障条 / 字幕条的固定文字模板 + 效果名词表。
// 内容由 tools/gen_cn_font.py 生成（io/text_rom.hex），各段起始地址见 include/text_ids.vh，不要手改。
// 读出寄存一拍；page_menu_ctrl 的文字生成器奇数拍读模板、偶数拍读词表。
`ifndef TEXT_ROM_HEX
`define TEXT_ROM_HEX "text_rom.hex"     // TD：相对本源文件所在目录（HDL-5105 规则 i）；仿真在 tb 里另行 define
`endif
module text_rom (
    input  wire        clk,
    input  wire [12:0] addr,
    output reg  [7:0]  q
);
    reg [7:0] rom [0:4095];
    initial $readmemh(`TEXT_ROM_HEX, rom);
    always @(posedge clk) q <= rom[addr[11:0]];
endmodule
