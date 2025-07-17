`ifndef EDGE_DETECT
	`define EDGE_DETECT
	module edge_detector(
		output reg tick,
		input reset, clk, in
	);
		parameter MODE="RISE"; //rise edge by default

		localparam 
		UNKNOWN=0,
		LOW=1,	
		HIGH=2,
		TICK=3;

		reg [1:0] state;

		always @(posedge clk, posedge reset) begin
			if (reset) begin
			   	state <= 0;
				tick <= 0;
				state <= UNKNOWN;
		   	end
			else begin
				case (MODE) 
					"RISE": begin
						case (state) 
							UNKNOWN, HIGH: state <= in ? HIGH : LOW;
							LOW: begin
								if (in) begin
									state <= TICK;
									tick <= 1;
								end
								else state <= LOW;
							end
							TICK: begin
								tick <= 0;
								state <= in ? HIGH : LOW;
							end
						endcase
					end
					"FALL": begin
					case (state)
						UNKNOWN, LOW: state <= in ? HIGH : LOW;
						HIGH: begin
							if (~in) begin
								state <= TICK;
								tick <= 1;
							end
							else state <= HIGH; 
						end
						TICK: begin
							tick <= 0;
							state <= in ? HIGH : LOW;
						end
						endcase
					end
				endcase
			end
		end
	endmodule
`endif
