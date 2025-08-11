`timescale 1ns/1ps
`include "interface.v"

module tb_sdram_interface;

    // parameters
    localparam CLK_PERIOD = 7.5; // 133MHz ~ 7.5ns

    // DUT connections
    reg         clk;
    reg         reset;
    reg  [24:0] address;
    reg  [15:0] data_in;
    reg         read;
    reg         write;
    `ifdef TEST
	    reg interface_start;
    `endif
    wire        ready;
    wire [15:0] data_out;
    wire        valid;

    // SDRAM pins (simplified, not modeled here)
    wire [15:0] DRAM_DQ;
    wire [12:0] DRAM_ADDR;
    wire [1:0]  DRAM_BA;
    wire        DRAM_CLK;
    wire        DRAM_CKE;
    wire        DRAM_LDQM;
    wire        DRAM_HDQM;
    wire        DRAM_nWE;
    wire        DRAM_nCAS;
    wire        DRAM_nRAS;
    wire        DRAM_nCS;

    // Instantiate DUT
    sdram_interface #(
        .CLK_FREQ(133),
        .BURST_LENGTH(4),
        .BURST_TYPE("SEQ"),
        .BURST_WR_MODE(1)
    ) dut (
        .valid(valid),
        .ready(ready),
	`ifdef TEST
		.start(interface_start),
	`endif
        .data_out(data_out),
        .address(address),
        .data_in(data_in),
        .read(read),
        .write(write),
        .clk(clk),
        .reset(reset),
        .DRAM_DQ(DRAM_DQ),
        .DRAM_ADDR(DRAM_ADDR),
        .DRAM_BA(DRAM_BA),
        .DRAM_CLK(DRAM_CLK),
        .DRAM_CKE(DRAM_CKE),
        .DRAM_LDQM(DRAM_LDQM),
        .DRAM_HDQM(DRAM_HDQM),
        .DRAM_nWE(DRAM_nWE),
        .DRAM_nCAS(DRAM_nCAS),
        .DRAM_nRAS(DRAM_nRAS),
        .DRAM_nCS(DRAM_nCS)
    );

always @(posedge clk) begin
	if (
		DRAM_nCS == 0	&&
		DRAM_nRAS == 0	&& 
		DRAM_nCAS == 1	&&
		DRAM_nWE == 0	&&	
		DRAM_ADDR[10] == 1
	) 
	begin
		$display("PALL");		
	end

		if (
			DRAM_CKE == 1	&&
			DRAM_nCS == 0	&&
			DRAM_nRAS == 0	&& 
			DRAM_nCAS == 0	&&
			DRAM_nWE == 1	&&
			$test$plusargs("AREF")
		)
		begin
			$display("AREF");
		end

	if (
		DRAM_nCS == 0	&&
		DRAM_nRAS == 0	&& 
		DRAM_nCAS == 0	&&
		DRAM_nWE == 0 	&&
		DRAM_BA == 0
	)
	begin
		$display("LMR");
	end

	if (
		DRAM_nCS == 0	&&
		DRAM_nRAS == 0 	&& 
		DRAM_nCAS == 1	&&
		DRAM_nWE == 1		
	)
	begin
		$display("ACTIVE: bank: %h row: %h", DRAM_BA, DRAM_ADDR);
	end

	if (
		DRAM_nCS == 0	&&
		DRAM_nRAS == 1	&& 
		DRAM_nCAS == 0	&&
		DRAM_nWE == 1			
	)
	begin
		$display("READ: column: %h ", DRAM_ADDR[9:0]);
	end

	if (
		DRAM_nCS <= 0	&&
		DRAM_nRAS <= 1	&& 
		DRAM_nCAS <= 0	&&
		DRAM_nWE <= 0			
	)
	begin
		$display("WRITE, value: %h, column: %h", DRAM_DQ, DRAM_ADDR[9:0]);
	end

	if (
		DRAM_nCS == 0	&&
		DRAM_nRAS == 0	&& 
		DRAM_nCAS == 1	&&
		DRAM_nWE == 0					
	)
	begin
		$display("PRECHARGE");
	end


	if (

		DRAM_nCS == 0	&&
		DRAM_nRAS == 1	&&
		DRAM_nCAS == 1	&&
		DRAM_nWE == 1	&& 
		$test$plusargs("NOP")
	)
	begin
		$display("NOP");
	end

end

	always @(posedge clk) begin
	       	if (valid) $display("VALID");
		if (!dut.burstWrite_done) begin
		       	$display("DQ is OPEN, %h", DRAM_DQ);
		end
		if ($test$plusargs("DEEP_DEBUG")) begin
			if (dut.fetch) $display("FETCH signal is HIGH");
			if (!dut.burstWrite_done) $display("_data_in %h", dut._data_in);
			if (dut.cmd_valid) $display("sync fifo out: %h", dut.fifo_data_in); 
			$display("END CYCLE");
			$strobe("---\nEND CYCLE\n---");
		end	
		
	end



    // Clock generation
    always #(CLK_PERIOD/2) clk = ~clk;

    // Simple SDRAM DQ modeling (not actual SDRAM model)

    // Stimulus generator tasks
    task do_write_burst(input [24:0] start_addr, input [15:0] base_data);
        integer i;
        begin
            // First write with address
            address = start_addr;
            data_in = base_data;
            write   = 1;
            @(posedge clk);
            //write   = 0;
            //@(posedge clk);

            // Remaining burst writes without changing address
            for (i = 1; i < 4; i = i + 1) begin
                data_in = base_data + i;
                //write   = 1;
                //@(posedge clk);
                //write   = 0;
                @(posedge clk);
            end
	    write   = 0;
	    @(posedge clk);
        end
    endtask

    task do_read_burst(input [24:0] start_addr);
        begin
            address = start_addr;
            read    = 1;
            @(posedge clk);
            read    = 0;
        end
    endtask

    // Generates scenarios
    initial begin
        // Init
        clk = 0;
        reset = 1;
        address = 0;
        read = 0;
        write = 0;
        data_in = 0;
        #(CLK_PERIOD*5);
        reset = 0;
	wait(dut.ready);
	$display("sdram ready");

        // Scenario 1: same bank+row burst writes
	//$display("\nscenario 1\n");
        do_write_burst({2'b00, 13'h0123, 10'h10}, 16'hA000); // bank=0 row=0x0123 col=0x10
        do_write_burst({2'b00, 13'h0123, 10'h14}, 16'hB000); // same bank/row diff col

        // Scenario 2: different bank same row
	//
	//$display("\nscenario 2\n");
        do_write_burst({2'b01, 13'h0123, 10'h20}, 16'hC000);

        // Scenario 3: different row same bank
	//
	//$display("\nscenario 3\n");
        do_write_burst({2'b00, 13'h0456, 10'h30}, 16'hD000);

        // Scenario 4: read bursts
	//
	//$display("\nscenario 4\n");
        do_read_burst({2'b10, 13'h0222, 10'h05});
        do_read_burst({2'b10, 13'h0222, 10'h09});

        // Scenario 5: back-to-back mixed commands
	//$display("\nscenario 4\n");
        do_write_burst({2'b11, 13'h0AAA, 10'h15}, 16'hE000);
        do_read_burst({2'b11, 13'h0AAA, 10'h15});
        do_write_burst({2'b01, 13'h0BBB, 10'h01}, 16'hF000);

	`ifdef TEST
		interface_start = 1;
		$display("START OF INTERFACE");
	`endif
	


        #(CLK_PERIOD*20);
	#1000;
        $finish;
    end

endmodule

