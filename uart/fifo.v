
`ifndef FIFO
	`define FIFO
	module fifo #
		(
		parameter N=8,
				  W=8
		)(
		output [W-1:0] data_out, 
		output full, empty,
		input [W-1:0] in,
		input clk, reset, do_push, do_pop 
	);

			
		localparam EMPTY=0, PROC=1, FULL=2;	

		reg write_en=1;	
		reg [1:0] state;
		
		reg [log(N):0] write_addr, read_addr;	
		wire [log(N):0] nxt_write_addr = write_addr + 2'd1;
		wire [log(N):0] nxt_read_addr = read_addr + 2'd1;
		reg [W-1:0] mem [0:N-1];
		always @(posedge clk) 
			if (write_en) mem[write_addr] <= in;
		
		assign data_out = mem[read_addr];
		assign full = state == FULL;
		assign empty = state == EMPTY;
		
		always @(posedge clk, posedge reset) begin
			if (reset) begin
				write_addr <= 0; 
				read_addr <= 0; 
				write_en <= 1;	
				state <= 0;
			end	
			else begin
				case (state) 
					EMPTY: begin
						if (do_push) begin
							write_addr <= nxt_write_addr;
							state <= PROC;
						end
					end
					PROC: begin
						if (do_push) begin
							write_addr <= nxt_write_addr;
							if (nxt_write_addr == read_addr) begin
								state <= FULL;
								write_en <= 0;
							end	
						end
						if (do_pop) begin
							read_addr <= nxt_read_addr;
							if (nxt_read_addr == write_addr) 
								state <= EMPTY;
						end
					end
					FULL: begin
						if (do_pop) begin
							read_addr <= nxt_read_addr;
							state <= PROC;
							write_en <= 1;
						end
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
