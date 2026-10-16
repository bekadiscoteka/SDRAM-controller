`timescale 1ns/1ps

// Synchronous first-word-fall-through FIFO.
//
// - data_out/valid always present the oldest entry; r_en while valid pops it.
// - Storage is a simple dual-port RAM with a registered read, so Quartus can
//   map it to M9K blocks. Two output registers sit behind the RAM, which gives
//   one pop per cycle sustained and DEPTH+1 entries of total capacity.
// - Writes while full are dropped. Pops while !valid are ignored.
// - DEPTH must be a power of two.
// - rst_n is a synchronous, active-low reset.

module synch_fifo #(
	parameter	DEPTH		= 8,
				DATA_WIDTH	= 8
)(
	input							clk,
									rst_n,
	input							w_en,
									r_en,
	input		[DATA_WIDTH-1:0]	data_in,
	output reg	[DATA_WIDTH-1:0]	data_out,
	output							full,
									empty,
	output reg						valid
);
	localparam AW = (DEPTH > 1) ? $clog2(DEPTH) : 1;

	reg [DATA_WIDTH-1:0]	mem [0:DEPTH-1];
	reg [AW-1:0]			w_ptr,
							r_ptr;

	reg [DATA_WIDTH-1:0]	q;			// RAM read register
	reg 					q_valid;

	wire ram_empty	= (w_ptr == r_ptr);
	assign full		= (w_ptr + 1'b1) == r_ptr;
	assign empty	= !valid;

	wire pop		= r_en && valid;
	wire out_load	= q_valid && (!valid || pop);	// q -> data_out
	wire ram_rd		= !ram_empty && (!q_valid || out_load);	// mem -> q

	// RAM (kept free of reset so it infers as block memory)
	always @(posedge clk) begin
		if (w_en && !full)
			mem[w_ptr] <= data_in;
		if (ram_rd)
			q <= mem[r_ptr];
	end

	always @(posedge clk) begin
		if (!rst_n) begin
			w_ptr		<= 0;
			r_ptr		<= 0;
			q_valid		<= 0;
			valid		<= 0;
			data_out	<= 0;
		end
		else begin
			if (w_en && !full)
				w_ptr <= w_ptr + 1'b1;

			if (ram_rd)
				r_ptr <= r_ptr + 1'b1;

			if (ram_rd)			q_valid <= 1;
			else if (out_load)	q_valid <= 0;

			if (out_load) begin
				data_out	<= q;
				valid		<= 1;
			end
			else if (pop)
				valid		<= 0;
		end
	end

endmodule
