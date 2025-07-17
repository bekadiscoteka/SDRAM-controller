`ifndef UART_TX
	`define UART_TX
	module uart_tx
		#( 
		parameter DBIT=8,
				  SB_TICK=16,
				  S=16
		)(
		output reg tx, done_tick,
		input clk, reset, start, 
		input s_tick,
		input [DBIT-1:0] d_in
	);

		localparam	IDLE=0, 
					START=1,
					DATA=2,
					STOP=3;
		
		reg [1:0] state;	
		reg [log(S):0] s_reg;	 
		reg [log(DBIT):0] n;
		reg [DBIT:0] in_reg; 
		always @(posedge clk, posedge reset) begin
			if (reset) begin
				tx <= 1'b1;
				n <= 0;
				s_reg <= 0;	
				done_tick <= 0;
				in_reg <= 0;
				state <= 0;
			end
			else begin
				case (state) 
					IDLE: begin
						tx <= 1;
						done_tick <= 0;
						in_reg <= d_in;
						if (start) begin
							n <= 0;
							s_reg <= 0;
							state <= START;
							tx <= 0;
						end
					end
					START: 
						if (s_tick) 
							if (s_reg == S-1) begin
								s_reg <= 0;
								state <= DATA;
								tx <= in_reg[0];
							end
							else s_reg <= s_reg + 1;
					DATA: 
						if (s_tick) 
							if (s_reg == S-1) begin
								s_reg <= 0;
								if (n == DBIT-1) begin
									state <= STOP;
									n <= 0;
									tx <= 1;
								end
								else begin
									in_reg <= in_reg >> 1;
									n <= n + 1;
								end
							end
							else begin
							   	s_reg <= s_reg + 1;
								tx <= in_reg[0];
							end
					STOP: 
						if (s_tick) begin
							if (s_reg == SB_TICK-1) begin
								state <= IDLE;
								s_reg <= 0;
								n <= 0;
								done_tick <= 1;
							end
							else s_reg <= s_reg + 1;
						end
				endcase
			end
		end

		function integer log;
			input [31:0] N;
			integer i;
			begin
				for (i=31; !N[31]; i = i-1) 
					N = N << 1;	
				log = i;	
			end	
		endfunction
				   
	endmodule
`endif

