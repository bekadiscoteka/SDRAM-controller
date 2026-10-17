`timescale 1ns/1ps

// DE10-Lite demo: SDRAM access over UART.
//
//   host -> "W" d1 d0 bank a2 a1 a0   write 16-bit word {d1,d0}
//   host -> "R" bank a2 a1 a0         read, returns BURST_LENGTH words,
//                                     each as two bytes, LSB first
//
// External modules, not part of this repository:
//   uart  UART with RX/TX FIFOs (expected at uart/uart.v)
//   pll   Quartus ALTPLL, 50 MHz in -> 133 MHz c0
//
// status_leds = {sdram ready, pll locked, command in progress, error}
// error is the parser error (bad command byte) or a sticky overflow:
// a command dropped because the controller FIFO was full, or read data
// dropped because the read buffer was full.

module final_top(
	output 				tx,
	output wire [3:0] 	status_leds,
	input 				rx,
						clk_50mhz,
						reset_n,
						sdram_start,		// commands run only while high

	// SDRAM
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
);
	localparam	BURST_LENGTH	= 4,
				RD_BUFF_DEPTH	= 512;

	// ------------------------------------------------------------------
	// clock and reset
	// ------------------------------------------------------------------
	wire	clk_133mhz,
			pll_ready;

	pll	pll_inst(
		.inclk0	( clk_50mhz		),
		.areset	( ~reset_n		),
		.c0		( clk_133mhz	),
		.locked	( pll_ready 	)
	);

	// asserted asynchronously, released synchronously once the PLL is locked
	wire		arst_n = reset_n && pll_ready;
	reg [2:0]	rst_sync;
	always @(posedge clk_133mhz or negedge arst_n) begin
		if (!arst_n)	rst_sync <= 3'b111;
		else			rst_sync <= {rst_sync[1:0], 1'b0};
	end
	wire	reset = rst_sync[2];

	// ------------------------------------------------------------------
	// UART
	// ------------------------------------------------------------------
	/* verilator lint_off UNUSEDSIGNAL */
	wire			rx_empty,
					uart_ready;
	/* verilator lint_on UNUSEDSIGNAL */
	wire			tx_empty,
					rx_fifo_valid;
	wire	[7:0]	uart_out;
	wire 	[7:0]	conv_byte;
	wire 			conv_valid,
					conv_fetch;

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

	// ------------------------------------------------------------------
	// command parser
	// ------------------------------------------------------------------
	wire	[15:0]	cmd_data;
	wire	[24:0]	cmd_address;
	wire			cmd_write,
					cmd_read,
					cmd_error,
					cmd_processing;

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

	// ------------------------------------------------------------------
	// SDRAM controller
	// ------------------------------------------------------------------
	wire			sdram_valid,
					sdram_ready;
	wire	[15:0]	sdram_data_out;

	sdram_interface #(
		.CLK_FREQ		( 133			),
		.BURST_WR_MODE	( 1				),
		.BURST_LENGTH	( BURST_LENGTH	),
		.BURST_TYPE		( "SEQ"			),
		.USE_START		( 1				)
	)	sdram_inst	(
		.clk		(	clk_133mhz		),
		.reset		(	reset			),
		.start		(	sdram_start		),
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

	// ------------------------------------------------------------------
	// read data -> bytes -> UART TX
	// ------------------------------------------------------------------
	wire	[15:0]	sdram_buff_out;
	wire 			sdram_buff_valid,
					sdram_buff_full;

	synch_fifo #(
		.DEPTH		( RD_BUFF_DEPTH	),
		.DATA_WIDTH	( 16			)
	) sdram_buff_inst (
		.clk		( clk_133mhz		),
		.rst_n		( !reset			),
	   	.w_en		( sdram_valid		),
		.r_en		( conv_fetch		),
		.data_in	( sdram_data_out	),
		.data_out	( sdram_buff_out	),
		.full		( sdram_buff_full	),
		.empty		( 					),
		.valid		( sdram_buff_valid	)
	);

	// a new word is only started while the UART TX FIFO is empty, so the two
	// bytes of a word always fit
	byte_2x1 converter(
		.clk		( clk_133mhz		),
		.rst		( reset				),
		.wr_en		( sdram_buff_valid	),
		.tx_ready	( tx_empty			),
		.in			( sdram_buff_out	),
		.fetch		( conv_fetch		),
		.out		( conv_byte			),
		.valid		( conv_valid		)
	);

	// ------------------------------------------------------------------
	// status
	// ------------------------------------------------------------------
	reg	overflow;
	always @(posedge clk_133mhz or posedge reset) begin
		if (reset)
			overflow <= 0;
		else if ((sdram_valid && sdram_buff_full) || ((cmd_write || cmd_read) && !sdram_ready))
			overflow <= 1;
	end

	assign 	status_leds = {
				sdram_ready,
				pll_ready,
				cmd_processing,
				cmd_error || overflow
	};

endmodule
