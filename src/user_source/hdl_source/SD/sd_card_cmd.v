
module sd_card_cmd #(
	parameter CRC_CHECK = 1        // 优化 A6：1 = 计算扇区 CRC16 并计数（数码管诊断页 C），提交版本可设 0
)(
	input                       sys_clk,
	input                       rst,
	input[15:0]                 spi_clk_div,                  //SPI module clock division parameter
	input                       cmd_req,                      //SD card command request
	output                      cmd_req_ack,                  //SD card command request response
	output reg                  cmd_req_error,                //SD card command request error
	input[47:0]                 cmd,                          //SD card command
	input[7:0]                  cmd_r1,                       //SD card expect response
	input[15:0]                 cmd_data_len,                 //SD card command read data length
	input                       block_read_req,               //SD card sector data read request
	output reg                  block_read_valid,             //SD card sector data read data valid
	output reg[7:0]             block_read_data,              //SD card sector data read data
	output                      block_read_req_ack,           //SD card sector data read response
	input                       block_write_req,              //SD card sector data write request
	input[7:0]                  block_write_data,             //SD card sector data write data next clock is valid
	output                      block_write_data_rd,          //SD card sector data write data
	output                      block_write_req_ack,          //SD card sector data write response
	output                      nCS_ctrl,                     //SPI module chip select control
	output reg[15:0]            clk_div,
	output reg                  spi_wr_req,                   //SPI module data sending request
	input                       spi_wr_ack,                   //SPI module data request response
	output[7:0]                 spi_data_in,                  //SPI module send data
	input[7:0]                  spi_data_out,                 //SPI module data returned
	// 诊断（只读，不影响读写流程）
	output reg[1:0]             dbg_stage,                    // 0 空闲 1 发命令/等响应 2 等数据令牌 0xFE 3 读扇区数据
	output reg[7:0]             crc_err_cnt,                  // 扇区数据 CRC16 校验错误次数（封顶 255）
	output reg[7:0]             rd_retry_cnt,                 // 读扇区出错后重试的次数（封顶 255）
	output reg                  blk_crc_err                   // 移植（参考工程扇区重放）：本扇区 CRC16 不符，S_READ_ACK 时锁存，sd_sec_read_end 那一拍有效
);
parameter S_IDLE         = 0;
parameter S_WAIT         = 1;
parameter S_INIT         = 2;
parameter S_CMD_PRE      = 3;
parameter S_CMD          = 4;
parameter S_CMD_DATA     = 5;
parameter S_READ_WAIT    = 6;
parameter S_READ         = 7;
parameter S_READ_ACK     = 8;
parameter S_WRITE_TOKEN  = 9;
parameter S_WRITE_DATA_0 = 10;
parameter S_WRITE_DATA_1 = 11;
parameter S_WRITE_CRC    = 12;
parameter S_WRITE_SUC    = 13;
parameter S_WRITE_BUSY   = 14;
parameter S_WRITE_ACK    = 15;
parameter S_ERR          = 16;
parameter S_END          = 17;

// 等数据令牌 0xFE 的最长字节数：2^18 字节 ≈ 100ms @ SCLK 25MHz（SD 规范单块读访问时间上限 100ms）
parameter READ_TOKEN_TIMEOUT = 18'd262143;

reg[4:0]                      state;
reg                           CS_reg;
reg[15:0]                     byte_cnt;
reg[7:0]                      send_data;
wire[7:0]                     data_recv;
reg[9:0]                      wr_data_cnt;
reg[17:0]                     rd_wait_cnt;                  // 等令牌已经读了多少字节
wire                          rd_wait_fail;                 // 等令牌失败：收到错误令牌或超时

