`ifndef M_COUNT
	`define M_COUNT
	module rx_specific_counter(
		output reg [15:0] counter,
		output reg tick,
		input clk, reset,
		input set_m,
		input [31:0] m
	);
		parameter INITIAL_M=166;
		reg [31:0] _m;
		always @(posedge clk, posedge reset) begin
			if (reset) begin
				counter <= 0;
				tick <= 0;
				_m <= INITIAL_M; 
			end
			else if (set_m) _m <= m; 
			else begin
				if (counter == _m) begin
					counter <= 0;
					tick <= 1;
				end
				else begin
					counter <= counter + 1;
					tick <= 0;
				end
			end
		end
	endmodule
`endif
