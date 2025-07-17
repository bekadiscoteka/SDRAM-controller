`include "interface.v"
`include "uart/uart.v"


module top(
						// top state
	output		ready,
					rx_empty,
						// uart 
	output		tx,
	input			rx,
	input 		clk_50MHz, 
					reset,
					cmd_start,

						// SDRAM connections
	inout  [15:0] 	DRAM_DQ,
	output [12:0]	DRAM_ADDR,	
	output [1:0] 	DRAM_BA,
	output  	DRAM_CLK,
	output 		DRAM_CKE,

			
	output 		DRAM_LDQM,  		
			DRAM_HDQM,
			DRAM_nWE,
			DRAM_nCAS,
			DRAM_nRAS,
			DRAM_nCS
);

	//pll
	
	pll	pll_inst (
	.areset (reset),
	.inclk0 (clk_50MHz),
	.c0 (clk_133MHz),
	.locked (pll_ready)
	);
	
	//edge detector for start
	edge_detector #(
	.MODE("FALL")
	) detect_inst (
	.clk(clk_133MHz),
	.reset(reset),
	.in(cmd_start),
	.tick(cmd_start_tick),
	);

	// initialization of connection wires 
	
	wire	[15:0]	sdram_data_out;

	wire	[7:0]	uart_out,
			cmd_address,
			cmd_data;
			

	wire	clk_133MHz,	
			sdram_valid,
			sdram_ready,
			fetch,
			//rx_empty,
			tx_empty, 
			uart_ready,
			cmd_read,
			cmd_write,
			cmd_ready,
			pll_ready;


				
	// end
	assign ready = uart_ready && cmd_ready && sdram_ready && pll_ready; 

	uart uart_unit(
		.clk(clk_133MHz),
		.reset(reset),
		.rx(rx),
		.tx(tx),
		
		.data_out(uart_out),
		.data_in(sdram_data_out[7:0]),
		.wr_data(sdram_valid),
		.rd_data(fetch),

		.rx_empty(rx_empty),	
		.tx_empty(tx_empty), // verification 
		.ready(uart_ready)
	);


	cmd_decoder cmd_unit(
		.clk(clk_133MHz),
		.reset(reset),
		.ready(cmd_ready),
		
		.cmd(uart_out),
		.start(cmd_start_tick),
					// connections for sdram
		.write(cmd_write),
		.read(cmd_read),
		.address(cmd_address),
		.data(cmd_data),
		
					// connections for uart
		.fetch(fetch)
	);


	sdram_interface SDR_INTF(
		.clk(clk_133MHz),
		.reset(reset),

		.data_in({8'b0, cmd_data}),    // in order to simplify, we took only MSB 
		.address({17'b0, cmd_address}),
		.data_out(sdram_data_out),
		.write(cmd_write),
		.read(cmd_read),
		
		.valid(sdram_valid),
		.ready(sdram_ready),

					// SDRAM connections
		.DRAM_DQ(DRAM_DQ),
		.DRAM_ADDR(DRAM_ADDR),	
		.DRAM_BA(DRAM_BA),
		.DRAM_CLK(DRAM_CLK),
		.DRAM_CKE(DRAM_CKE),
		.DRAM_LDQM(DRAM_LDQM),  		
		.DRAM_HDQM(DRAM_HDQM),
		.DRAM_nWE(DRAM_nWE),
		.DRAM_nCAS(DRAM_nCAS),
		.DRAM_nRAS(DRAM_nRAS),
		.DRAM_nCS(DRAM_nCS)
	);

	
endmodule

module cmd_decoder(
	output reg	[7:0]	address,
       				data,	
	output reg		write,
				read,
		 		fetch,
				ready,
				valid, // for verification

	input	[7:0]	cmd,	
	input 		clk, 
			reset,
			start
);	
	localparam [2:0]	IDLE=0,
				ADDR=1,
				VALUE=2,
				FINAL=3,
				OPER=4;

	reg [2:0]	state;
	reg [7:0]	_data,
			_address;
	reg 		_write,
			_read;


	always @(posedge clk, posedge reset) begin
		if (reset) begin
			state <= IDLE;

			address <= 0;
			_address <= 0;

			_data <= 0;
			data <= 0;

			_write <= 0;
			write <= 0;

			read <= 0;
			_read <= 0;

			fetch <= 0;
			ready <= 0;
		end
		else begin
			case (state) 
				IDLE: begin
					valid <= 0;
					read  <= 0;
					write <= 0;

					_read  <= 0;
					_write <= 0;

					if (start) begin
						state <= OPER;
						fetch <= 1;
						ready <= 0;
					end
					else begin
						fetch <= 0;
						ready <= 1;
					end
				end
				OPER: begin
					if (cmd == "r" | cmd == "R") begin
					       	state <= ADDR;
						_read <= 1;
					end
					else if (cmd == "w" | cmd == "W") begin
						state <= VALUE;
						_write <= 1;
					end
				end
				ADDR: begin
					_address <= cmd;
					state <= FINAL;
				end
				VALUE: begin
					_data <= cmd;
					state <= ADDR;
				end
				FINAL: begin
					data <= _data;
					address <= _address;
					write <= _write;
					read <= _read;
					state <= IDLE;
					valid <= 1;
				end
			endcase
		end
	end	
endmodule
