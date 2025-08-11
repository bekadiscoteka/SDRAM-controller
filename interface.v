
`ifndef SDRAM_CTRL
	`define	SDRAM_CTRL

	`include "synch_fifo.v"

											// designed for sdram from issi with speed -7 inside of terasic de10 lite 
	
	`define LOAD_BURST_LENGTH	DRAM_ADDR[2:0]
	`define LOAD_BURST_TYPE 	DRAM_ADDR[3]	
	`define LOAD_CAS 			DRAM_ADDR[6:4]
	`define LOAD_BURST_WR_MODE 	DRAM_ADDR[9]
											// internal address conventions
	`define BANK_ADDR 			_address[24:23]
	`define ROW_ADDR 			_address[22:10]
    `define COLUMN_ADDR 		_address[9:0]	

	
	module sdram_interface #(
		parameter	CLK_FREQ=133, 			// 143 or 133
					BURST_LENGTH = 4,
					BURST_TYPE = "SEQ",  	// SEQ = sequential INTR = interleaved	
					BURST_WR_MODE = 0		// 0 = burst applied to READ operation only
						       				// 1 = applied to both
	)(
											// interface
		output reg			valid, 					
		output 				ready,				// ready for accepting command
		output [15:0]		data_out,
		input  [24:0]		address,
		input  [15:0]		data_in,
		input 				read,
		input 				write,
		input 				clk,
							reset,
		
		`ifdef TEST
							start,
		`endif
					

							// SDRAM connections
		inout      [15:0] 	DRAM_DQ,
		output reg [12:0]	DRAM_ADDR,	
		output reg [1:0] 	DRAM_BA,
		output  			DRAM_CLK,
		output reg 			DRAM_CKE,

							//active low
				
		output reg 			DRAM_LDQM,  		
							DRAM_HDQM,
							DRAM_nWE,
							DRAM_nCAS,
							DRAM_nRAS,
							DRAM_nCS

	);

							// ALL LATENCIES 
	
		localparam integer	
				CAS = (CLK_FREQ == 143) ? 3 : 2,
				MRD = 2,
				DMD = 0, 
				QMD = 2,
				PQL = 1,
				WDL = 0,
				RQL = 2,
				WBD = 0,
				RBD = 2,
				DAL = 4,
				DPL = 2,
				CCD = 1,
				RRD = 2,
				RP = 2,
				RAS = 5,
				RC = 8,
				RAC = 4,
				RCD = 2,	
				
				AUTO_REFRESH_T = 1040,
				WARNING = AUTO_REFRESH_T - 15;	


		localparam 	PRE_PALL=0,
					AREF=1,
					PALL=2,
					LMR=3,
					INIT=4,
					IDLE=5,
					ACTIVE=6,
					WRITE=7,
					READ=8;
				

		reg [log2(AUTO_REFRESH_T)-1:0]	REFRESH_COUNTER; 
		reg [log2(13300)-1:0] 			counter; 
		reg [2:0] 						autoref_counter;


		wire warn_signal = REFRESH_COUNTER >= WARNING;
		wire refresh = REFRESH_COUNTER == AUTO_REFRESH_T;
	
	
		wire	cmd_empty,
				cmd_valid,
				cmd_full;
			


 		// registering the input
		// stop light for all operations, refresh is about to happen	
			
		reg [3:0]			delay,        		// delay parameter that can be passed between states
			 				init_state,
							state;
		wire [24:0] 		_address;
		reg [15:0] 			_data_in;
		wire [15:0]			fifo_data_in;
		wire 				_write,
							_read;

		wire [(2+13)-1:0]	current_bank_row  = {`BANK_ADDR, `ROW_ADDR};
		reg [(2+13)-1:0]	prev_bank_row;



		reg 				valid_in;
		reg	[3:0] 			burstRead_counter,
							burstRead_finish;
		reg 	[7:0] 		valid_pipe;	

		wire 	burstRead_read_ready 	= burstRead_counter == burstRead_finish;
		wire 	burstRead_done 	  		= !( |{ valid_pipe[CAS:1], valid_in } ); 	// {valid_pipe[CAS:1], valid_in} == 0;
		wire 	burstRead_PRE_ready  	= burstRead_read_ready && !valid_pipe[CAS-RP:0];// assume RP < CAS always



		reg	[3:0]	burstWrite_counter,
					burstWrite_finish;
		wire		burstWrite_done	= burstWrite_counter == burstWrite_finish;
		wire 		burstWrite_PRE_ready = burstWrite_done;	// only for now



		assign ready 	= !cmd_full && ( state != INIT ) && !warn_signal && !refresh;
		assign DRAM_DQ 	= !burstWrite_done ? _data_in : 16'bz;
		assign DRAM_CLK = clk;
		assign data_out = DRAM_DQ;	

		reg 	fetch;


		generate 
			if (BURST_WR_MODE) begin
				always @* begin
				    fetch = 1'b0;  // default

				    if (delay == counter `ifdef TEST && start `endif) begin
					if (warn_signal && burstWrite_done) fetch = 0;
					// ACTIVE state case
					else if (!cmd_valid) fetch = 1;
					else if (state == ACTIVE) begin	
						if (!burstWrite_done && (burstWrite_counter != burstWrite_finish - 1)) begin
							if (_write) fetch = 1;		
						end
					    	else if (prev_bank_row == current_bank_row) begin
						    if (_write) begin
							if (burstRead_done && burstWrite_done)
							    fetch = 1'b1;
						    end
					    	else if (_read) begin
							if (burstWrite_done && burstRead_done)
						    	fetch = 1'b1;
					    	end
					    end
					end
					
					// IDLE state case
					else if (state == IDLE && !refresh && !warn_signal) begin
					    if (!_write && !_read)
						fetch = 1'b1;
					end
				    end
				end
			end
			else begin
				always @* begin
				    fetch = 1'b0;  // default

				    if (delay == counter `ifdef TEST && start `endif) begin
					if (warn_signal && burstWrite_done) fetch = 0;
					// ACTIVE state case
					else if (!cmd_valid) fetch = 1;
					else if (state == ACTIVE) begin
					    if ((prev_bank_row == current_bank_row) && cmd_valid) begin
						    if (_write) begin
							if (burstRead_done && burstWrite_done)
							    fetch = 1'b1;
						    end
						    else if (_read) begin
							if (burstWrite_done && burstRead_done)
							    fetch = 1'b1;
						    end
					    end
					end
					
					// IDLE state case
					else if (state == IDLE && !refresh && !warn_signal) begin
					    if (!_write && !_read)
						fetch = 1'b1;
					end
				    end
				end
		end
		endgenerate


		//	=============================================================
		//  ||	COMMAND REGISTRATION 				   ||	
		//  	---------------------------------------------------------------
		// 	||	purpose: register every incoming command, save until ||
		// 	||	they are execute									
		// 	===============================================================
				
		synch_fifo #(
		    .DEPTH(512),
		    .DATA_WIDTH(43)
		) fifo_inst (
		    .clk       	( clk ),
		    .rst_n      ( ~reset ), // assuming reset is active-low
		    .data_in   	( { data_in, address, write, read } ), // ensure this is 43 bits total
		    .data_out  	( { fifo_data_in, _address, _write, _read } ), // same, must match 43
		    .w_en      	( write ^ read ), // or (write && !read)
		    .r_en      	( fetch ),
		    .empty     	( cmd_empty ),
		    .full      	( cmd_full ),
		    .valid		( cmd_valid )
		);
		

		

							// refresh logic goes
							// purpose: track the refresh period and send warn_signal if it
							// is close. Eventually call auto refresh


		always @(posedge clk, posedge reset) begin
			if (reset) begin
				REFRESH_COUNTER <= 0;
			end	
			else begin
				if (REFRESH_COUNTER == AUTO_REFRESH_T) begin
					REFRESH_COUNTER <= 0;
				end
				else 	REFRESH_COUNTER <= state != INIT ? REFRESH_COUNTER + 1 : 0;
			end
		end

							// interface logic 


		always @(posedge clk, posedge reset) begin
			if (reset) begin
				state <= INIT;
				init_state <= PRE_PALL;
				counter <= 0;
				autoref_counter <= 0;

				DRAM_nCS <= 0;
				DRAM_nRAS <= 1;
				DRAM_nCAS <= 1;
				DRAM_nWE <= 1;
				DRAM_CKE <= 1;
				DRAM_HDQM <= 0;
				DRAM_LDQM <= 0;
				DRAM_ADDR <= 0;
				DRAM_BA <= 0;

				valid <= 0;
				delay <= 13300; // latency(100e-6) fixed latency for specific sdram boot

				burstRead_finish <= 0;
				burstRead_counter <= 0;
				valid_pipe <= 0;
				valid_in <= 0;

				prev_bank_row <= 0;

				burstWrite_finish <= 0;
				burstWrite_counter <= 0;
				
			end
			else begin
			       	if (counter == delay) begin 
				case (state)
					INIT: begin
						case (init_state)	
							PRE_PALL: begin
								DO_PALL(RP);
								init_state <= PALL;
							end
							PALL: begin
								DO_AREF(RC);
								init_state <= AREF;
							end
							AREF: begin 
								autoref_counter <= autoref_counter + 1;
								if (&autoref_counter) begin
									DO_LMR(MRD);
									init_state <= LMR;
								end
								else DO_AREF(RC);
							end
							LMR: begin 
								state <= IDLE;  
								counter <= 0;
								delay <= 0;
							end
						endcase
					end
					
					// operating mode

					IDLE: begin
						if ( refresh ) begin
							DO_AREF(RC);
							$display("refreshing");
						end
						else if ( warn_signal ) NOP();
						else begin
							if ( _write ^ _read ) begin
								DO_ACTIVE(RCD);
								state <= ACTIVE;
								prev_bank_row <= current_bank_row;
							end
						end	
					end
					ACTIVE: begin
						if ( warn_signal) begin
							if (burstWrite_done) begin
								PRE(RP);
								state <= IDLE;
							end
						end
						else if (cmd_valid `ifdef TEST && start `endif) begin
							if ( ( prev_bank_row == current_bank_row )) begin 
								if ( _write ) begin
									if ( burstWrite_done && burstRead_done ) begin
										$display("write active");
										DO_WRITE(0);
										BURST_WRITE_START();

										// fetch is high automatically here
										prev_bank_row <= {`BANK_ADDR, `ROW_ADDR}; 
									end	
									else NOP();
								end
								else if ( _read ) begin
									if ( burstWrite_done && burstRead_done ) begin
										DO_READ(0);
										BURST_READ_START();

										// fetch is high automatically here
										prev_bank_row <= {`BANK_ADDR, `ROW_ADDR}; 
									end
									else NOP();
								end
								else NOP();
							end
							else if ( burstRead_done && burstWrite_done ) begin
								PRE(RP);
								state <= IDLE;
							end
							else NOP();
						end
						else NOP();
					end
				endcase	
			end
			else begin
			       	NOP();
				counter <= counter + 1;
			end

			//	BURST LOGIC
			// ------------------------------------------------------------------------

			burstRead_counter <= (burstRead_read_ready) ? 	burstRead_counter : burstRead_counter + 1;
									   
			//	BURST READ 
			//	----------
			
			valid_pipe[7:1] <= {valid_pipe[6:1], valid_in};
			valid <= valid_pipe[CAS]; 

			// -----------------------------------------------------------------------			
			// 	BURST WRITE
			// 	-----------
			burstWrite_counter <= (burstWrite_counter == burstWrite_finish) ? burstWrite_counter : burstWrite_counter + 1;					  
			_data_in <= fifo_data_in;
			end
		end

		task BURST_WRITE_START;
			begin
				burstWrite_finish <= BURST_WR_MODE ? burstWrite_finish + BURST_LENGTH : burstWrite_finish + 1;	


			end
		endtask

		task BURST_READ_START;
			begin
				burstRead_finish 	<= burstRead_finish + BURST_LENGTH - 1;	
				valid_in 			<= 1;
			end
		endtask


		task NOP;
			begin
				DRAM_nCS 	<= 0;
				DRAM_nRAS 	<= 1;
				DRAM_nCAS	<= 1;
				DRAM_nWE 	<= 1;	

				valid_in 	<= burstRead_read_ready ? 0 : valid_in; 
			end
		endtask
		
		task DO_PALL(input integer _delay);
			begin
				DRAM_nCS 		<= 0;
				DRAM_nRAS		<= 0; 
				DRAM_nCAS 		<= 1;
				DRAM_nWE 		<= 0;	
				DRAM_ADDR[10] 	<= 1;
				counter 		<= 0;

				delay 			<= _delay; 
			end

		endtask

		task DO_AREF(input integer _delay);
			begin
				DRAM_CKE 	<= 1;
				DRAM_nCS 	<= 0;
				DRAM_nRAS 	<= 0; 
				DRAM_nCAS 	<= 0;
				DRAM_nWE 	<= 1;	
				counter 	<= 0;			
				delay 		<= _delay;
			end
		endtask	

		task DO_LMR(input integer _delay);
			begin
				DRAM_nCS 	<= 0;
				DRAM_nRAS 	<= 0; 
				DRAM_nCAS 	<= 0;
				DRAM_nWE 	<= 0;	
				DRAM_BA 	<= 0;
				delay 		<= _delay;
				counter 	<= 0;	
				
				`LOAD_BURST_LENGTH <=	BURST_LENGTH == 1 ? 0 :
										BURST_LENGTH == 2 ? 1 :
										BURST_LENGTH == 4 ? 2 :
										BURST_LENGTH == 8 ? 3 : 0;	

				`LOAD_BURST_TYPE 	<=	BURST_TYPE == "INTR" ? 1 : 0;
				`LOAD_BURST_WR_MODE <=	BURST_WR_MODE == 1 ? 0 : 1;
				`LOAD_CAS 			<= 	CAS;
			end
		endtask	

		task DO_ACTIVE(input integer _delay);
			begin
				DRAM_nCS	<= 0;
				DRAM_nRAS 	<= 0; 
				DRAM_nCAS 	<= 1;
				DRAM_nWE  	<= 1;	
				DRAM_BA 	<= `BANK_ADDR;
				DRAM_ADDR 	<= `ROW_ADDR;	

				delay 		<= _delay;
				counter 	<= 0;
				
				valid_in 	<= burstRead_read_ready ? 0 : valid_in;
			end
		endtask

		task DO_READ(input integer _delay);
			begin
				DRAM_nCS 		<= 0;
				DRAM_nRAS 		<= 1; 
				DRAM_nCAS 		<= 0;
				DRAM_nWE 		<= 1;			
				DRAM_BA 		<= `BANK_ADDR;
				DRAM_ADDR[9:0] 	<= `COLUMN_ADDR;
				DRAM_ADDR[10] 	<= 0; // fixed for now

				counter 		<= 0;
				delay 			<= _delay;
			end
		endtask

		task DO_WRITE(input integer _delay);
		       	begin
				DRAM_nCS 		<= 0;
				DRAM_nRAS 		<= 1; 
				DRAM_nCAS 		<= 0;
				DRAM_nWE 		<= 0;			
				DRAM_BA 		<= `BANK_ADDR;
				DRAM_ADDR[9:0] 	<= `COLUMN_ADDR;
				DRAM_ADDR[10] 	<= 0; // fixed for now

				delay 			<= _delay;
				counter 		<= 0;


				valid_in 		<= burstRead_read_ready ? 0 : valid_in;
			end
		endtask

		task PRE(input integer _delay);
			begin
				DRAM_nCS 		<= 0;
				DRAM_nRAS 		<= 0; 
				DRAM_nCAS 		<= 1;
				DRAM_nWE 		<= 0;						
				DRAM_ADDR[10] 	<= 0;
				DRAM_BA 		<= `BANK_ADDR;
				
				delay 			<= _delay;
				counter 		<= 0;

				valid_in 		<= burstRead_read_ready ? 0 : valid_in;
			end
		endtask
/*
		function integer latency;
			input real value;
			begin
				latency = $rtoi(((CLK_FREQ * 1_000_000) * value) + 0.5);
			end
		endfunction	
*/	

		function integer log2;
			input integer arg;
			integer i;
			begin: loop
				for (i=0; i <= 31; i = i + 1) begin
					if (2**i > arg) begin
						log2 = i;
						disable loop;
					end
				end
			end
		endfunction

	endmodule



`endif
