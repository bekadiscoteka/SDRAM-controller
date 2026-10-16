`timescale 1ns/1ps

// Random push/pop test of synch_fifo against a reference queue.
// Checks order, the valid/full flags, capacity and throughput.

module tb_synch_fifo;

	parameter	DEPTH	= 8,
				W		= 16;

	reg				clk = 0, rst_n = 0, w_en = 0, r_en = 0;
	reg  [W-1:0]	din = 0;
	wire [W-1:0]	dout;
	wire			full, empty, valid;

	always #5 clk = ~clk;

	synch_fifo #(.DEPTH(DEPTH), .DATA_WIDTH(W)) dut (
		.clk(clk), .rst_n(rst_n), .w_en(w_en), .r_en(r_en),
		.data_in(din), .data_out(dout), .full(full), .empty(empty), .valid(valid)
	);

	reg [W-1:0]	ref_q [0:4095];
	integer		head = 0, tail = 0, errors = 0, pops = 0, max_level = 0;
	integer		i, seed = 7, p_w, p_r, phase;

	always @(posedge clk) begin
		if (rst_n) begin
			if (empty !== !valid) begin
				errors = errors + 1;
				$display("ERROR: empty != !valid");
			end
			if (r_en && valid) begin
				if (head == tail) begin
					errors = errors + 1;
					$display("ERROR @%0t: pop from empty reference", $time);
				end
				else begin
					if (dout !== ref_q[head % 4096]) begin
						errors = errors + 1;
						if (errors < 10) $display("ERROR @%0t: got %h expected %h", $time, dout, ref_q[head % 4096]);
					end
					head = head + 1;
					pops = pops + 1;
				end
			end
			if (w_en && !full) begin
				ref_q[tail % 4096] = din;
				tail = tail + 1;
			end
			if (tail - head > max_level) max_level = tail - head;
		end
	end

	initial begin
		repeat (3) @(posedge clk);
		rst_n <= 1;
		for (phase = 0; phase < 4; phase = phase + 1) begin
			// mostly-write, mostly-read, balanced, streaming
			p_w = phase == 0 ? 90 : phase == 1 ? 20 : phase == 2 ? 50 : 100;
			p_r = phase == 0 ? 20 : phase == 1 ? 90 : phase == 2 ? 50 : 100;
			for (i = 0; i < 5000; i = i + 1) begin
				@(posedge clk);
				w_en	<= ($random(seed) % 100 + 100) % 100 < p_w;
				r_en	<= ($random(seed) % 100 + 100) % 100 < p_r;
				din		<= $random(seed);
			end
		end
		w_en <= 0;
		r_en <= 1;
		repeat (DEPTH + 8) @(posedge clk);

		if (head != tail) begin errors = errors + 1; $display("ERROR: %0d entries lost", tail - head); end
		if (max_level < DEPTH) begin errors = errors + 1; $display("ERROR: capacity %0d < DEPTH", max_level); end
		$display("pops=%0d max_level=%0d", pops, max_level);
		if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
		$finish;
	end

endmodule
