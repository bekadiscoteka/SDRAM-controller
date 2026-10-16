`timescale 1ns/1ps

// Extra top-level for `make sim`: dumps the controller run to build/sdram.vcd.
module wave_dump;
	initial begin
		$dumpfile("sdram.vcd");
		$dumpvars(0, tb_sdram_interface);
	end
endmodule
