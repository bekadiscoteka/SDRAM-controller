`timescale 1ns/1ps

// Splits 16-bit words into two bytes, LSB first.
//
// in/wr_en is a first-word-fall-through source: the word is taken (and
// fetch pops it) when wr_en and tx_ready are both high while idle. valid is
// then high for two cycles, carrying the LSB and then the MSB.

module byte_2x1(
	output	reg	[7:0]	out,
	output	reg 		valid,
	output 	wire 		fetch,
	input 				clk,
						rst,
						wr_en,
						tx_ready,	// sink can take two bytes
	input		[15:0]	in
);
	localparam	IDLE	= 0,
				OUT_LSB	= 1,
				OUT_MSB	= 2;
	reg [1:0]	state;

	reg	[7:0] 	msb;

	assign fetch = state == IDLE && wr_en && tx_ready;

	always @(posedge clk or posedge rst) begin
		if (rst) begin
		   	state	<= IDLE;
			valid	<= 0;
			out		<= 0;
			msb		<= 0;
		end
		else begin
			case (state)
				IDLE: begin
					if (fetch) begin
						msb		<= in[15:8];
						out		<= in[7:0];
						valid 	<= 1;
						state 	<= OUT_LSB;
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

				default:
					state	<= IDLE;
			endcase
		end
	end

endmodule
