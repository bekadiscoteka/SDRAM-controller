
`ifndef SDRAM_CTRL

	`define	SDRAM_CTRL

							// designed for sdram from issi with speed -7 inside of terasic de10 lite 
	
	`define LOAD_BURST_LENGTH	DRAM_ADDR[2:0]
	`define LOAD_BURST_TYPE 	DRAM_ADDR[3]	
	`define LOAD_CAS 		DRAM_ADDR[6:4]
	`define LOAD_BURST_WR_MODE 	DRAM_ADDR[9]
							// internal address conventions
	`define BANK_ADDR 		_address[24:23]
	`define ROW_ADDR 		_address[22:10]
        `define COLUMN_ADDR 		_address[9:0]	
	
	module sdram_interface #(
		parameter	CLK_FREQ=133, 		// 143 or 133
				BURST_LENGTH = 1,
				INTERLEAVED = 0,  	// SEQ = sequential 
						     	// INTR = interleaved	
				BURST_WR_MODE = 0  	// 0 = burst applied to READ operation only
						       	// 1 = applied to both
	)(
							// interface
		output reg	ready, 			// ready for accepting command
				valid, 			// data out is valid 
		output [15:0]	data_out,
		input  [24:0]	address,
		input  [15:0]	data_in,
		input 		read,
		input 		write,
		input 		clk,
				//turn_on,
				reset,

							// SDRAM connections
		inout      [15:0] 	DRAM_DQ,
		output reg [12:0]	DRAM_ADDR,	
		output reg [1:0] 	DRAM_BA,
		output  		DRAM_CLK,
		output reg 		DRAM_CKE,

							//active low
				
		output reg 	DRAM_LDQM,  		
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
		reg [log2(13300)-1:0] counter; 
		reg [2:0] 	autoref_counter;
		reg 		_read, 
				_write, 		// registering the input
				refresh,
				valid_in,
			 	warning;		// stop light for all operations, refresh is about to happen	
		reg [3:0]	delay,        		// delay parameter that can be passed between states
			 	init_state,
				state,
				burst_counter,
				burst_finish;
		reg [7:0] 	valid_pipe;
		reg [24:0] 	_address;
		reg [15:0] 	_data_in;
		
		assign DRAM_DQ = (state == WRITE) ? _data_in : 16'bz;
		assign DRAM_CLK = clk;
		assign data_out = DRAM_DQ;	
		
		wire burst_read_ready = burst_counter == burst_finish;
		wire burst_pre_ready = burst_read_ready && !valid_pipe[CAS-RP:0]; // assume RP < CAS always
		wire valid_trigger = (_read && state == ACTIVE);

							// refresh logic goes
							// purpose: track the refresh period and send warning if it
							// is close. Eventually call auto refresh

		always @(posedge clk, posedge reset) begin
			if (reset) begin
				REFRESH_COUNTER <= 0;
				warning <= 0;
			end	
			else begin
				REFRESH_COUNTER <= state != INIT ? REFRESH_COUNTER + 1 : 0;
				if (REFRESH_COUNTER >= WARNING) warning <= 1;	
				if (REFRESH_COUNTER == AUTO_REFRESH_T) begin
					refresh <= 1;
					REFRESH_COUNTER <= 0;
				end
				else begin
				       	warning <= 0;
					refresh <= 0;
				end
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
				ready <= 0;
				delay <= 13300; // latency(100e-6) fixed latency for specific sdram boot
				_read <= 0;
				_write <= 0;
				_address <= 0;

				burst_finish <= 0;
				burst_counter <= 0;
				valid_pipe <= 0;
				valid_in <= 0;
				
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
						if (warning) begin
							ready <= 0;
						end
						else if (refresh) DO_AREF(RC);
						else if ((write ^ read)) begin

							// in future
							// this block
							// will be
							// separate
							// task	
							_write <= write;
							_read <= read;
							_data_in <= data_in;
							_address <= address;

							DO_ACTIVE(RCD);
							state <= ACTIVE;
							ready <= 0;
						end							
						else begin
						       	ready <= 1;
							_write <= 0;
						end
					end
					ACTIVE: begin
						if (_write) begin
							DO_WRITE(0);
							state <= WRITE;
						end
						else if (_read) begin
							DO_READ(0);
							BURST_START();
							state <= READ;
						end
							/*
							* 
							*/
					end
					READ: begin
						if (burst_read_ready) valid_in <= 0;
						if (burst_pre_ready) begin
							PRE(RP);
							state <= IDLE;	
						end											
						else NOP();
							
					end
					WRITE: begin
						PRE(RP);
						state <= IDLE;
					end
				endcase	
			end
			else begin
			       	NOP();
				counter <= counter + 1;
			end
			
			//	BURST LOGIC	
			// ---------------------------------------------------

			burst_counter <= (burst_counter == burst_finish) ? burst_counter : 
									   burst_counter + 1;

			//	valid signal pipeline	
			
			valid_pipe[7:1] <= {valid_pipe[6:1], valid_in};
			valid <= valid_pipe[CAS]; 

			//----------------------------------------------------
			end
		end

		task BURST_START;
			begin
				burst_finish <= burst_finish + BURST_LENGTH - 1;	
				valid_in <= 1;
			end
		endtask

		task NOP;
			begin
				DRAM_nCS <= 0;
				DRAM_nRAS <= 1;
				DRAM_nCAS <= 1;
				DRAM_nWE <= 1;	
			end
		endtask
		
		task DO_PALL(input integer _delay);
			begin
				DRAM_nCS <= 0;
				DRAM_nRAS <= 0; 
				DRAM_nCAS <= 1;
				DRAM_nWE <= 0;	
				DRAM_ADDR[10] <= 1;
				counter <= 0;

				delay <= _delay; 
			end

		endtask

		task DO_AREF(input integer _delay);
			begin
				DRAM_CKE <= 1;
				DRAM_nCS <= 0;
				DRAM_nRAS <= 0; 
				DRAM_nCAS <= 0;
				DRAM_nWE <= 1;	
				counter <= 0;			
				delay <= _delay;
			end
		endtask	

		task DO_LMR(input integer _delay);
			begin
				DRAM_nCS <= 0;
				DRAM_nRAS <= 0; 
				DRAM_nCAS <= 0;
				DRAM_nWE <= 0;	
				DRAM_BA <= 0;
				delay <= _delay;

				`LOAD_BURST_LENGTH <=	BURST_LENGTH == 1 ? 0 :
							BURST_LENGTH == 2 ? 1 :
							BURST_LENGTH == 4 ? 2 :
							BURST_LENGTH == 8 ? 3 : 0;	

				`LOAD_BURST_TYPE <= INTERLEAVED;
				`LOAD_BURST_WR_MODE <=	BURST_WR_MODE == 1 ? 0 : 1;
				`LOAD_CAS <= 		CAS;

				counter <= 0;			
			end
		endtask	

		task DO_ACTIVE(input integer _delay);
			begin
				DRAM_nCS <= 0;
				DRAM_nRAS <= 0; 
				DRAM_nCAS <= 1;
				DRAM_nWE <= 1;	
				DRAM_BA <= `BANK_ADDR;
				DRAM_ADDR <= `ROW_ADDR;	

				delay <= _delay;
				counter <= 0;
			end
		endtask

		task DO_READ(input integer _delay);
			begin
				DRAM_nCS <= 0;
				DRAM_nRAS <= 1; 
				DRAM_nCAS <= 0;
				DRAM_nWE <= 1;			
				DRAM_BA <= `BANK_ADDR;
				DRAM_ADDR[9:0] <= `COLUMN_ADDR;
				DRAM_ADDR[10] <= 0; // fixed for now

				counter <= 0;
				delay <= _delay;
			end
		endtask

		task DO_WRITE(input integer _delay);
			begin
				DRAM_nCS <= 0;
				DRAM_nRAS <= 1; 
				DRAM_nCAS <= 0;
				DRAM_nWE <= 0;			
				DRAM_BA <= `BANK_ADDR;
				DRAM_ADDR[9:0] <= `COLUMN_ADDR;
				DRAM_ADDR[10] <= 0; // fixed for now

				delay <= _delay;
				counter <= 0;
			end
		endtask

		task PRE(input integer _delay);
			begin
				DRAM_nCS <= 0;
				DRAM_nRAS <= 0; 
				DRAM_nCAS <= 1;
				DRAM_nWE <= 0;						
				DRAM_ADDR[10] <= 0;
				DRAM_BA <= `BANK_ADDR;
				
				delay <= _delay;
				counter <= 0;
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
