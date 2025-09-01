`include "final_top.v"
`timescale 1ms / 1ms

module genclk(output reg clk);
	initial begin
		clk = 0;
		forever #5 clk = ~clk;
	end	
endmodule

`timescale 1s / 1s
module tb;
	///////////////////////////////////
	//		TESTBENCH GENERATE SIGNALS
	reg [7:0]	tb_byte,
				tb_zero = "0";
	wire 		tb_clk;
	reg			tb_n_rst=1,
				tb_wr=0,
				tb_rd=0;

	///////////////////////////////////
	

	///////////////////////////////////
	//		UART WIRES
	wire [7:0]	uart_out;
	wire 		uart_tx,
				uart_rx_empty,
				uart_tx_empty,	
				uart_rx_fifo_valid;
	///////////////////////////////////
	

	///////////////////////////////////
	//		TOP WIRES
	wire [3:0]	top_status;
	wire 		top_tx;	
	///////////////////////////////////
	
	genclk genclk_inst( tb_clk );

	uart #(
		.FIFO_DEPTH		(	32					),
		.BAUND_RATE		(	9600				)
	)	uart_tb			(
		.clk			(	tb_clk				),
		.reset			(	~tb_n_rst			),
		.rx				(	top_tx				),
		.wr_data		(	tb_wr				),
		.rd_data		(	tb_rd				),
		.data_in		(	tb_byte				),

		.tx				(	uart_tx				),
		.data_out		(	uart_out			),
		.rx_empty		(	uart_rx_empty		),	
		.tx_empty		(	uart_tx_empty		),
		.rx_fifo_valid	(	uart_rx_fifo_valid	)
	);


	top top_inst(
		.clk_50mhz	( tb_clk		),
		.n_reset	( tb_n_rst		),
		.rx			( uart_tx		),

		.tx			( top_tx		),
		.status		( top_status	)
	);	



	initial begin
		DO_RESET();

		$display("waiting for ready interface");
		wait(top_status[3]);

		$display("waiting for uart ready");
		wait(top_inst.uart_ready);
		if ($test$plusargs("WRITE_CMD_TEST")) begin
			WRITE("W", "2", "3", "0", "2", "5", "8");	
			wait(top_inst.cmd_read ^ top_inst.cmd_write);
			if (top_inst.cmd_data[15:8]	== "2") 
				if (top_inst.cmd_data[7:0]	== "3") 
					if (top_inst.cmd_address[24:23]	== tb_zero[1:0])
						if (top_inst.cmd_address[22:15]	== "2") 
							if (top_inst.cmd_address[14:7]	== "5") 
							   if (top_inst.cmd_address[6:0] == "8")	
								   	$display("WRITE SUCCESS");
							   else $display("WRITE FAIL, ADDRESS[6:0]");
							else $display("WRITE FAIL: ADDRESS[14:7]");
						else $display("WRITE FAIL: ADDR[22:15]");
					else $display("WRITE FAIL: ADDR[24:23]");
				else $display("WRITE FAIL: DATA[7:0]");
			 else $display("WRITE FAIL: DATA[15:8]");
		end	

		if ($test$plusargs("READ_CMD_TEST")) begin
			WRITE("R", "0", "3", "8", "6", 0, 0);
			wait(top_inst.cmd_read ^ top_inst.cmd_write);
			if (top_inst.cmd_address[24:23]	== "0") 
				if (top_inst.cmd_address[22:15]	== "3") 
					if (top_inst.cmd_address[14:7]	== "8") 
						if (top_inst.cmd_address[6:0] 	== "6") 
							$display("READ SUCCESS");
						else $display("READ FAIL: ADDR[6:0]");
					else $display("READ FAIL: ADDR[14:7]");
				else $display("READ FAIL: ADDR[22:15]"); 
			else $display("READ FAIL: ADDR[24:23]", tb_zero[1:0]);
		end	

		if ($test$plusargs("BYTE2X1_TEST")) begin
			WRITE("R", "0", "3", "8", "6", 0, 0);
			wait(top_inst.sdram_valid);
			while (top_inst.sdram_valid) begin
				force top_inst.sdram_inst.DRAM_DQ = 16'h0204;	
				@(posedge tb_clk);	
			end
			release top_inst.sdram_inst.DRAM_DQ;
			#10000; //waiting for tb_uart receive
		end


		$stop;

		
	end	


	task DO_RESET;
		begin
			tb_n_rst = 0;
			@(posedge tb_clk);
			#0;
			tb_n_rst = 1;
			@(posedge tb_clk);
			#0;
		end
	endtask


	task WRITE(
		input [7:0]	mode,
					data0,
					data1,
					bank,
					addr0,
					addr1,
					addr2
	);
		begin
			byte_write(mode);
			byte_write(data0);
			byte_write(data1);
			byte_write(bank);
			byte_write(addr0);
			byte_write(addr1);
			byte_write(addr2);	
		end
	endtask
	
	task byte_write(
		input [7:0]	byte_in
	);
		begin
			tb_wr 	= 1;
			tb_byte = byte_in; 
			@(posedge tb_clk);
			#0;
			tb_wr	= 0;
			@(posedge tb_clk);
			#0;
		end
	endtask

endmodule