// 数据错误令牌格式为 000xxxxx；原代码只认 0xFE，其它一律继续等，漏收令牌就永远卡在这里
assign rd_wait_fail = (state == S_READ_WAIT) && (spi_wr_ack == 1'b1) && (data_recv != 8'hfe) &&
                      ((data_recv[7:5] == 3'b000) || (rd_wait_cnt == READ_TOKEN_TIMEOUT));

assign cmd_req_ack = (state == S_END);
assign block_read_req_ack = (state == S_READ_ACK);
assign block_write_req_ack= (state == S_WRITE_ACK);
assign block_write_data_rd = (state == S_WRITE_DATA_0);
assign spi_data_in = send_data;
assign data_recv = spi_data_out;
assign nCS_ctrl = CS_reg;
always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		CS_reg <= 1'b1;
		spi_wr_req <= 1'b0;
		byte_cnt <= 16'd0;
		clk_div <= 16'd0;
		send_data <= 8'hff;
		state <= S_IDLE;
		cmd_req_error <= 1'b0;
		wr_data_cnt <= 10'd0;
	end
	else
		case(state)
			S_IDLE:
			begin
				state <= S_INIT;
				clk_div <= spi_clk_div;
				CS_reg <= 1'b1;
			end
			S_INIT:
			begin
				//send 11 bytes on power(at least 74 SPI clocks)
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt >= 16'd10)
					begin
						byte_cnt <= 16'd0;
						spi_wr_req <= 1'b0;
						state <= S_WAIT;
					end
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WAIT:
			begin
				cmd_req_error <= 1'b0;
				wr_data_cnt <= 10'd0;
				//wait for  instruction
				if(cmd_req == 1'b1)
					state <= S_CMD_PRE;
				else if(block_read_req == 1'b1)
					state <= S_READ_WAIT;
				else if(block_write_req == 1'b1)
					state <= S_WRITE_TOKEN;
				clk_div <= spi_clk_div;
			end
			S_CMD_PRE:
			begin
				//before sending a command, send an byte 'ff',provide some clocks
				if(spi_wr_ack == 1'b1)
				begin
					state <= S_CMD;
					spi_wr_req <= 1'b0;
					byte_cnt <= 16'd0;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					CS_reg <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_CMD:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if((byte_cnt == 16'hffff) || (data_recv != cmd_r1 && data_recv[7] == 1'b0))
					begin
						state <= S_ERR;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else if(data_recv == cmd_r1)
					begin
						spi_wr_req <= 1'b0;
						if(cmd_data_len != 16'd0)
						begin
							state <= S_CMD_DATA;
							byte_cnt <= 16'd0;
						end
						else
						begin
							state <= S_END;
							byte_cnt <= 16'd0;
						end
					end
					else
						byte_cnt <=  byte_cnt + 16'd1;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					CS_reg <= 1'b0;
					if(byte_cnt == 16'd0)
						send_data <= (cmd[47:40] | 8'h40);
					else if(byte_cnt == 16'd1)
						send_data <= cmd[39:32];
					else if(byte_cnt == 16'd2)
						send_data <= cmd[31:24];
					else if(byte_cnt == 16'd3)
						send_data <= cmd[23:16];
					else if(byte_cnt == 16'd4)
						send_data <= cmd[15:8];
					else if(byte_cnt == 16'd5)
						send_data <= cmd[7:0];
					else
						send_data <= 8'hff;
				end
			end
			S_CMD_DATA:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt == cmd_data_len - 16'd1)
					begin
						state <= S_END;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_READ_WAIT:
			begin
				if(spi_wr_ack == 1'b1 && data_recv == 8'hfe)
				begin
					spi_wr_req <= 1'b0;
					state <= S_READ;
					byte_cnt <= 16'd0;
				end
				else if(rd_wait_fail)
				begin
					// 报错退出（S_ERR -> S_END，cmd_req_error=1），由 sd_card_sec_read_write 重发 CMD17
					spi_wr_req <= 1'b0;
					state <= S_ERR;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_READ:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt == 16'd513)
					begin
						state <= S_READ_ACK;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WRITE_TOKEN:
				if(spi_wr_ack == 1'b1)
				begin
					state <= S_WRITE_DATA_0;
					spi_wr_req <= 1'b0;
					byte_cnt <= 16'd0;  
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hfe;
				end
			S_WRITE_DATA_0:
			begin
				state <= S_WRITE_DATA_1;
				wr_data_cnt <= wr_data_cnt + 10'd1;
			end
			S_WRITE_DATA_1:
			begin
				if(spi_wr_ack == 1'b1 && wr_data_cnt == 10'd512)
				begin
					state <= S_WRITE_CRC;
					spi_wr_req <= 1'b0;
				end
				else if(spi_wr_ack == 1'b1)
				begin
					state <= S_WRITE_DATA_0;
					spi_wr_req <= 1'b0;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= block_write_data;
				end
			end
			S_WRITE_CRC:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt == 16'd1)
					begin
						state <= S_WRITE_SUC;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WRITE_SUC :
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(data_recv[4:0] == 5'b00101)
					begin
						state <= S_WRITE_BUSY;
						spi_wr_req <= 1'b0;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WRITE_BUSY :
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(data_recv == 8'hff)
					begin
						state <= S_WRITE_ACK;
						spi_wr_req <= 1'b0;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_ERR:
			begin
				state <= S_END;
				cmd_req_error <= 1'b1;
			end
			S_READ_ACK,S_WRITE_ACK,S_END:
			begin
				state <= S_WAIT;
			end
			default:
				state <= S_IDLE;
		endcase
end
always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
		block_read_valid <= 1'b0;
	else if(state == S_READ && byte_cnt < 16'd512)
		block_read_valid <= spi_wr_ack;
	else
		block_read_valid <= 1'b0;
end

always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
		block_read_data <= 8'd0;
	else if(state == S_READ && spi_wr_ack == 1'b1)
		block_read_data <= data_recv;
end

// ---------------- 诊断：当前所处阶段 ----------------
always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
		dbg_stage <= 2'd0;
	else if(state == S_CMD_PRE || state == S_CMD || state == S_CMD_DATA)
		dbg_stage <= 2'd1;
	else if(state == S_READ_WAIT)
		dbg_stage <= 2'd2;
	else if(state == S_READ)
		dbg_stage <= 2'd3;
	else
		dbg_stage <= 2'd0;
end

// ---------------- 诊断：扇区数据 CRC16 校验 ----------------
// SD 卡每个数据块后都跟 2 字节 CRC16（CCITT，多项式 0x1021，初值 0，MSB 先），即使 SPI 模式没开 CRC 也会发。
// 这里只统计错误次数，用来判断 MISO 采样是否出错；数据已经边读边送出去了，不在这里重读。
// 字节间隔 >= 37 个时钟，每字节逐位算 8 个时钟，来得及。
reg[15:0]                     crc_calc;
reg[15:0]                     crc_recv;
reg[7:0]                      crc_sh;
reg[3:0]                      crc_bits;
always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		crc_calc <= 16'd0;
		crc_recv <= 16'd0;
		crc_sh <= 8'd0;
		crc_bits <= 4'd0;
		crc_err_cnt <= 8'd0;
		blk_crc_err <= 1'b0;
	end
	else
	begin
		if(state == S_READ_WAIT)
		begin
			crc_calc <= 16'd0;
			crc_bits <= 4'd0;
		end
		else if(state == S_READ && spi_wr_ack == 1'b1)
		begin
			if(byte_cnt < 16'd512)
			begin
				crc_sh <= data_recv;
				crc_bits <= 4'd8;
			end
			else if(byte_cnt == 16'd512)
				crc_recv[15:8] <= data_recv;
			else
				crc_recv[7:0] <= data_recv;
		end
		else if(crc_bits != 4'd0)
		begin
			crc_calc <= {crc_calc[14:0], 1'b0} ^ ((crc_calc[15] ^ crc_sh[7]) ? 16'h1021 : 16'h0000);
			crc_sh <= {crc_sh[6:0], 1'b0};
			crc_bits <= crc_bits - 4'd1;
		end

		if(CRC_CHECK && state == S_READ_ACK && crc_calc != crc_recv && crc_err_cnt != 8'hff)
			crc_err_cnt <= crc_err_cnt + 8'd1;
		if(state == S_READ_ACK)
			blk_crc_err <= CRC_CHECK && (crc_calc != crc_recv);
	end
end

// 等令牌计数
always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
		rd_wait_cnt <= 18'd0;
	else if(state != S_READ_WAIT)
		rd_wait_cnt <= 18'd0;
	else if(spi_wr_ack == 1'b1 && rd_wait_cnt != READ_TOKEN_TIMEOUT)
		rd_wait_cnt <= rd_wait_cnt + 18'd1;
end

// 读扇区重试计数：CMD17 响应出错或等令牌失败，都会经过 S_ERR，上层随后重发 CMD17
always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
		rd_retry_cnt <= 8'd0;
	else if(rd_retry_cnt != 8'hff && state == S_ERR && cmd[47:40] == 8'd17)
		rd_retry_cnt <= rd_retry_cnt + 8'd1;
end

endmodule