`include "uart/uart_rx.v"
`include "uart/uart_tx.v"
`include "uart/m_counter.v"
`include "uart/fifo.v"
`ifndef UART
	`define UART
	module uart	
		#(
			parameter WIDTH=8,
					SB_TICK=16,
					
					S=16,
					BAUND_RATE=9600,

					FIFO_DEPTH=8
		)
		(
			output [WIDTH-1:0] data_out,
			output 	tx_full, tx_empty, tx, 
					rx_full, rx_empty, rx_done_tick,
					ready,
			input [WIDTH-1:0] data_in,
			input wr_data, rd_data, rx, clk, reset
	);
		wire tx_done_tick,
			 rx_ready,
			 s_tick;
		assign ready = rx_ready;
		wire [WIDTH-1:0] tx_data, rx_data;	

		wire detect_done_tick;
		wire [31:0] m;
		
		rx_specific_counter #(.INITIAL_M(compute_m(BAUND_RATE, S))) 
		counter(
			.tick(s_tick),
			.clk(clk),
			.reset(reset),
			.m(m),
			.set_m(detect_done_tick)
		);	
			
		fifo #(.W(WIDTH), .N(FIFO_DEPTH)) tx_fifo(
			.clk(clk),
			.reset(reset),
			.do_push(wr_data),
			.do_pop(tx_done_tick),
			.full(tx_full),
			.empty(tx_empty),
			.in(data_in),
			.data_out(tx_data)
		);	

		fifo #(.W(WIDTH), .N(FIFO_DEPTH)) rx_fifo(
			.clk(clk),
			.reset(reset),
			.do_push(rx_done_tick),
			.do_pop(rd_data),
			.data_out(data_out),
			.in(rx_data),
			.full(rx_full),
			.empty(rx_empty)
		);

		uart_rx #(.DBIT(WIDTH), .SB_TICK(SB_TICK), .S(S)) rx_inst(
			.clk(clk),
			.reset(reset),
			.d_out(rx_data),
			.rx(rx),
			.s_tick(s_tick),	
			.done_tick(rx_done_tick),
			.detect_done_tick(detect_done_tick),
			.m_out(m),
			.ready(rx_ready)
		);

		uart_tx #(.DBIT(WIDTH), .SB_TICK(SB_TICK), .S(S)) tx_inst(
			.clk(clk),
			.reset(reset),
			.d_in(tx_data), 
			.tx(tx),
			.start((~tx_empty && ~tx_done_tick)),
			.s_tick(s_tick),
			.done_tick(tx_done_tick)
		);

	function integer compute_m(input [31:0] baund_r, sample);
		begin
			compute_m = 32'd133_000_000 / (baund_r * sample);
		end
	endfunction
	endmodule
`endif
