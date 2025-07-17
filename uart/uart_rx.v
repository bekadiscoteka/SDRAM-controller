`ifndef UART_RX
	`define UART_RX
	`include "uart/division.v"
	module uart_rx #(
		parameter DBIT=8,
				  S=16,
				  SB_TICK=16
	)
	(
		output reg [7:0] d_out,
		output wire [31:0] m_out,
		output ready,
		output reg done_tick,
		output wire detect_done_tick,
		input rx, s_tick,
		input clk, reset
	);

		localparam IDLE=0,
				   START=1,
				   DATA=2,
				   STOP=3;

		localparam BAUND_DETECT=0,
				   OPERATE=1;
		reg [log(S):0] s_operate_reg;
		reg [7:0] cycle;
		reg [31:0] temp_cycle_per_byte, cycle_per_byte;
		reg [log(DBIT):0] n;
		reg div_start;
		reg state;
		reg [1:0] operate_state, baund_detect_state;

		division #(.W(32)) divide (
			.clk(clk),
			.reset(reset),
			.start(div_start),
			.done_tick(detect_done_tick),
			.dvnd(cycle_per_byte),
			.dvsr(S),
			.quo(m_out)
		);



		assign ready = (state == OPERATE) && (operate_state == IDLE);
		always @(posedge clk, posedge reset) begin
			if (reset) begin
				temp_cycle_per_byte <= 0;
				cycle_per_byte <= 0;
				cycle <= 0;
				div_start <= 0;
				operate_state <= IDLE;
				baund_detect_state <= IDLE;	
				s_operate_reg <= 0;				
				d_out <= 0;
				state <= BAUND_DETECT;
				n <= 0;
				done_tick <= 0;
			end
			else begin
				case (state)
					BAUND_DETECT: begin
						case (baund_detect_state) 
							IDLE: if (!rx) baund_detect_state <= DATA;
							DATA: begin
								if (cycle == 8) begin
									cycle <= 0;
									if (!rx) cycle_per_byte <= temp_cycle_per_byte + 1;
									temp_cycle_per_byte <= 
										temp_cycle_per_byte + 1;	//this part is very sensitive
									if (temp_cycle_per_byte == 
										(100000)) begin //dont touch, very sensitive 
										//slowest baund can be 500 baund, i dont know why
									   	baund_detect_state <= STOP;
										cycle <= 0;
										$display("cycle per byte: %d", cycle_per_byte);
									end
								end
								else if (!rx) begin
								   	cycle_per_byte <= temp_cycle_per_byte;
									cycle <= cycle + 1;
								end

								else cycle <= cycle + 1;
								
							end
							STOP: begin
								div_start <= 1;	
								$display(divide.counter);
								if (detect_done_tick) begin
									$display(divide.quo);
									div_start <= 0;
									state <= OPERATE;
									baund_detect_state <= IDLE;
								end
							end
						endcase
					end
					OPERATE: begin
						case (operate_state) 
							IDLE: begin
								s_operate_reg <= 0;
								d_out <= 0;
								n <= 0;
								done_tick <= 0;
								if (!rx) operate_state <= START;
							end
							START: begin
								if (s_tick) begin
									if (s_operate_reg >= (S/2)-1) begin
										operate_state <= DATA;
										s_operate_reg <= 0;
									end
									else s_operate_reg <= s_operate_reg +1;
								end

							end
							DATA: begin
								if (s_tick) begin
									if (s_operate_reg == S-1) begin
										s_operate_reg <= 0;
										d_out <= {rx, d_out[DBIT-1:1]};
										if (n == DBIT-1) operate_state <= STOP;
										else n <= n + 1;
									end	
									else s_operate_reg <= s_operate_reg + 1;	
								end	
							end
							STOP: begin
								if (s_tick) begin
									if (s_operate_reg == SB_TICK-1) begin
										done_tick <= 1;
										operate_state <= IDLE;
									end							
									s_operate_reg <= s_operate_reg + 1;
								end
							end
						endcase
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
