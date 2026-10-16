`timescale 1ns/1ps

// UART command parser for final_top.
//
//   "W"/"w" d1 d0 bank a2 a1 a0   ->  one-cycle write pulse, data = {d1, d0}
//   "R"/"r" bank a2 a1 a0         ->  one-cycle read pulse
//
// address = {bank[1:0], a2, a1, a0[6:0]}: bank, 13-bit row, 10-bit column.
// Any other first byte sets error until the next valid command.

module cmd(
	output	reg	[15:0]	data,
	output	reg [24:0]	address,
	output	reg			write,
						read,
						error,
	output 	wire		processing,
	input		[7:0]	byte_in,
   	input				wr_en,
						clk,
						rst

);
	///////////////////////////
	//		STATE MACHINE
	localparam	IDLE			=0,

				BYTE_DATA0		=1,
				BYTE_DATA1		=2,

				BYTE_BANK		=3,
				BYTE_ADDR0		=4,
				BYTE_ADDR1		=5,
				BYTE_ADDR2		=6;


	reg	[3:0]	state;
	///////////////////////////

	reg _write,
		_read;

	assign processing = state != IDLE;

	always @(posedge clk or posedge rst) begin
		if (rst) begin
			state		<=	IDLE;
			data		<=	0;
			address		<=	0;
			write		<= 	0;
			read		<= 	0;
			_read		<= 	0;
			_write 		<= 	0;
			error 		<= 	0;
		end
		else begin
			case (state)

				IDLE: begin
					NOT_VALID();
				   	if	(wr_en) begin
						if (byte_in == "W" || byte_in == "w") begin
							_write	<= 1;
							state 	<= BYTE_DATA0;
							error	<= 0;
						end
						else if	(byte_in == "R" || byte_in == "r") begin
							_read	<= 1;
							state 	<= BYTE_BANK;
							error 	<= 0;
						end
						else error	<= 1;
					end
				end

				BYTE_DATA0: begin
					if (wr_en) begin
						data[15:8]	<= byte_in;
					   	state		<= BYTE_DATA1;
					end
				end

				BYTE_DATA1: begin
					if (wr_en) begin
						data[7:0]	<= byte_in;
						state		<= BYTE_BANK;
					end
				end

				BYTE_BANK: begin
					if (wr_en) begin
						address[24:23]	<= byte_in[1:0];
						state 			<= BYTE_ADDR0;
					end
				end

				BYTE_ADDR0: begin
					if (wr_en) begin
						address[22:15]	<= byte_in;
						state			<= BYTE_ADDR1;
					end
				end

				BYTE_ADDR1: begin
					if (wr_en) begin
						address[14:7]	<= byte_in;
						state			<= BYTE_ADDR2;
					end
				end

				BYTE_ADDR2: begin
					if (wr_en) begin
						address[6:0]	<= byte_in[6:0];
						state			<= IDLE;
						VALID();
					end
				end

			endcase
		end
	end

	task VALID;
		begin
			write	<= _write;
			read 	<= _read;
			_write	<= 0;
			_read	<= 0;
		end
	endtask

	task NOT_VALID;
		begin
			write	<= 0;
			read 	<= 0;
		end
	endtask

endmodule
