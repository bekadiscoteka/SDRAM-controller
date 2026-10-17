// Self-checking testbench for sdram_interface against sdram_model.
//
// Drives random and directed traffic through the valid/ready interface,
// keeps a shadow copy of everything written and checks every read word.
// Pass/fail also requires zero protocol/timing errors from the model.
//
// Plusargs: +seed=N  +ops=N  +verbose

`timescale 1ns/1ps

module tb_sdram_interface;

	parameter	CLK_FREQ		= 133,
				BURST_LENGTH	= 4,
				BURST_TYPE		= "SEQ",
				BURST_WR_MODE	= 0,
				CMD_FIFO_DEPTH	= 512;

	localparam real	CLK_PERIOD = 1000.0 / CLK_FREQ;
	localparam		BT_INTR = BURST_TYPE == "INTR";

	reg 		clk = 0, reset = 1;
	reg  [24:0]	address = 0;
	reg  [15:0]	data_in = 0;
	reg 		read = 0, write = 0;
	wire		ready, valid;
	wire [15:0]	data_out;

	wire [15:0]	DRAM_DQ;
	wire [12:0]	DRAM_ADDR;
	wire [1:0]	DRAM_BA;
	wire		DRAM_CLK, DRAM_CKE, DRAM_LDQM, DRAM_HDQM,
				DRAM_nWE, DRAM_nCAS, DRAM_nRAS, DRAM_nCS;

	always #(CLK_PERIOD / 2) clk = ~clk;

	sdram_interface #(
		.CLK_FREQ		( CLK_FREQ			),
		.BURST_LENGTH	( BURST_LENGTH		),
		.BURST_TYPE		( BURST_TYPE		),
		.BURST_WR_MODE	( BURST_WR_MODE		),
		.CMD_FIFO_DEPTH	( CMD_FIFO_DEPTH	)
	) dut (
		.valid(valid), .ready(ready), .data_out(data_out),
		.address(address), .data_in(data_in), .read(read), .write(write),
		.clk(clk), .reset(reset), .start(1'b1),
		.DRAM_DQ(DRAM_DQ), .DRAM_ADDR(DRAM_ADDR), .DRAM_BA(DRAM_BA),
		.DRAM_CLK(DRAM_CLK), .DRAM_CKE(DRAM_CKE),
		.DRAM_LDQM(DRAM_LDQM), .DRAM_HDQM(DRAM_HDQM),
		.DRAM_nWE(DRAM_nWE), .DRAM_nCAS(DRAM_nCAS),
		.DRAM_nRAS(DRAM_nRAS), .DRAM_nCS(DRAM_nCS)
	);

	sdram_model #(
		.CLK_FREQ		( CLK_FREQ	),
		.BOARD_DELAY	( 1			)
	) sdram (
		.DQ(DRAM_DQ), .A(DRAM_ADDR), .BA(DRAM_BA), .CLK(DRAM_CLK), .CKE(DRAM_CKE),
		.nCS(DRAM_nCS), .nRAS(DRAM_nRAS), .nCAS(DRAM_nCAS), .nWE(DRAM_nWE),
		.LDQM(DRAM_LDQM), .HDQM(DRAM_HDQM)
	);

	// ------------------------------------------------------------------
	// address pool: every bank, 8 rows spread over the row range
	// ------------------------------------------------------------------
	function [12:0] pool_row(input [2:0] i);
		pool_row = {i, 10'h000} ^ {3'b000, 10'h2a5} ^ {10'h000, i};
	endfunction

	function [24:0] mk_addr(input [1:0] b, input [2:0] ri, input [9:0] c);
		mk_addr = {b, pool_row(ri), c};
	endfunction

	// shadow index {bank, row index, column}
	reg [15:0]	shadow		[0:(1<<15)-1];
	reg			shadow_ok	[0:(1<<15)-1];

	function [14:0] sidx(input [24:0] a);
		sidx = {a[24:23], a[22:20], a[9:0]};		// row[12:10] == pool index
	endfunction

	function [9:0] burst_col(input [9:0] base, input integer k);
		reg [9:0] mask;
		begin
			mask = BURST_LENGTH - 1;
			if (BT_INTR)	burst_col = base ^ (k & mask);
			else			burst_col = (base & ~mask) | ((base + k) & mask);
		end
	endfunction

	// expected read words, queued in command order
	localparam QD = 4096;
	reg [15:0]	exp_data [0:QD*8-1];
	reg			exp_ok   [0:QD*8-1];
	reg [24:0]	exp_addr [0:QD-1];
	integer		q_wr = 0, q_rd = 0, q_word = 0;

	integer	errors = 0, words_checked = 0, words_unknown = 0;
	integer	n_writes = 0, n_reads = 0, ready_low_cycles = 0;
	integer	i, k, seed, ops;

	// ------------------------------------------------------------------
	// command acceptance: a command is taken on an edge with ready high
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (!reset && ready && (write ^ read)) begin
			if (write) begin
				shadow[sidx(address)]		= data_in;
				shadow_ok[sidx(address)]	= 1;
				n_writes = n_writes + 1;
			end
			else begin
				if (q_wr - q_rd >= QD) begin
					$display("TB: expected-read queue overflow");
					$finish;
				end
				exp_addr[q_wr % QD] = address;
				for (k = 0; k < BURST_LENGTH; k = k + 1) begin
					exp_data[(q_wr % QD)*8 + k]	= shadow[sidx({address[24:10], burst_col(address[9:0], k)})];
					exp_ok[(q_wr % QD)*8 + k]	= shadow_ok[sidx({address[24:10], burst_col(address[9:0], k)})];
				end
				q_wr = q_wr + 1;
				n_reads = n_reads + 1;
			end
		end
		if (!reset && !ready && dut.init_done)
			ready_low_cycles = ready_low_cycles + 1;
	end

	// ------------------------------------------------------------------
	// read data checker
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (!reset && valid) begin
			if (q_rd == q_wr) begin
				errors = errors + 1;
				$display("TB ERROR @%0t: unexpected read data %h", $time, data_out);
			end
			else begin
				if (exp_ok[(q_rd % QD)*8 + q_word]) begin
					words_checked = words_checked + 1;
					if (data_out !== exp_data[(q_rd % QD)*8 + q_word]) begin
						errors = errors + 1;
						if (errors <= 20)
							$display("TB ERROR @%0t: read %h word %0d: got %h expected %h",
								$time, exp_addr[q_rd % QD], q_word, data_out,
								exp_data[(q_rd % QD)*8 + q_word]);
					end
				end
				else begin
					// never written: the model still holds X there, anything
					// else means a stray write hit this word
					words_unknown = words_unknown + 1;
					if (^data_out !== 1'bx) begin
						errors = errors + 1;
						if (errors <= 20)
							$display("TB ERROR @%0t: read %h word %0d: unwritten word holds %h",
								$time, exp_addr[q_rd % QD], q_word, data_out);
					end
				end
				q_word = q_word + 1;
				if (q_word == BURST_LENGTH) begin
					q_word = 0;
					q_rd = q_rd + 1;
				end
			end
		end
	end

	integer merged = 0;
	always @(posedge clk)
		if (dut.wr_merge) merged = merged + 1;

	// bus contention: controller and SDRAM must never drive DQ together
	always @(posedge clk)
		if (dut.dq_oe && sdram.dq_en) begin
			errors = errors + 1;
			$display("TB ERROR @%0t: DQ bus contention", $time);
		end

	// ------------------------------------------------------------------
	// stimulus helpers (all drive right after a clock edge)
	// ------------------------------------------------------------------
	task idle(input integer n);
		begin
			repeat (n) @(posedge clk);
		end
	endtask

	// present one command and hold it until accepted
	task cmd(input w, input [24:0] a, input [15:0] d);
		begin
			write	<= w;
			read	<= !w;
			address	<= a;
			data_in	<= d;
			@(posedge clk);
			while (!ready) @(posedge clk);
			write	<= 0;
			read	<= 0;
		end
	endtask

	task cmd_wr(input [24:0] a, input [15:0] d);	cmd(1, a, d);		endtask
	task cmd_rd(input [24:0] a);					cmd(0, a, 16'h0);	endtask

	function [24:0] rand_addr(input dummy);
		reg [31:0] r;
		begin
			r = $random(seed);
			rand_addr = mk_addr(r[1:0], r[4:2], r[14:5]);
		end
	endfunction

	// random traffic: p_cmd in percent per cycle, p_wr percent writes
	task random_traffic(input integer n, input integer p_cmd, input integer p_wr);
		integer j, run, m;
		reg [24:0] a;
		reg [31:0] r;
		begin
			j = 0;
			while (j < n) begin
				r = $random(seed);
				if ((r[7:0] % 100) < p_cmd) begin
					a = rand_addr(0);
					if ((r[15:8] % 100) < p_wr) begin
						// sometimes a run of writes, in burst order (mergeable) or
						// in plain address order (must not merge across the wrap)
						run = (r[16] && BURST_LENGTH > 1) ? BURST_LENGTH : 1;
						for (m = 0; m < run; m = m + 1) begin
							cmd_wr(r[17] ? {a[24:10], burst_col(a[9:0], m)} : {a[24:10], a[9:0] + m[9:0]}, $random(seed));
							j = j + 1;
						end
					end
					else begin
						cmd_rd(a);
						j = j + 1;
					end
				end
				else
					@(posedge clk);
			end
		end
	endtask

	task drain;
		integer t;
		begin
			t = 0;
			while ((q_rd != q_wr || dut.h_valid) && t < 200000) begin
				@(posedge clk);
				t = t + 1;
			end
			idle(32);
			if (q_rd != q_wr) begin
				errors = errors + 1;
				$display("TB ERROR: %0d reads never returned", q_wr - q_rd);
			end
		end
	endtask

	// ------------------------------------------------------------------
	// test sequence
	// ------------------------------------------------------------------
	initial begin
		if (!$value$plusargs("seed=%d", seed)) seed = 1;
		if (!$value$plusargs("ops=%d", ops)) ops = 20000;
		for (i = 0; i < (1<<15); i = i + 1) shadow_ok[i] = 0;

		$display("TB: CLK_FREQ=%0d BL=%0d BT=%0s WR_MODE=%0d seed=%0d ops=%0d",
			CLK_FREQ, BURST_LENGTH, BURST_TYPE, BURST_WR_MODE, seed, ops);

		repeat (5) @(posedge clk);
		reset <= 0;

		// commands presented before init completes must be held off
		write	<= 1;
		address	<= mk_addr(0, 0, 0);
		data_in	<= 16'hdead;
		@(posedge clk);
		if (ready) begin
			errors = errors + 1;
			$display("TB ERROR: ready high during init");
		end
		while (!ready) @(posedge clk);
		write <= 0;
		$display("TB: init done at %0t", $time);

		// both strobes together is not a command
		write <= 1; read <= 1; address <= mk_addr(0, 0, 1); data_in <= 16'hbad0;
		@(posedge clk);
		write <= 0; read <= 0;

		// directed: every bank, row switches within and across banks
		for (i = 0; i < 32; i = i + 1)
			cmd_wr(mk_addr(i[1:0], i[4:2], i * 8), 16'h1000 + i);
		for (i = 0; i < 32; i = i + 1)
			cmd_rd(mk_addr(i[1:0], i[4:2], i * 8));
		cmd_rd(mk_addr(0, 0, 1));		// word was never written
		drain();

		// a write at the next burst column but in another row/bank must not
		// be merged into the open burst
		for (i = 0; i < 4; i = i + 1) begin
			cmd_wr(mk_addr(1, 2, 10'h100 + 8*i), 16'ha000 + i);
			cmd_wr(mk_addr(i == 0 ? 2 : 1, i == 0 ? 2 : 3 + i, 10'h101 + 8*i), 16'hb000 + i);
			cmd_wr(mk_addr(1, 2, 10'h102 + 8*i), 16'hc000 + i);
		end
		drain();
		for (i = 0; i < 4; i = i + 1) begin
			cmd_rd(mk_addr(1, 2, 10'h100 + 8*i));
			cmd_rd(mk_addr(i == 0 ? 2 : 1, i == 0 ? 2 : 3 + i, 10'h100 + 8*i));
		end
		drain();

		// a row left open across several refresh periods
		cmd_wr(mk_addr(3, 7, 10'h3ff), 16'hcafe);
		idle(4000);
		cmd_rd(mk_addr(3, 7, 10'h3f8));
		drain();

		// back-to-back traffic fills the command FIFO
		random_traffic(ops / 4, 100, 50);
		drain();
		// read-heavy and write-heavy bursts
		random_traffic(ops / 4, 100, 10);
		random_traffic(ops / 4, 100, 90);
		drain();
		// sparse traffic, idle gaps around refreshes
		random_traffic(ops / 8, 3, 50);
		drain();
		// full read-back of everything written
		for (i = 0; i < 4 * 8 * 1024; i = i + BURST_LENGTH)
			if (shadow_ok[i]) cmd_rd(mk_addr(i[14:13], i[12:10], i[9:0]));
		drain();

		$display("TB: writes=%0d reads=%0d words_checked=%0d unknown=%0d refreshes=%0d ready_low=%0d merged=%0d",
			n_writes, n_reads, words_checked, words_unknown, sdram.refreshes, ready_low_cycles, merged);
		$display("TB: model saw %0d READ, %0d words written", sdram.reads, sdram.writes);

		// every accepted write lands exactly once
		if (sdram.writes != n_writes) begin
			errors = errors + 1;
			$display("TB ERROR: %0d writes accepted but %0d written", n_writes, sdram.writes);
		end
		if (BURST_WR_MODE && BURST_LENGTH > 1 && merged == 0) begin
			errors = errors + 1;
			$display("TB ERROR: no write was merged into a burst");
		end
		if (sdram.refreshes == 0)	begin errors = errors + 1; $display("TB ERROR: no refresh"); end
		// coverage sanity for full-length runs; short debug runs skip it
		if (ops >= 4000) begin
			if (words_checked < ops / 10)	begin errors = errors + 1; $display("TB ERROR: too few words checked"); end
			if (ready_low_cycles == 0)		begin errors = errors + 1; $display("TB ERROR: FIFO back-pressure not exercised"); end
		end

		if (errors == 0 && sdram.errors == 0)
			$display("PASS");
		else
			$display("FAIL: %0d tb errors, %0d model errors", errors, sdram.errors);
		$finish;
	end

	// stop early once the run has clearly failed
	always @(posedge clk)
		if (errors + sdram.errors > 20) begin
			$display("FAIL: %0d tb errors, %0d model errors (stopped early)", errors, sdram.errors);
			$finish;
		end

	// watchdog
	initial begin
		#(50_000_000);
		$display("FAIL: timeout");
		$finish;
	end

endmodule
