`define TEST
`include "uart/uart.v"
`include "interface.v"
`include "synch_fifo.v"

module final_top(
	output 					tx,
	output wire [3:0] 	status_leds, 
	input 				rx,
						clk_50mhz,
						reset_n,
						
						`ifdef TEST
						sdram_start,
						`endif
			//			n_cmd_start,

	/////////////////////////////
	//		DRAM CONNECTIONS
	inout  [15:0] 		DRAM_DQ,
	output [12:0]		DRAM_ADDR,	
	output [1:0] 		DRAM_BA,
	output  			DRAM_CLK,
	output 				DRAM_CKE,

			
	output 				DRAM_LDQM,  		
						DRAM_HDQM,
						DRAM_nWE,
						DRAM_nCAS,
						DRAM_nRAS,
						DRAM_nCS
	////////////////////////////
		
);
	wire	reset = ~reset_n;

	////////////////////////////
	// 		PLL WIRES
	wire	clk_133mhz,
			pll_ready;
	////////////////////////////


	////////////////////////////
	// 		UART WIRES
	wire			rx_empty,
					tx_empty,
					rx_fifo_valid,
					uart_fetch,
					uart_ready;
	wire	[7:0]	uart_out;
	////////////////////////////



	////////////////////////////
	// 		SDRAM CONTROLLER WIRES
	wire			sdram_valid,
					sdram_ready;	
	wire	[15:0]	sdram_data_out;
	////////////////////////////


	////////////////////////////
	// 		CMD WIRES
	wire	[15:0]	cmd_data;
	wire	[24:0]	cmd_address;
	wire			cmd_write,
					cmd_error,
					cmd_processing,
					cmd_read;	
	////////////////////////////
	
	////////////////////////////
	//		SDRAM OUTPUT BUFFER WIRES
	wire	[15:0]	sdram_buff_out;
	wire 			sdram_buff_valid;
	////////////////////////////
	

	////////////////////////////
	//		2 TO 1 BYTE CONVERTER
	wire 	[7:0]	conv_byte;
	wire 			conv_valid,
					conv_fetch;
	////////////////////////////
	
	////////////////////////////
	//		DESIGN STATE TRACK
	assign 	status_leds = {
				sdram_ready,
				pll_ready,
				cmd_processing,
				cmd_error	
	};
	////////////////////////////	
	
	pll	pll_inst(
		.inclk0	( clk_50mhz		),
		.areset	( reset 		),
		.c0	( clk_133mhz	),
		.locked ( pll_ready 	)
	);		


	uart #(
		.FIFO_DEPTH		(	32			),
		.BAUND_RATE		(	9600		)
	)	uart_inst		(
		.clk			(	clk_133mhz		),
		.reset			(	reset			),
		.rx				(	rx				),
		.tx				(	tx				),
		
		.data_out		(	uart_out		),
		.data_in		(	conv_byte		),
		.wr_data		(	conv_valid		),
		.rd_data		(	1'b1			),

		.rx_empty		(	rx_empty		),	
		.tx_empty		(	tx_empty		),
		.rx_fifo_valid	(	rx_fifo_valid	),
		.ready			(	uart_ready		)
	);

	cmd	cmd_inst	(
		.clk		(	clk_133mhz		),
		.rst		(	reset			),
		.byte_in	(	uart_out		),
		.wr_en		(	rx_fifo_valid	),
		.write		(	cmd_write		),
		.read		(	cmd_read		),
		.data		(	cmd_data		),
		.address	(	cmd_address		),
		.processing	(	cmd_processing 	),
		.error		(	cmd_error		)
	);
	
	sdram_interface #(
		.BURST_WR_MODE(1),
		.BURST_LENGTH(4),
		.BURST_TYPE("SEQ")

	)	sdram_inst	(
		.clk		(	clk_133mhz		),
		.reset		(	reset			),
		.start		(	sdram_start			),
		.data_in	(	cmd_data 		),   
		.address	( 	cmd_address 	),
		.write		(	cmd_write		),
		.read		(	cmd_read		),
		.data_out	(	sdram_data_out 	),
		.valid		(	sdram_valid		),
		.ready		(	sdram_ready		),

		.DRAM_DQ	(	DRAM_DQ			),
		.DRAM_ADDR	(	DRAM_ADDR		),	
		.DRAM_BA	(	DRAM_BA			),
		.DRAM_CLK	(	DRAM_CLK		),
		.DRAM_CKE	(	DRAM_CKE		),
		.DRAM_LDQM	(	DRAM_LDQM		),  		
		.DRAM_HDQM	(	DRAM_HDQM		),
		.DRAM_nWE	(	DRAM_nWE		),
		.DRAM_nCAS	(	DRAM_nCAS		),
		.DRAM_nRAS	(	DRAM_nRAS		),
		.DRAM_nCS	(	DRAM_nCS		)
	);

	synch_fifo #(.DATA_WIDTH(16)) sdram_buff_inst(
		.clk		( clk_133mhz		),
		.rst_n		( reset_n			),
	   	.w_en		( sdram_valid		),
		.r_en		( conv_fetch		),
		.data_in	( sdram_data_out	),	
		.data_out	( sdram_buff_out	),
		.valid		( sdram_buff_valid	)
	);	

	byte_2x1 converter(
		.clk	( clk_133mhz		),
		.rst	( reset				),
		.wr_en	( sdram_buff_valid	),
		.in		( sdram_buff_out	),
		.fetch	( conv_fetch		),
		.out	( conv_byte			),
		.valid	( conv_valid		)
	);


