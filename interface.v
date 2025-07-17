
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
				BURST_TYPE = "SEQ",  	// SEQ = sequential 
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
	
		localparam	CAS = (CLK_FREQ == 143) ? 3 : 2,
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
			 	warning;		// stop light for all operations, refresh is about to happen	
		reg [3:0]	_delay,        		// delay parameter that can be passed between states
			 	init_state,
				state,
				burst_state;	
		reg [24:0] 	_address;
		reg [15:0] 	_data_in;
		
		assign DRAM_DQ = (_write && state == ACTIVE) ? _data_in : 16'bz;
		assign DRAM_CLK = clk;
		assign data_out = DRAM_DQ;	

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
				burst_state <= IDLE;
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
				_delay <= 0;
				_read <= 0;
				_write <= 0;
				_address <= 0;
				
			end
			else begin
				case (state)
					INIT: begin
						case (init_state)	
							PRE_PALL: begin
								if (counter == 13300) begin //latency(100e-6)
									DO_PALL();
									init_state <= PALL;
								end
								else NOP();
							end
							PALL: begin
								if (counter == RP) begin
									DO_AREF();
									init_state <= AREF;
								end
								else NOP();
							end
							AREF: begin 
								if (counter == RC) begin
									autoref_counter <= autoref_counter + 1;
									if (&autoref_counter) begin
										DO_LMR();
										init_state <= LMR;
									end
									else DO_AREF();
								end
								else NOP();
							end
							LMR: if (counter == MRD) begin
								state <= IDLE;  
								counter <= 0;
								_delay <= 0;
							end
							else NOP();
						endcase
					end
					
					// operating mode

					IDLE: begin
						if (counter == _delay) begin
							if (warning) begin
								ready <= 0;
							end
							else if (refresh) begin
								DO_AREF();
								_delay <= RC; 
							end
							else if ((write ^ read)) begin
								_write <= write;
								_read <= read;
								_data_in <= data_in;
								_address <= address;
								DO_ACTIVE();
								_delay <= RCD;
								ready <= 0;
							end							
							else begin
								ready <= 1;
							end
						end
						else NOP();
					end
					ACTIVE: begin
						if (counter == _delay) begin
							if (_write) begin
							       	DO_WRITE();
								_delay <= 0;
							end
							else if (_read) begin
							       	DO_READ(); 
								_delay <= CAS;
							end
						end	
						else NOP();
					end
					READ: begin
						if (counter == _delay) begin
							PRE();

							_delay <= RP;

							/*
							if (BURST_LENGTH > RP) begin
								if (BURST_LENGTH - PR - 1) begin
									PRE(address[14:13]);
									_delay <= PR;
								end
							end
							else PRE(address[14:13]);
							*/
							
						       

						end
						else if (counter == _delay-1) begin
							burst_state <= READ;
							NOP();
						end
						else NOP();
					end
					WRITE: begin
					       	PRE();
						_delay <= RP;
					end

				endcase	
				
				// burst logic

				case (burst_state) 
					IDLE: begin
						valid <= 0;
					end
					READ: begin
						valid <= 1;
						// it should count up to burst
						// length

						burst_state <= IDLE;
					end
				endcase

			end
		end

		task NOP;
			begin
				DRAM_nCS <= 0;
				DRAM_nRAS <= 1;
				DRAM_nCAS <= 1;
				DRAM_nWE <= 1;	
				counter <= counter + 1;
			end
		endtask
		
		task DO_PALL;
			begin
				DRAM_nCS <= 0;
				DRAM_nRAS <= 0; 
				DRAM_nCAS <= 1;
				DRAM_nWE <= 0;	
				DRAM_ADDR[10] <= 1;
				counter <= 0;
			end

		endtask

		task DO_AREF;
			begin
				DRAM_CKE <= 1;
				DRAM_nCS <= 0;
				DRAM_nRAS <= 0; 
				DRAM_nCAS <= 0;
				DRAM_nWE <= 1;	
				counter <= 0;			
			end
		endtask	

		task DO_LMR;
			begin
				DRAM_nCS <= 0;
				DRAM_nRAS <= 0; 
				DRAM_nCAS <= 0;
				DRAM_nWE <= 0;	
				DRAM_BA <= 0;

				`LOAD_BURST_LENGTH <=	BURST_LENGTH == 1 ? 0 :
							BURST_LENGTH == 2 ? 1 :
							BURST_LENGTH == 4 ? 2 :
							BURST_LENGTH == 8 ? 3 : 1;	

				`LOAD_BURST_TYPE <=	BURST_TYPE == "INTR" ? 1 : 0;
				`LOAD_BURST_WR_MODE <=	BURST_WR_MODE == 1 ? 0 : 1;
				`LOAD_CAS <= 		CAS;

				counter <= 0;			
			end
		endtask	

		task DO_ACTIVE;
			begin
				DRAM_nCS <= 0;
				DRAM_nRAS <= 0; 
				DRAM_nCAS <= 1;
				DRAM_nWE <= 1;	
				DRAM_BA <= `BANK_ADDR;
				DRAM_ADDR <= `ROW_ADDR;	

				state <= ACTIVE;
				counter <= 0;
			end
		endtask

		task DO_READ;
			begin
				DRAM_nCS <= 0;
				DRAM_nRAS <= 1; 
				DRAM_nCAS <= 0;
				DRAM_nWE <= 1;			
				DRAM_BA <= `BANK_ADDR;
				DRAM_ADDR[9:0] <= `COLUMN_ADDR;
				DRAM_ADDR[10] <= 0; // fixed for now

				state <= READ;
				counter <= 0;
			end
		endtask

		task DO_WRITE;
			begin
				DRAM_nCS <= 0;
				DRAM_nRAS <= 1; 
				DRAM_nCAS <= 0;
				DRAM_nWE <= 0;			
				DRAM_BA <= `BANK_ADDR;
				DRAM_ADDR[9:0] <= `COLUMN_ADDR;
				DRAM_ADDR[10] <= 0; // fixed for now

				state <= WRITE;
				counter <= 0;
			end
		endtask

		task PRE;
			begin
				DRAM_nCS <= 0;
				DRAM_nRAS <= 0; 
				DRAM_nCAS <= 1;
				DRAM_nWE <= 0;						
				DRAM_ADDR[10] <= 0;
				DRAM_BA <= `BANK_ADDR;
				
				state <= IDLE;
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
