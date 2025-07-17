//Divisor design
//width modifiable 
//testbench: division_testbench.v
`ifndef DIVISION
`define DIVISION

module division #(parameter W=8) (
	output reg [W-1:0] quo, rmd,
	output ready, done_tick,
	input [W-1:0] dvnd, dvsr,
	input clk, reset, start
);
	localparam [1:0]  
		READY=0,
		PROC=1,
		FINISH=2;
	reg [W*2-1:0] db_dvnd;
	reg [1:0] state;

	reg [W*2-1:0] nxt_db_dvnd;
	reg [1:0] nxt_state;
	reg [W-1:0] nxt_rmd;
	reg [W-1:0] nxt_quo;
	reg [9:0] nxt_counter;

	wire [W-1:0] temp_dvnd = db_dvnd[W*2-1:W];

	reg [9:0] counter;

	always @(posedge clk, posedge reset) begin
		if (reset) begin
			state <= 0;
			db_dvnd <= 0;
			rmd <= 0;
			counter <= 0;
			quo <= 0;
		end
		else begin
			counter <= nxt_counter;
			db_dvnd <= nxt_db_dvnd;
			state <= nxt_state;
			rmd <= nxt_rmd;
			quo <= nxt_quo;
		end
	end


	always @* begin
		case (state) 
			READY: begin
				nxt_state = start ? PROC : state;
				nxt_counter = 0;
				nxt_quo = 0;
				nxt_db_dvnd = {{W{1'b0}}, dvnd};
				nxt_rmd = 0;
			end
			PROC: begin
				nxt_counter = counter + 1;
				nxt_state = counter == W ? FINISH : state;
				if (temp_dvnd >= dvsr) begin
					nxt_rmd = temp_dvnd - dvsr;
					nxt_quo = quo << 1;
					nxt_quo[0] = 1;
					nxt_db_dvnd = {nxt_rmd, db_dvnd[W-1:0]} << 1;	
				end	
				else begin
					nxt_db_dvnd = db_dvnd << 1;
					nxt_quo = quo << 1;
					nxt_rmd = rmd;
				end
			end
			FINISH: begin
				nxt_state = READY;
				nxt_rmd = temp_dvnd;
				nxt_quo = quo;
				nxt_db_dvnd = db_dvnd;
				nxt_counter = counter;
			end
		endcase	
	end

	assign done_tick = state == FINISH;
	assign ready = state == READY;	
endmodule
`endif
