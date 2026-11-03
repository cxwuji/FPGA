`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: anlgoic
// Author: 	xg 
// description:  top module
//////////////////////////////////////////////////////////////////////////////////

`define DEBUG

`include "../user_source/hdl_source/include/global_def.v"

module sdram(
    `ifdef SIMULATION
	output					SDRAM_CLK,
	output					SDR_CKE,
	output					SDR_RAS,
	output					SDR_CAS,
	output					SDR_WE,
	output	[`BA_WIDTH-1:0]	SDR_BA,
	output	[`ROW_WIDTH-1:0]SDR_ADDR,
	output	[`DM_WIDTH-1:0]	SDR_DM,
	inout	[`DATA_WIDTH-1:0]	SDR_DQ,	
	`endif
    input   					Clk,
    input						Clk_sft,
    input						Rst,
    
    output 						Sdr_init_done,
    output						Sdr_init_ref_vld,
    output						Sdr_busy,
    
    input						App_wr_en,
	input [`ADDR_WIDTH-1:0]		App_wr_addr,  	
	input [`DM_WIDTH-1:0]		App_wr_dm,
	input [`DATA_WIDTH-1:0]		App_wr_din,	//synthesis keep
    
    input 						App_rd_en,
	input [`ADDR_WIDTH-1:0]		App_rd_addr,
	output 						Sdr_rd_en,
	output [`DATA_WIDTH-1:0]	Sdr_rd_dout	//synthesis keep
    
    
    
);
`ifndef SIMULATION
wire  			SDRAM_CLK;
wire 			SDR_RAS;
wire  			SDR_CAS;
wire  			SDR_WE;
wire  [`BA_WIDTH-1:0]	SDR_BA; 
wire  [`ROW_WIDTH-1:0]	SDR_ADDR;
wire  [`DATA_WIDTH-1:0]	SDR_DQ ;
wire  [`DM_WIDTH-1:0]	SDR_DM; 
`endif

// 移植修正（参考工程）：刷新打开后，刷新命令前后留出"不准开始新突发"的窗口。
// Sdr_busy 对外改为 app_busy（控制器 busy 或处在窗口内），读写两侧只在开始新突发时看它，已开始的突发不打断。
wire controller_busy;
sdram_refresh_admission u_refresh_admission (
    .clk(Clk), .rst(Rst), .init_done(Sdr_init_done),
    .controller_busy(controller_busy), .app_busy(Sdr_busy)
);

sdr_as_ram  #( .self_refresh_open(1'b1))
	u2_ram( 
		.Sdr_clk(Clk),
		.Sdr_clk_sft(Clk_sft),
		.Rst(Rst),
			  			  
		.Sdr_init_done(Sdr_init_done),
		.Sdr_init_ref_vld(Sdr_init_ref_vld),
		.Sdr_busy(controller_busy),
		
		.App_ref_req(1'b0),
		
        .App_wr_en(App_wr_en), 
        .App_wr_addr(App_wr_addr),  	
		.App_wr_dm(App_wr_dm),
		.App_wr_din(App_wr_din),

		.App_rd_en(App_rd_en),
		.App_rd_addr(App_rd_addr),
		.Sdr_rd_en	(Sdr_rd_en),
		.Sdr_rd_dout(Sdr_rd_dout),
	
		.SDRAM_CLK(SDRAM_CLK),
		.SDR_RAS(SDR_RAS),
		.SDR_CAS(SDR_CAS),
		.SDR_WE(SDR_WE),
		.SDR_BA(SDR_BA),
		.SDR_ADDR(SDR_ADDR),
		.SDR_DM(SDR_DM),
		.SDR_DQ(SDR_DQ)	
	);


assign SDR_CKE=1'b1;

//`ifndef SIMULATION
	EG_PHY_SDRAM_2M_32 sdram(
		.clk(SDRAM_CLK),
		.ras_n(SDR_RAS),
		.cas_n(SDR_CAS),
		.we_n(SDR_WE),
		.addr(SDR_ADDR[10:0]),
		.ba(SDR_BA),
		.dq(SDR_DQ),
		.cs_n(1'b0),
		.dm0(SDR_DM[0]),
		.dm1(SDR_DM[1]),
		.dm2(SDR_DM[2]),
		.dm3(SDR_DM[3]),
		.cke(1'b1)
		);
//`endif

endmodule

// 移植自参考工程：在控制器周期刷新前后预留安静窗口。
// 本计数器与 sdr_init_ref 的 init_cnt 都在 init_done 后第一拍从 0 开始、周期相同，所以无需跨时钟信号即可对齐。
// 刷新请求在槽内第 SELF_REFRESH_INTERVAL-10 拍发出；读写突发最长 128 拍，提前 128+64 拍停止准入，刷新后再等 32 拍。
module sdram_refresh_admission (
    input wire clk,
    input wire rst,
    input wire init_done,
    input wire controller_busy,
    output wire app_busy
);
    localparam integer MAX_APP_BURST = 128;
    localparam integer PIPELINE_MARGIN = 64;
    localparam integer POST_REFRESH_GUARD = 32;
    localparam integer PRE_REFRESH_GUARD = MAX_APP_BURST + PIPELINE_MARGIN;
    reg [13:0] slot_count;
    always @(posedge clk) begin
        if(rst || !init_done)
            slot_count <= 14'd0;
        else if(slot_count == (`SELF_REFRESH_INTERVAL-1))
            slot_count <= 14'd0;
        else
            slot_count <= slot_count + 1'b1;
    end
    assign app_busy = controller_busy || !init_done ||
        slot_count >= (`SELF_REFRESH_INTERVAL-PRE_REFRESH_GUARD) ||
        slot_count < POST_REFRESH_GUARD;
endmodule 