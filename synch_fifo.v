`ifndef SYNC_FIFO
`define SYNC_FIFO
module synch_fifo #(parameter DEPTH=8, DATA_WIDTH=8) (
	  input clk, rst_n,
	  input w_en, r_en,
	  input [DATA_WIDTH-1:0] data_in,
	  output reg [DATA_WIDTH-1:0] data_out,
	  output full, empty,
	  output reg valid
	);
	  
	  reg [log2(DEPTH)-1:0] w_ptr, r_ptr;
	  reg [DATA_WIDTH-1:0] fifo[0:DEPTH];
	  
	  
	  // To write data to FIFO
	  always@(posedge clk) begin
		 if(!rst_n) begin
	      		w_ptr <= 0; r_ptr <= 0;
	      		data_out <= 0;
	      		valid <= 0;
	    end
	    else begin 
			if(w_en & !full)begin
				fifo[w_ptr] <= data_in;
				w_ptr <= w_ptr + 1;
			end
			if(r_en & !empty) begin
				data_out <= fifo[r_ptr];
				r_ptr <= r_ptr + 1;
				valid <= 1;
			 end
			if (r_en & empty) begin
				 data_out <= 0;
				 valid <= 0;
			 end
		end
	  end
	  
	assign full = ((w_ptr+1'b1) == r_ptr);
	assign empty = (w_ptr == r_ptr);


	function integer log2;
		input integer arg;
		integer i;
		begin: loop
			for (i=0; i <= 31; i = i + 1) begin
				if (2**i > arg) begin
					log2 = i;
					disable loop;
				end
			end
		end
	endfunction
endmodule
`endif