endmodule


module byte_2x1(
	output	reg	[7:0]	out,
	output	reg 		valid,
	output 	wire 		fetch,
	input 				clk,
						rst,
						wr_en,
	input		[15:0]	in
);
	/////////////////////////////////
	//		STATE MACHINE
	//
	localparam	IDLE	=0,
				OUT_LSB	=1,
				OUT_MSB	=2;
	reg [1:0]	state;
	/////////////////////////////////
	

	reg	[7:0] 	msb;

	always @(posedge clk or posedge rst) begin
		if (rst) begin
		   	state	<= IDLE;
			valid	<= 0;
			out		<= 0;
		end
		else begin
			case (state) 

				IDLE: begin
					if (wr_en) begin
						msb		<= in[15:8];				
						state 	<= OUT_LSB;
						valid 	<= 1;
						out		<= in[7:0];
					end	
				end
			
				OUT_LSB: begin
						out 	<= msb;	
						state	<= OUT_MSB;
				end

				OUT_MSB: begin
						valid 	<= 0;
						state 	<= IDLE;
				end

			endcase
		end
	end

	/////////////////////////////
	//		FETCH LOGIC
	assign fetch = state == IDLE;
	/////////////////////////////
endmodule

module cmd(
	output	reg	[15:0]	data,
	output	reg [24:0]	address,
	output	reg			write,
						read,
						error,	
	output 	wire		processing,
	input		[7:0]	byte_in,
   	input				wr_en,
						clk,
						rst
					
);
	///////////////////////////
	//		STATE MACHINE
	localparam	IDLE			=0,

				BYTE_DATA0		=1,
				BYTE_DATA1		=2,

				BYTE_BANK		=3,	
				BYTE_ADDR0		=4,
				BYTE_ADDR1		=5,
				BYTE_ADDR2		=6;

					
	reg	[3:0]	state;
	///////////////////////////
	
	reg _write,
		_read;

	assign processing = state != IDLE;	

	always @(posedge clk or posedge rst) begin
		if (rst) begin
			state		<=	IDLE;
			data		<=	0;
			address		<=	0;
			write		<= 	0;
			read		<= 	0;
			_read		<= 	0;
			_write 		<= 	0;
			error 		<= 	0;
		end
		else begin
			case (state) 

				IDLE: begin
					NOT_VALID();
				   	if	(wr_en) begin
						if (byte_in == "W" || byte_in == "w") begin
							_write	<= 1;
							state 	<= BYTE_DATA0;
							error	<= 0;
						end
						else if	(byte_in == "R" || byte_in == "r") begin
							_read	<= 1;
							state 	<= BYTE_BANK;
							error 	<= 0;
						end
						else error	<= 1;
					end
				end

				BYTE_DATA0: begin
					if (wr_en) begin
						data[15:8]	<= byte_in;
					   	state		<= BYTE_DATA1;		
					end
				end

				BYTE_DATA1: begin
					if (wr_en) begin
						data[7:0]	<= byte_in;
						state		<= BYTE_BANK;
					end
				end

				BYTE_BANK: begin
					if (wr_en) begin
						address[24:23]	<= byte_in[1:0];
						state 			<= BYTE_ADDR0;	
					end
				end

				BYTE_ADDR0: begin
					if (wr_en) begin
						address[22:15]	<= byte_in;
						state			<= BYTE_ADDR1;
					end
				end

				BYTE_ADDR1: begin
					if (wr_en) begin
						address[14:7]	<= byte_in;
						state			<= BYTE_ADDR2;
					end
				end

				BYTE_ADDR2: begin
					if (wr_en) begin
						address[6:0]	<= byte_in[6:0];
						state			<= IDLE;
						VALID();
					end
				end

			endcase
		end
	end

	task VALID;
		begin
			write	<= _write;
			read 	<= _read;
			_write	<= 0;
			_read	<= 0;
		end
	endtask

	task NOT_VALID;
		begin
			write	<= 0;
			read 	<= 0;
		end
	endtask
	
endmodule


