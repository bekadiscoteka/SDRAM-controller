// Behavioral model of the IS42S16320D for simulation.
//
// It stores data and checks the controller against the datasheet: power-up
// and init sequence, bank state legality, command spacing (tRCD, tRP, tRC,
// tRAS, tRRD, tDPL, tMRD), refresh interval, mode register contents and burst
// interruption. Every violation is printed and counted in `errors`.
//
// BOARD_DELAY models the round trip of the DE10-Lite with DRAM_CLK taken
// straight from the controller clock: read data the datasheet expects to be
// sampled at edge T+CL is seen by the FPGA one edge later.
//
// Storage: up to ROWS distinct (bank,row) pairs, allocated on first write.

`timescale 1ns/1ps

module sdram_model #(
	parameter	CLK_FREQ	= 133,
				BOARD_DELAY	= 1,
				ROWS		= 64,
				VERBOSE		= 0
)(
	inout [15:0]	DQ,
	input [12:0]	A,
	input [1:0]		BA,
	input			CLK,
					CKE,
					nCS,
					nRAS,
					nCAS,
					nWE,
					LDQM,
					HDQM
);
	localparam	FAST	= CLK_FREQ > 133,
				T_RCD	= FAST ? 3 : 2,
				T_RP	= FAST ? 3 : 2,
				T_RC	= FAST ? 9 : 8,
				T_RAS	= FAST ? 6 : 5,
				T_RRD	= 2,
				T_DPL	= 2,
				T_MRD	= 2;

	localparam real	POWERUP_NS	= 100000.0,
					T_REFI_NS	= 7812.5;

	integer errors = 0;
	integer refreshes = 0;
	integer reads = 0;
	integer writes = 0;

	task fail(input [8*64-1:0] msg);
		begin
			errors = errors + 1;
			if (errors <= 20)
				$display("SDRAM MODEL ERROR @%0t (cycle %0d): %0s", $time, cyc, msg);
		end
	endtask

	// ------------------------------------------------------------------
	// storage
	// ------------------------------------------------------------------
	reg [15:0]	mem [0:ROWS*1024-1];
	reg [14:0]	row_key [0:ROWS-1];
	integer		rows_used = 0;

	function integer row_index(input [1:0] b, input [12:0] r, input alloc);
		integer i;
		begin
			row_index = -1;
			for (i = 0; i < rows_used; i = i + 1)
				if (row_key[i] == {b, r})
					row_index = i;
			if (row_index < 0 && alloc) begin
				if (rows_used == ROWS) begin
					$display("SDRAM MODEL: out of row storage");
					$finish;
				end
				row_key[rows_used] = {b, r};
				row_index = rows_used;
				rows_used = rows_used + 1;
			end
		end
	endfunction

	// ------------------------------------------------------------------
	// state
	// ------------------------------------------------------------------
	integer	cyc = 0;
	real	t_first_clk = -1.0;
	integer	init_phase = 0;			// 0 power-up wait, 1 need PALL, 2 AREFs, 3 need LMR, 4 ready
	integer	init_refs = 0;

	reg		bank_active [0:3];
	reg [12:0] bank_row [0:3];
	integer	c_act [0:3];
	integer	c_pre [0:3];
	integer	c_wr_data [0:3];
	integer	c_act_any = -1000, c_aref = -1000, c_lmr = -1000, c_pre_any = -1000;
	real	t_aref = 0.0;
	reg		refi_violated = 0;

	integer	cl = 2, bl = 1, wbl = 1;
	reg		bt = 0;

	// read burst in progress
	integer	rd_end = -1;			// last command cycle of the read burst
	// write burst in progress
	integer	wr_left = 0, wr_k = 0, wr_idx = 0;
	reg [1:0] wr_bank;
	reg [9:0] wr_base;

	// output schedule, indexed by cycle mod 32
	reg [15:0]	out_data [0:31];
	reg			out_en   [0:31];
	reg [1:0]	dqm_hist [0:31];		// {HDQM, LDQM}

	reg [15:0]	dq_drive = 0;
	reg [1:0]	dq_byte_en = 0;
	wire		dq_en = |dq_byte_en;
	assign DQ[7:0]	= dq_byte_en[0] ? dq_drive[7:0]  : 8'bz;
	assign DQ[15:8]	= dq_byte_en[1] ? dq_drive[15:8] : 8'bz;

	integer i;
	initial begin
		for (i = 0; i < 4; i = i + 1) begin
			bank_active[i] = 0;
			c_act[i] = -1000;
			c_pre[i] = -1000;
			c_wr_data[i] = -1000;
		end
		for (i = 0; i < 32; i = i + 1) begin
			out_en[i] = 0;
			dqm_hist[i] = 0;
		end
	end

	// one write slot, LDQM/HDQM mask their byte
	task write_word(input integer idx);
		begin
			if (!LDQM) begin
				if (^DQ[7:0] === 1'bx) fail("write data is X/Z");
				mem[idx][7:0] = DQ[7:0];
			end
			if (!HDQM) begin
				if (^DQ[15:8] === 1'bx) fail("write data is X/Z");
				mem[idx][15:8] = DQ[15:8];
			end
			if (!LDQM || !HDQM)
				writes = writes + 1;
		end
	endtask

	function [9:0] burst_col(input [9:0] base, input integer k, input integer len, input t);
		reg [9:0] mask;
		begin
			mask = len - 1;
			if (t)	burst_col = base ^ (k & mask);
			else	burst_col = (base & ~mask) | ((base + k) & mask);
		end
	endfunction

	wire [3:0] cmd = {nCS, nRAS, nCAS, nWE};
	localparam [3:0]	C_NOP = 4'b0111, C_ACT = 4'b0011, C_READ = 4'b0101, C_WRITE = 4'b0100,
						C_PRE = 4'b0010, C_AREF = 4'b0001, C_LMR = 4'b0000, C_BST = 4'b0110;

	reg any_active;
	integer b, k, ri, slot, dslot;

	always @(posedge CLK) begin
		cyc = cyc + 1;
		if (t_first_clk < 0) t_first_clk = $realtime;

		any_active = bank_active[0] | bank_active[1] | bank_active[2] | bank_active[3];
		dqm_hist[cyc % 32] = {HDQM, LDQM};

		if (!CKE)
			fail("CKE low is not used by this controller");

		if (init_phase == 4 && $realtime - t_aref > T_REFI_NS && !refi_violated) begin
			fail("refresh interval exceeded 7.8125 us");
			refi_violated = 1;
		end

		// ---- write burst data (word 0 is sampled with the WRITE command) ----
		if (wr_left > 0) begin
			if (!nCS && cmd != C_NOP)
				fail("command interrupts a write burst");
			k = burst_col(wr_base, wr_k, wbl, bt);
			ri = row_index(wr_bank, bank_row[wr_bank], 1);
			write_word(ri*1024 + k);
			c_wr_data[wr_bank] = cyc;
			wr_k = wr_k + 1;
			wr_left = wr_left - 1;
		end
		else if (!nCS && cmd != C_NOP && cmd != C_AREF && cmd != C_LMR && cmd != C_ACT && rd_end >= cyc)
			fail("command interrupts a read burst");

		if (!nCS && cmd != C_NOP) begin
			if (init_phase == 0) begin
				if ($realtime - t_first_clk < POWERUP_NS)
					fail("command before 100 us power-up wait");
				init_phase = 1;
			end

			case (cmd)
				C_ACT: begin
					b = BA;
					if (VERBOSE) $display("%0t ACT  b%0d r%0h", $time, b, A);
					if (init_phase != 4)		fail("ACT before init complete");
					if (bank_active[b])			fail("ACT to an active bank");
					if (cyc - c_pre[b] < T_RP)	fail("tRP violated (PRE->ACT)");
					if (cyc - c_act[b] < T_RC)	fail("tRC violated (ACT->ACT)");
					if (cyc - c_act_any < T_RRD)	fail("tRRD violated");
					if (cyc - c_aref < T_RC)	fail("tRC violated (REF->ACT)");
					if (cyc - c_lmr < T_MRD)	fail("tMRD violated");
					bank_active[b] = 1;
					bank_row[b] = A;
					c_act[b] = cyc;
					c_act_any = cyc;
				end

				C_READ, C_WRITE: begin
					b = BA;
					if (VERBOSE) $display("%0t %0s b%0d c%0h", $time, cmd == C_READ ? "READ " : "WRITE", b, A[9:0]);
					if (!bank_active[b])		fail("READ/WRITE to an idle bank");
					if (cyc - c_act[b] < T_RCD)	fail("tRCD violated");
					if (A[10])					fail("auto precharge not expected");
					if (cmd == C_READ) begin
						reads = reads + 1;
						if (wr_left > 0) ;		// already reported
						ri = row_index(b, bank_row[b], 0);
						rd_end = cyc + bl - 1;
						for (k = 0; k < bl; k = k + 1) begin
							slot = cyc + cl - 1 + BOARD_DELAY + k;
							out_en[slot % 32] = 1;
							out_data[slot % 32] = ri < 0 ? 16'hxxxx
										: mem[ri*1024 + burst_col(A[9:0], k, bl, bt)];
						end
					end
					else begin
						wr_bank = b;
						wr_base = A[9:0];
						wr_k = 0;
						wr_left = wbl;
						// word 0 is sampled now
						ri = row_index(b, bank_row[b], 1);
						write_word(ri*1024 + A[9:0]);
						c_wr_data[b] = cyc;
						wr_k = 1;
						wr_left = wbl - 1;
					end
				end

				C_PRE: begin
					if (VERBOSE) $display("%0t PRE%0s b%0d", $time, A[10] ? "A" : " ", BA);
					for (b = 0; b < 4; b = b + 1)
						if (A[10] || b == BA) begin
							if (bank_active[b]) begin
								if (cyc - c_act[b] < T_RAS)		fail("tRAS violated (ACT->PRE)");
								if (cyc - c_wr_data[b] < T_DPL)	fail("tDPL violated (write->PRE)");
							end
							bank_active[b] = 0;
							c_pre[b] = cyc;
						end
					c_pre_any = cyc;
					if (init_phase == 1 && A[10]) init_phase = 2;
				end

				C_AREF: begin
					if (VERBOSE) $display("%0t AREF", $time);
					if (init_phase == 1)		fail("AREF before PRECHARGE ALL");
					if (any_active)				fail("AREF with a bank active");
					if (cyc - c_pre_any < T_RP)	fail("tRP violated (PRE->REF)");
					if (cyc - c_aref < T_RC)	fail("tRC violated (REF->REF)");
					if (cyc - c_lmr < T_MRD)	fail("tMRD violated");
					c_aref = cyc;
					t_aref = $realtime;
					refi_violated = 0;
					if (init_phase == 2) init_refs = init_refs + 1;
					if (init_phase == 4) refreshes = refreshes + 1;
				end

				C_LMR: begin
					if (VERBOSE) $display("%0t LMR %h", $time, A);
					if (any_active)				fail("LMR with a bank active");
					if (init_phase != 2 && init_phase != 4)	fail("LMR out of init order");
					if (init_phase == 2 && init_refs < 8)	fail("fewer than 8 AREF before LMR");
					if (cyc - c_pre_any < T_RP)	fail("tRP violated (PRE->LMR)");
					if (cyc - c_aref < T_RC)	fail("tRC violated (REF->LMR)");
					if (A[12:10] != 0 || A[8:7] != 0 || BA != 0)
						fail("reserved mode register bits set");
					case (A[2:0])
						0: bl = 1; 1: bl = 2; 2: bl = 4; 3: bl = 8;
						default: fail("unsupported burst length");
					endcase
					bt  = A[3];
					cl  = A[6:4];
					if (cl != (FAST ? 3 : 2))	fail("CAS latency does not match clock");
					wbl = A[9] ? 1 : bl;
					c_lmr = cyc;
					init_phase = 4;
					t_aref = $realtime;
				end

				C_BST:		fail("BURST STOP not expected");
				default:	;
			endcase
		end

		// ---- read output, after a small clock-to-out delay ----
		slot = cyc;
		dslot = cyc + 1 - BOARD_DELAY - 2;		// device edge of this word, minus DQM latency
		#1;
		if (out_en[slot % 32]) begin
			dq_byte_en = ~dqm_hist[(dslot + 64) % 32];
			dq_drive = out_data[slot % 32];
			out_en[slot % 32] = 0;
		end
		else
			dq_byte_en = 0;
	end

endmodule
