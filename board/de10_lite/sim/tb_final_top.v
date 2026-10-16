`timescale 1ns/1ps

// End-to-end test of final_top: UART commands in, SDRAM model behind the
// controller, bytes out of the UART. Uses the stand-ins from stubs.v.

module tb_final_top;

	localparam BL = 4;

	reg			clk = 0;
	reg			reset_n = 0;
	reg			sdram_start = 1;
	wire		tx;
	wire [3:0]	status;

	wire [15:0]	DRAM_DQ;
	wire [12:0]	DRAM_ADDR;
	wire [1:0]	DRAM_BA;
	wire		DRAM_CLK, DRAM_CKE, DRAM_LDQM, DRAM_HDQM,
				DRAM_nWE, DRAM_nCAS, DRAM_nRAS, DRAM_nCS;

	always #3.75 clk = ~clk;		// 133 MHz straight into the pass-through PLL

	final_top top (
		.tx(tx), .status_leds(status), .rx(1'b1),
		.clk_50mhz(clk), .reset_n(reset_n), .sdram_start(sdram_start),
		.DRAM_DQ(DRAM_DQ), .DRAM_ADDR(DRAM_ADDR), .DRAM_BA(DRAM_BA),
		.DRAM_CLK(DRAM_CLK), .DRAM_CKE(DRAM_CKE),
		.DRAM_LDQM(DRAM_LDQM), .DRAM_HDQM(DRAM_HDQM),
		.DRAM_nWE(DRAM_nWE), .DRAM_nCAS(DRAM_nCAS),
		.DRAM_nRAS(DRAM_nRAS), .DRAM_nCS(DRAM_nCS)
	);

	sdram_model #( .CLK_FREQ(133), .BOARD_DELAY(1) ) sdram (
		.DQ(DRAM_DQ), .A(DRAM_ADDR), .BA(DRAM_BA), .CLK(DRAM_CLK), .CKE(DRAM_CKE),
		.nCS(DRAM_nCS), .nRAS(DRAM_nRAS), .nCAS(DRAM_nCAS), .nWE(DRAM_nWE),
		.LDQM(DRAM_LDQM), .HDQM(DRAM_HDQM)
	);

	integer errors = 0;
	integer rx_idx = 0;		// next byte of tx_log to check

	task send_write(input [1:0] bank, input [12:0] row, input [9:0] col, input [15:0] d);
		reg [24:0] a;
		begin
			a = {bank, row, col};
			top.uart_inst.rx_push("W");
			top.uart_inst.rx_push(d[15:8]);
			top.uart_inst.rx_push(d[7:0]);
			top.uart_inst.rx_push({6'b0, a[24:23]});
			top.uart_inst.rx_push(a[22:15]);
			top.uart_inst.rx_push(a[14:7]);
			top.uart_inst.rx_push({1'b0, a[6:0]});
		end
	endtask

	task send_read(input [1:0] bank, input [12:0] row, input [9:0] col);
		reg [24:0] a;
		begin
			a = {bank, row, col};
			top.uart_inst.rx_push("r");
			top.uart_inst.rx_push({6'b0, a[24:23]});
			top.uart_inst.rx_push(a[22:15]);
			top.uart_inst.rx_push(a[14:7]);
			top.uart_inst.rx_push({1'b0, a[6:0]});
		end
	endtask

	// wait for one word (two bytes, LSB first) on the UART and check it
	task expect_word(input [15:0] d);
		integer t;
		begin
			t = 0;
			while (top.uart_inst.tx_count < rx_idx + 2 && t < 100000) begin
				@(posedge clk);
				t = t + 1;
			end
			if (top.uart_inst.tx_count < rx_idx + 2) begin
				errors = errors + 1;
				$display("TB ERROR: timeout waiting for word %h", d);
			end
			else if ({top.uart_inst.tx_log[rx_idx + 1], top.uart_inst.tx_log[rx_idx]} !== d) begin
				errors = errors + 1;
				$display("TB ERROR: got %h expected %h",
					{top.uart_inst.tx_log[rx_idx + 1], top.uart_inst.tx_log[rx_idx]}, d);
			end
			rx_idx = rx_idx + 2;
		end
	endtask

	integer i;
	initial begin
		repeat (5) @(posedge clk);
		reset_n = 1;

		wait (status[3]);		// sdram ready
		$display("TB: controller ready at %0t", $time);

		// four writes along one burst, then a read of the burst
		for (i = 0; i < BL; i = i + 1)
			send_write(2, 13'h1abc, 10'h040 + i, 16'h1200 + i * 16'h0101);
		send_read(2, 13'h1abc, 10'h040);
		for (i = 0; i < BL; i = i + 1)
			expect_word(16'h1200 + i * 16'h0101);

		// another bank and row, then back again
		send_write(1, 13'h0007, 10'h3fe, 16'hbeef);
		send_read(1, 13'h0007, 10'h3fc);
		expect_word(16'hxxxx);			// 3fc..3fd never written
		expect_word(16'hxxxx);
		expect_word(16'hbeef);
		expect_word(16'hxxxx);
		send_read(2, 13'h1abc, 10'h041);
		expect_word(16'h1301);
		expect_word(16'h1402);
		expect_word(16'h1503);
		expect_word(16'h1200);

		// several reads back to back: data must queue up and not be dropped
		for (i = 0; i < 6; i = i + 1)
			send_read(2, 13'h1abc, 10'h040);
		for (i = 0; i < 6 * BL; i = i + 1)
			expect_word(16'h1200 + (i % BL) * 16'h0101);

		// a bad command byte raises the error LED
		top.uart_inst.rx_push("x");
		repeat (5) @(posedge clk);
		if (!status[0]) begin
			errors = errors + 1;
			$display("TB ERROR: error LED not set");
		end

		repeat (100) @(posedge clk);
		if (top.uart_inst.tx_overflow != 0) begin
			errors = errors + 1;
			$display("TB ERROR: UART TX FIFO overflowed %0d times", top.uart_inst.tx_overflow);
		end
		if (top.uart_inst.tx_count != rx_idx) begin
			errors = errors + 1;
			$display("TB ERROR: %0d extra bytes on UART", top.uart_inst.tx_count - rx_idx);
		end

		if (errors == 0 && sdram.errors == 0)	$display("PASS");
		else $display("FAIL: %0d tb errors, %0d model errors", errors, sdram.errors);
		$finish;
	end

	initial begin
		#(50_000_000);
		$display("FAIL: timeout");
		$finish;
	end

endmodule
