`timescale 1ns/1ps

// Simulation stand-ins for the external modules final_top uses.
// They only model the port behaviour final_top relies on.

/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

// PLL: passes the input clock through and locks after a few cycles.
module pll(
	input		inclk0,
				areset,
	output		c0,
	output reg	locked
);
	integer n = 0;
	assign c0 = inclk0;
	always @(posedge inclk0 or posedge areset)
		if (areset) begin
			n		<= 0;
			locked	<= 0;
		end
		else begin
			n		<= n + 1;
			locked	<= n >= 20;
		end
endmodule

// UART: the testbench injects received bytes with rx_push() and reads
// transmitted bytes from tx_log. tx_empty drops for TX_BYTE_CYCLES per
// queued byte to mimic a slow line.
module uart #(
	parameter	FIFO_DEPTH		= 32,
				BAUND_RATE		= 9600,
				TX_BYTE_CYCLES	= 40
)(
	input				clk,
						reset,
						rx,
	output				tx,
	output reg [7:0]	data_out,
	input	   [7:0]	data_in,
	input				wr_data,
						rd_data,
	output				rx_empty,
						tx_empty,
	output reg			rx_fifo_valid,
	output				ready
);
	assign tx		= 1'b1;
	assign rx_empty	= 1'b1;
	assign ready	= 1'b1;

	reg [7:0]	tx_log [0:65535];
	integer		tx_count = 0;
	integer		tx_level = 0;		// bytes in the TX FIFO
	integer		tx_timer = 0;
	integer		tx_overflow = 0;

	assign tx_empty = tx_level == 0;

	initial begin
		rx_fifo_valid	= 0;
		data_out		= 0;
	end

	task rx_push(input [7:0] b);
		begin
			@(posedge clk);
			data_out		<= b;
			rx_fifo_valid	<= 1;
			@(posedge clk);
			rx_fifo_valid	<= 0;
			repeat (3) @(posedge clk);
		end
	endtask

	always @(posedge clk) begin
		if (wr_data) begin
			if (tx_level >= FIFO_DEPTH)
				tx_overflow = tx_overflow + 1;
			else begin
				tx_log[tx_count] = data_in;
				tx_count = tx_count + 1;
				tx_level = tx_level + 1;
			end
		end
		if (tx_level > 0) begin
			tx_timer = tx_timer + 1;
			if (tx_timer == TX_BYTE_CYCLES) begin
				tx_timer = 0;
				tx_level = tx_level - 1;
			end
		end
	end
endmodule
