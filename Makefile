# Simulation and lint for the SDRAM controller.
#
#   make test       FIFO, controller (all parameter sets) and board tests
#   make sim        one controller run, with VCD:  make sim CLK_FREQ=143 BL=8 BT=INTR WM=1 SEED=3
#   make lint       Verilator lint of the RTL
#   make mutation   check that the controller testbench catches known bugs
#   make synth      Yosys synthesis check (M9K family, close to the MAX 10)
#
# Needs Icarus Verilog (iverilog/vvp), Verilator, Python 3 and, for synth, Yosys.

BUILD    := build
RTL      := rtl/synch_fifo.v rtl/sdram_interface.v
MODEL    := sim/sdram_model.v
BOARD    := board/de10_lite/rtl/final_top.v board/de10_lite/rtl/cmd.v board/de10_lite/rtl/byte_2x1.v
IVERILOG := iverilog -g2012
OPS      ?= 20000
SEED     ?= 1

CLK_FREQ ?= 133
BL       ?= 4
BT       ?= SEQ
WM       ?= 0

CTRL_TB  := $(RTL) $(MODEL) sim/tb_sdram_interface.v
TB       := tb_sdram_interface

.PHONY: test test-fifo test-ctrl test-board sim lint mutation synth clean

test: test-fifo test-ctrl test-board
	@echo "all tests passed"

$(BUILD):
	@mkdir -p $(BUILD)

# --- FIFO ---------------------------------------------------------------
test-fifo: | $(BUILD)
	@for d in 2 8 512; do \
		$(IVERILOG) -Ptb_synch_fifo.DEPTH=$$d -o $(BUILD)/fifo.vvp -s tb_synch_fifo rtl/synch_fifo.v sim/tb_synch_fifo.v || exit 1; \
		r=$$(vvp -n $(BUILD)/fifo.vvp | grep -E '^(PASS|FAIL)'); \
		echo "fifo DEPTH=$$d: $$r"; [ "$$r" = PASS ] || exit 1; \
	done

# --- controller, every parameter combination ----------------------------
test-ctrl: | $(BUILD)
	@for f in 133 143; do for bl in 1 2 4 8; do for bt in SEQ INTR; do for wm in 0 1; do \
		$(IVERILOG) -o $(BUILD)/ctrl.vvp -s $(TB) \
			-P$(TB).CLK_FREQ=$$f -P$(TB).BURST_LENGTH=$$bl \
			-P$(TB).BURST_TYPE=\"$$bt\" -P$(TB).BURST_WR_MODE=$$wm $(CTRL_TB) || exit 1; \
		r=$$(vvp -n $(BUILD)/ctrl.vvp +ops=$(OPS) +seed=$(SEED) | grep -E '^(PASS|FAIL)'); \
		echo "ctrl $$f MHz BL=$$bl $$bt WR_MODE=$$wm: $$r"; \
		case "$$r" in PASS) ;; *) exit 1;; esac; \
	done; done; done; done

# --- board top-level, with UART/PLL stand-ins ---------------------------
test-board: | $(BUILD)
	@$(IVERILOG) -o $(BUILD)/board.vvp -s tb_final_top $(RTL) $(BOARD) \
		board/de10_lite/sim/stubs.v $(MODEL) board/de10_lite/sim/tb_final_top.v
	@r=$$(vvp -n $(BUILD)/board.vvp | grep -E '^(PASS|FAIL)'); \
		echo "board final_top: $$r"; [ "$$r" = PASS ]

# --- single run with waveform -------------------------------------------
sim: | $(BUILD)
	$(IVERILOG) -o $(BUILD)/sim.vvp -s $(TB) -s wave_dump \
		-P$(TB).CLK_FREQ=$(CLK_FREQ) -P$(TB).BURST_LENGTH=$(BL) \
		-P$(TB).BURST_TYPE=\"$(BT)\" -P$(TB).BURST_WR_MODE=$(WM) \
		$(CTRL_TB) sim/wave_dump.v
	cd $(BUILD) && vvp -n sim.vvp +ops=$(OPS) +seed=$(SEED)

# --- lint ---------------------------------------------------------------
lint:
	@for f in 133 143; do for bl in 1 2 4 8; do for bt in SEQ INTR; do for wm in 0 1; do \
		verilator --lint-only -Wall $(RTL) --top-module sdram_interface \
			-GCLK_FREQ=$$f -GBURST_LENGTH=$$bl -GBURST_TYPE='"'$$bt'"' -GBURST_WR_MODE=$$wm || exit 1; \
	done; done; done; done
	verilator --lint-only --timing -Wall -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
		$(RTL) $(BOARD) board/de10_lite/sim/stubs.v --top-module final_top
	@echo "lint clean"

mutation:
	python3 sim/mutate.py

# cycloneiv uses the same M9K blocks as the MAX 10; checks the RTL synthesizes
# and the command FIFO maps to block RAM
synth: | $(BUILD)
	yosys -q -p "read_verilog $(RTL); synth_intel -family cycloneiv -top sdram_interface; tee -q -o $(BUILD)/synth.txt stat"
	@grep -E "Number of cells|altsyncram" $(BUILD)/synth.txt | tail -2
	@grep -q altsyncram $(BUILD)/synth.txt || (echo "command FIFO did not map to block RAM"; exit 1)

clean:
	rm -rf $(BUILD)
