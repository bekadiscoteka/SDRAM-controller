`timescale 1ns/1ps

// SDRAM controller for the ISSI IS42S16320D (-7) on the Terasic DE10-Lite.
//
// Commands are queued in a FIFO and executed in order with an open-row
// policy: the row stays open until a command needs another row or a refresh
// is due. Only one row (in one bank) is open at a time.
//
//   read   one READ command, returns BURST_LENGTH words on data_out/valid
//          in SDRAM burst order starting at the requested column.
//   write  writes exactly one word at the given address. With BURST_WR_MODE=1
//          a WRITE burst is used, and following queued writes are merged into
//          it when they hit the next columns of that burst; burst slots with
//          no matching write are masked with DQM.
//
// Address map: address[24:23] bank, [22:10] row, [9:0] column.
//
// Command timing is taken from the datasheet tables (133 MHz / CL2 and
// 143 MHz / CL3). Each constraint has its own down-counter holding the number
// of cycles left until a command of that class is legal.

module sdram_interface #(
	parameter	CLK_FREQ			= 133,		// MHz, 133 (CL2) or 143 (CL3)
				BURST_LENGTH		= 4,		// 1, 2, 4 or 8
				BURST_TYPE			= "SEQ",	// "SEQ" sequential, "INTR" interleaved
				BURST_WR_MODE		= 0,		// 0: burst on reads only, 1: reads and writes
				CMD_FIFO_DEPTH		= 512,		// power of two
				USE_START			= 0,		// 1: commands are executed only while start is high
				RD_CAPTURE_DELAY	= 1,		// extra cycles from the nominal CAS edge to the
												// DQ capture, compensates the board round trip
												// with an unshifted DRAM_CLK
				POWERUP_US			= 100		// power-up wait before the init sequence
)(
	// user interface
	output reg			valid,		// data_out holds a read word
	output 				ready,		// a command presented now is accepted at the next edge
	output [15:0]		data_out,
	input  [24:0]		address,
	input  [15:0]		data_in,
	input 				read,
	input 				write,
	input 				clk,
						reset,		// active high, asynchronous
						start,		// only used when USE_START=1

	// SDRAM
	inout      [15:0] 	DRAM_DQ,
	output reg [12:0]	DRAM_ADDR,
	output reg [1:0] 	DRAM_BA,
	output  			DRAM_CLK,
	output reg 			DRAM_CKE,
	output reg 			DRAM_LDQM,
						DRAM_HDQM,
						DRAM_nWE,	// active low
						DRAM_nCAS,
						DRAM_nRAS,
						DRAM_nCS
);

	// ------------------------------------------------------------------
	// timing, in clock cycles
	// ------------------------------------------------------------------
	localparam	FAST	= CLK_FREQ > 133,
				CAS		= FAST ? 3 : 2,
				T_RCD	= FAST ? 3 : 2,
				T_RP	= FAST ? 3 : 2,
				T_RC	= FAST ? 9 : 8,
				T_RAS	= FAST ? 6 : 5,
				T_DPL	= 2,
				T_MRD	= 2,
				BLW		= (BURST_WR_MODE != 0) ? BURST_LENGTH : 1;

	localparam integer	POWERUP_CYCLES	= CLK_FREQ * POWERUP_US + 16,
						// 8192 refreshes / 64 ms = one per 7.8125 us, with margin
						// for a refresh that has to wait for a burst to finish
						REF_INTERVAL	= (CLK_FREQ * 78) / 10 - 16;

	// spacing from a command to the next legal one; a timer loaded with N-1
	// allows the next command N cycles later
	/* verilator lint_off WIDTHTRUNC */
	localparam [4:0]	ACT_TO_RW	= T_RCD - 1,
						ACT_TO_PRE	= T_RAS - 1,
						ACT_TO_ACT	= T_RC - 1,
						RD_TO_RD	= BURST_LENGTH - 1,
						RD_TO_PRE	= BURST_LENGTH - 1,			// PRE at READ+BL does not cut the burst
						RD_TO_WR	= CAS + BURST_LENGTH + 1,	// bus turnaround, plus one cycle margin
						WR_TO_RW	= BLW - 1,
						WR_TO_PRE	= BLW - 1 + T_DPL,
						PRE_TO_ACT	= T_RP - 1,
						REF_TO_ACT	= T_RC - 1,
						MRD_TO_ACT	= T_MRD - 1;
	localparam [3:0]	BL_M1	= BURST_LENGTH - 1,
						BLW_M1	= BLW - 1;
	localparam [9:0]	BL_MASK	= BURST_LENGTH - 1;
	/* verilator lint_on WIDTHTRUNC */

	localparam [3:0]	CMD_NOP		= 4'b0111,		// {nCS, nRAS, nCAS, nWE}
						CMD_ACT		= 4'b0011,
						CMD_READ	= 4'b0101,
						CMD_WRITE	= 4'b0100,
						CMD_PRE		= 4'b0010,
						CMD_AREF	= 4'b0001,
						CMD_LMR		= 4'b0000;

	localparam [2:0]	S_INIT_WAIT	= 0,	// power-up wait, then PRECHARGE ALL
						S_INIT_REF	= 1,	// 8 x AUTO REFRESH
						S_INIT_LMR	= 2,	// LOAD MODE REGISTER
						S_IDLE		= 3,	// all banks precharged
						S_OPEN		= 4;	// open_bank/open_row active

	/* verilator lint_off WIDTHEXPAND */
	localparam			BT_INTR = BURST_TYPE == "INTR";
	/* verilator lint_on WIDTHEXPAND */

	localparam [2:0]	MR_BL	= BURST_LENGTH == 8 ? 3 :
								  BURST_LENGTH == 4 ? 2 :
								  BURST_LENGTH == 2 ? 1 : 0;
	localparam [12:0]	MODE_REG = {3'b000,
									(BURST_WR_MODE != 0) ? 1'b0 : 1'b1,	// A9: 0 burst write, 1 single write
									2'b00,
									CAS == 3 ? 3'd3 : 3'd2,
									BT_INTR ? 1'b1 : 1'b0,
									MR_BL};

	// ------------------------------------------------------------------
	// command FIFO
	// ------------------------------------------------------------------
	wire [15:0]	h_data;
	wire [24:0]	h_addr;
	wire		h_we,
				h_re,
				h_valid,
				cmd_full;
	/* verilator lint_off UNUSEDSIGNAL */
	wire		cmd_empty;		// h_valid is used instead
	/* verilator lint_on UNUSEDSIGNAL */
	reg			pop;

	synch_fifo #(
		.DEPTH		( CMD_FIFO_DEPTH	),
		.DATA_WIDTH	( 16 + 25 + 2		)
	) cmd_fifo (
		.clk		( clk							),
		.rst_n		( !reset						),
		.w_en		( (write ^ read) && ready		),
		.r_en		( pop							),
		.data_in	( { data_in, address, write, read } ),
		.data_out	( { h_data, h_addr, h_we, h_re } ),
		.full		( cmd_full						),
		.empty		( cmd_empty						),
		.valid		( h_valid						)
	);

	wire [1:0]	h_bank	= h_addr[24:23];
	wire [12:0]	h_row	= h_addr[22:10];
	wire [9:0]	h_col	= h_addr[9:0];
	wire		h_ok	= h_valid && (USE_START ? start : 1'b1);

	// ------------------------------------------------------------------
	// state
	// ------------------------------------------------------------------
	reg [2:0]	state;
	reg			init_done;
	localparam	INIT_W	= $clog2(POWERUP_CYCLES + 1),
				REF_W	= $clog2(REF_INTERVAL + 1);
	/* verilator lint_off WIDTHTRUNC */
	localparam [INIT_W-1:0]	INIT_LOAD	= POWERUP_CYCLES;
	localparam [REF_W-1:0]	REF_LAST	= REF_INTERVAL - 1;
	/* verilator lint_on WIDTHTRUNC */

	reg [INIT_W-1:0]	init_cnt;
	reg [2:0]	init_refs;

	reg [REF_W-1:0]		ref_cnt;
	reg			ref_req;

	reg [1:0]	open_bank;
	reg [12:0]	open_row;

	reg [4:0]	t_act,		// ACT / AREF / LMR allowed when 0
				t_rd,		// READ
				t_wr,		// WRITE
				t_pre;		// PRE

	reg [3:0]	wr_left;	// burst write slots still to drive
	reg [3:0]	wr_idx;
	reg [9:0]	wr_base;	// start column of the current write burst
	reg [3:0]	rd_left;	// read burst words still to tag
	reg [7:0]	rd_sr;		// read word tags, one per cycle

	(* useioff = 1 *) reg [15:0]	dq_out;
	(* useioff = 1 *) reg [15:0]	dq_q;
	reg								dq_oe;

	assign ready	= !cmd_full && init_done;
	assign DRAM_DQ	= dq_oe ? dq_out : 16'bz;
	assign DRAM_CLK	= clk;
	assign data_out	= dq_q;

	wire row_hit = h_ok && h_bank == open_bank && h_row == open_row;


	function [9:0] burst_col(input [9:0] base, input [3:0] k);
		reg [9:0] mask;
		begin
			mask = BL_MASK;
			if (BT_INTR)
				burst_col = base ^ ({6'b0, k} & mask);
			else
				burst_col = (base & ~mask) | ((base + {6'b0, k}) & mask);
		end
	endfunction

	wire [9:0]	wr_next_col	= burst_col(wr_base, wr_idx);
	wire		wr_merge	= wr_left != 0 && row_hit && h_we && h_col == wr_next_col;

	// ------------------------------------------------------------------
	// command decision: exactly one command (or NOP) per cycle
	// ------------------------------------------------------------------
	reg do_pall, do_aref, do_lmr, do_act, do_read, do_write, do_pre;

	always @* begin
		{do_pall, do_aref, do_lmr, do_act, do_read, do_write, do_pre} = 0;
		pop = 0;

		case (state)
			S_INIT_WAIT:	do_pall	= init_cnt == 0;
			S_INIT_REF:		do_aref	= t_act == 0;
			S_INIT_LMR:		do_lmr	= t_act == 0;

			S_IDLE: begin
				if (ref_req)
					do_aref	= t_act == 0;
				else if (h_ok)
					do_act	= t_act == 0;
			end

			S_OPEN: begin
				if (ref_req || (h_ok && !row_hit))
					do_pre		= t_pre == 0;
				else if (row_hit && h_re)
					do_read		= t_rd == 0;
				else if (row_hit && h_we)
					do_write	= t_wr == 0;
			end

			default: ;
		endcase

		// t_rd/t_wr keep READ/WRITE out while a write burst is running, so
		// merging a burst slot never competes with a new command for the head
		pop = do_read || do_write || wr_merge;
	end

	// ------------------------------------------------------------------
	// sequential part
	// ------------------------------------------------------------------
	function [4:0] tmax(input [4:0] cur, input [4:0] val);
		tmax = cur > val ? cur : val;
	endfunction

	wire [4:0]	t_act_d	= t_act == 0 ? 5'd0 : t_act - 1'b1,
				t_rd_d	= t_rd  == 0 ? 5'd0 : t_rd  - 1'b1,
				t_wr_d	= t_wr  == 0 ? 5'd0 : t_wr  - 1'b1,
				t_pre_d	= t_pre == 0 ? 5'd0 : t_pre - 1'b1;

	wire		rd_tag	= do_read || rd_left != 0;
	wire		ref_tick = init_done && ref_cnt == REF_LAST;

	always @(posedge clk, posedge reset) begin
		if (reset) begin
			state		<= S_INIT_WAIT;
			init_done	<= 0;
			init_cnt	<= INIT_LOAD;
			init_refs	<= 0;
			ref_cnt		<= 0;
			ref_req		<= 0;
			open_bank	<= 0;
			open_row	<= 0;
			t_act		<= 0;
			t_rd		<= 0;
			t_wr		<= 0;
			t_pre		<= 0;
			wr_left		<= 0;
			wr_idx		<= 0;
			wr_base		<= 0;
			rd_left		<= 0;
			rd_sr		<= 0;
			valid		<= 0;
			dq_out		<= 0;
			dq_q		<= 0;
			dq_oe		<= 0;

			{DRAM_nCS, DRAM_nRAS, DRAM_nCAS, DRAM_nWE} <= CMD_NOP;
			DRAM_CKE	<= 1;
			DRAM_ADDR	<= 0;
			DRAM_BA		<= 0;
			DRAM_LDQM	<= 0;
			DRAM_HDQM	<= 0;
		end
		else begin
			// defaults
			{DRAM_nCS, DRAM_nRAS, DRAM_nCAS, DRAM_nWE} <= CMD_NOP;
			DRAM_CKE	<= 1;
			t_act		<= t_act_d;
			t_rd		<= t_rd_d;
			t_wr		<= t_wr_d;
			t_pre		<= t_pre_d;

			if (state == S_INIT_WAIT && init_cnt != 0)
				init_cnt <= init_cnt - 1'b1;

			// refresh request
			if (init_done)
				ref_cnt <= ref_tick ? 0 : ref_cnt + 1'b1;
			if (ref_tick)
				ref_req <= 1;
			else if (do_aref && state == S_IDLE)
				ref_req <= 0;

			if (do_pall) begin
				{DRAM_nCS, DRAM_nRAS, DRAM_nCAS, DRAM_nWE} <= CMD_PRE;
				DRAM_ADDR[10]	<= 1;		// all banks
				t_act			<= tmax(t_act_d, PRE_TO_ACT);
				state			<= S_INIT_REF;
			end

			if (do_aref) begin
				{DRAM_nCS, DRAM_nRAS, DRAM_nCAS, DRAM_nWE} <= CMD_AREF;
				t_act			<= tmax(t_act_d, REF_TO_ACT);
				if (state == S_INIT_REF) begin
					init_refs	<= init_refs + 1'b1;
					if (init_refs == 7)
						state	<= S_INIT_LMR;
				end
			end

			if (do_lmr) begin
				{DRAM_nCS, DRAM_nRAS, DRAM_nCAS, DRAM_nWE} <= CMD_LMR;
				DRAM_BA			<= 0;
				DRAM_ADDR		<= MODE_REG;
				t_act			<= tmax(t_act_d, MRD_TO_ACT);
				state			<= S_IDLE;
				init_done		<= 1;
			end

			if (do_act) begin
				{DRAM_nCS, DRAM_nRAS, DRAM_nCAS, DRAM_nWE} <= CMD_ACT;
				DRAM_BA			<= h_bank;
				DRAM_ADDR		<= h_row;
				open_bank		<= h_bank;
				open_row		<= h_row;
				t_act			<= tmax(t_act_d, ACT_TO_ACT);
				t_rd			<= tmax(t_rd_d,  ACT_TO_RW);
				t_wr			<= tmax(t_wr_d,  ACT_TO_RW);
				t_pre			<= tmax(t_pre_d, ACT_TO_PRE);
				state			<= S_OPEN;
			end

			if (do_pre) begin
				{DRAM_nCS, DRAM_nRAS, DRAM_nCAS, DRAM_nWE} <= CMD_PRE;
				DRAM_BA			<= open_bank;	// the bank that is actually open
				DRAM_ADDR[10]	<= 0;
				t_act			<= tmax(t_act_d, PRE_TO_ACT);
				state			<= S_IDLE;
			end

			if (do_read) begin
				{DRAM_nCS, DRAM_nRAS, DRAM_nCAS, DRAM_nWE} <= CMD_READ;
				DRAM_BA			<= h_bank;
				DRAM_ADDR		<= {3'b000, h_col};		// A10=0: no auto precharge
				t_rd			<= tmax(t_rd_d,  RD_TO_RD);
				t_wr			<= tmax(t_wr_d,  RD_TO_WR);
				t_pre			<= tmax(t_pre_d, RD_TO_PRE);
			end

			// write data path: dq_out/DQM are registered with the command, so
			// word k goes out k cycles after WRITE
			dq_oe		<= 0;
			DRAM_LDQM	<= 0;
			DRAM_HDQM	<= 0;

			if (do_write) begin
				{DRAM_nCS, DRAM_nRAS, DRAM_nCAS, DRAM_nWE} <= CMD_WRITE;
				DRAM_BA			<= h_bank;
				DRAM_ADDR		<= {3'b000, h_col};
				t_rd			<= tmax(t_rd_d,  WR_TO_RW);
				t_wr			<= tmax(t_wr_d,  WR_TO_RW);
				t_pre			<= tmax(t_pre_d, WR_TO_PRE);
				dq_out			<= h_data;
				dq_oe			<= 1;
				wr_left			<= BLW_M1;
				wr_idx			<= 1;
				wr_base			<= h_col;
			end
			else if (wr_left != 0) begin
				dq_oe			<= 1;
				wr_left			<= wr_left - 1'b1;
				wr_idx			<= wr_idx + 1'b1;
				if (wr_merge)
					dq_out		<= h_data;
				else begin
					DRAM_LDQM	<= 1;		// nothing queued for this slot
					DRAM_HDQM	<= 1;
				end
			end

			// read data path
			rd_left	<= do_read ? BL_M1 : (rd_left != 0 ? rd_left - 1'b1 : 4'd0);
			rd_sr	<= {rd_sr[6:0], rd_tag};
			dq_q	<= DRAM_DQ;
			valid	<= rd_sr[CAS + RD_CAPTURE_DELAY];
		end
	end

	// ------------------------------------------------------------------
	// parameter checks
	// ------------------------------------------------------------------
	// synthesis translate_off
	initial begin
		if (BURST_LENGTH != 1 && BURST_LENGTH != 2 && BURST_LENGTH != 4 && BURST_LENGTH != 8) begin
			$display("sdram_interface: BURST_LENGTH must be 1, 2, 4 or 8");
			$finish;
		end
		if (CLK_FREQ > 143) begin
			$display("sdram_interface: CLK_FREQ above 143 MHz is not supported by the -7 part");
			$finish;
		end
		if (CAS + RD_CAPTURE_DELAY > 7) begin
			$display("sdram_interface: RD_CAPTURE_DELAY too large");
			$finish;
		end
	end
	// synthesis translate_on

endmodule
