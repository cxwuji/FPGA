


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

// 移植修正（参考工程）：两个宏都要加括号。原写法文本替换后是 64000000/1000000000/125000000/2**11，
// 整数从左往右除得 0，sdr_init_ref 的刷新请求条件永远不成立 = SDRAM 从不自刷新，不在显示的 bank 会掉数据。
// 加括号后 = 64ms / 8ns / 2048 行 = 3906 个时钟一次刷新（31.25us）。
`define	  SDR_CLK_PERIOD				(1000000000 / 125000000)
`define   SELF_REFRESH_INTERVAL			(64000000 / `SDR_CLK_PERIOD / (2 ** (`ROW_WIDTH)))

