# SDRAM Controller for Terasic DE10-Lite

A Verilog controller for the ISSI IS42S16320D (-7) SDRAM on the DE10-Lite
board. It handles power-up initialization, auto-refresh and burst reads and
writes, with a command FIFO in front and an open-row policy.

The repository also has a UART demo top-level for the board and a
self-checking simulation environment with a behavioral SDRAM model.

## Repository layout

```
rtl/                    controller RTL (board independent)
  sdram_interface.v     the controller
  synch_fifo.v          first-word-fall-through FIFO (block RAM)
board/de10_lite/
  rtl/                  UART demo: final_top.v, cmd.v, byte_2x1.v
  sim/                  board test and UART/PLL stand-ins
  final_top.sdc         timing constraints
sim/
  sdram_model.v         SDRAM model with protocol and timing checks
  tb_sdram_interface.v  controller testbench
  tb_synch_fifo.v       FIFO testbench
  mutate.py             mutation test for the testbench
docs/IS42S16320D.pdf    datasheet
```

## Controller

### Parameters

| Parameter          | Default | Description |
|--------------------|---------|-------------|
| `CLK_FREQ`         | 133     | Clock in MHz: `133` (CL2) or `143` (CL3). Lower clocks use the 133 MHz timings. |
| `BURST_LENGTH`     | 4       | 1, 2, 4 or 8 words |
| `BURST_TYPE`       | `"SEQ"` | `"SEQ"` sequential, `"INTR"` interleaved |
| `BURST_WR_MODE`    | 0       | 0: bursts on reads only. 1: reads and writes (see below) |
| `CMD_FIFO_DEPTH`   | 512     | Command FIFO depth, power of two |
| `USE_START`        | 0       | 1: queued commands only run while `start` is high |
| `RD_CAPTURE_DELAY` | 1       | Extra cycles between the nominal CAS edge and the DQ capture (see *Clocking*) |
| `POWERUP_US`       | 100     | Power-up wait before initialization |

### User interface

| Signal     | Dir | Width | Description |
|------------|-----|-------|-------------|
| `clk`      | in  | 1     | Controller clock, also sent to the SDRAM |
| `reset`    | in  | 1     | Active high, asynchronous |
| `ready`    | out | 1     | A command can be accepted. Low during initialization and while the FIFO is full |
| `read`     | in  | 1     | Read command |
| `write`    | in  | 1     | Write command |
| `address`  | in  | 25    | `[24:23]` bank, `[22:10]` row, `[9:0]` column |
| `data_in`  | in  | 16    | Write data |
| `valid`    | out | 1     | `data_out` holds a read word, one cycle per word |
| `data_out` | out | 16    | Read data |
| `start`    | in  | 1     | Only with `USE_START=1`; otherwise leave it unconnected |

A command is accepted on a rising edge where `ready` is high and exactly one
of `read`/`write` is high. If both are high, nothing is accepted.

Commands run in the order they were accepted:

* **read** returns `BURST_LENGTH` words on consecutive `valid` cycles, in
  SDRAM burst order starting at the requested column. With `BURST_LENGTH=4`,
  sequential order, and column 6, that is columns 6, 7, 4, 5.
* **write** writes exactly one word at its address. With `BURST_WR_MODE=1`,
  the controller issues a write burst. Writes already queued behind it are
  merged into the burst when they target the next columns of the same burst,
  in burst order. Burst slots with no matching write are masked with DQM, so
  neighbouring words are never touched.

### Operation

* **Init**: 100 µs wait, PRECHARGE ALL, 8 × AUTO REFRESH, LOAD MODE REGISTER.
* **Open-row policy**: a row stays open until a command needs another row or
  bank, or a refresh is due. Only one bank is open at a time.
* **Refresh**: a request is raised about every 7.7 µs (1021 cycles at 133 MHz,
  1099 at 143 MHz). The controller finishes the current burst, precharges the
  open bank, then refreshes. The datasheet limit is 7.8125 µs.

### Timing (clock cycles, from the datasheet table)

| Clock   | CL | tRCD | tRP | tRC | tRAS | tDPL | tMRD |
|---------|----|------|-----|-----|------|------|------|
| 133 MHz | 2  | 2    | 2   | 8   | 5    | 2    | 2    |
| 143 MHz | 3  | 3    | 3   | 9   | 6    | 2    | 2    |

Each constraint has its own down-counter in the controller, so a command is
issued as soon as every constraint that applies to it has been met.

### Clocking

`DRAM_CLK` is the controller clock sent straight to the pin, without a phase
shift. With that setup, read data reaches the FPGA about one cycle after the
nominal CAS edge. The controller therefore captures DQ one cycle later in an
I/O register (`RD_CAPTURE_DELAY = 1`), which is the alignment that was
validated on hardware. The SDRAM I/O timing is not constrained in
`final_top.sdc` yet; the file says what is needed to constrain it.

### Example

```verilog
sdram_interface #(
    .CLK_FREQ(133),
    .BURST_LENGTH(4),
    .BURST_TYPE("SEQ"),
    .BURST_WR_MODE(0)
) dram_ctrl (
    .clk(clk_133MHz),  .reset(rst),
    .address(addr),    .data_in(wr_data), .read(rd_en), .write(wr_en),
    .ready(cmd_ready), .valid(rd_valid),  .data_out(rd_data),
    .start(1'b1),
    .DRAM_DQ(DRAM_DQ), .DRAM_ADDR(DRAM_ADDR), .DRAM_BA(DRAM_BA),
    .DRAM_CLK(DRAM_CLK), .DRAM_CKE(DRAM_CKE),
    .DRAM_LDQM(DRAM_LDQM), .DRAM_HDQM(DRAM_HDQM),
    .DRAM_nWE(DRAM_nWE), .DRAM_nCAS(DRAM_nCAS),
    .DRAM_nRAS(DRAM_nRAS), .DRAM_nCS(DRAM_nCS)
);
```

## DE10-Lite UART demo

`board/de10_lite/rtl/final_top.v` drives the controller from a UART at
9600 baud:

| Host sends                    | Effect |
|-------------------------------|--------|
| `W` d1 d0 bank a2 a1 a0       | write `{d1,d0}` |
| `R` bank a2 a1 a0             | read; returns `BURST_LENGTH` words, two bytes each, LSB first |

Here `address = {bank[1:0], a2, a1, a0[6:0]}`.

`status_leds` = {SDRAM ready, PLL locked, command in progress, error}. The
error LED covers a bad command byte and also sticks on if a command or read
data was dropped because a buffer was full.

The demo needs two modules that are **not in this repository**:

* `uart`: the UART with RX/TX FIFOs, expected at `uart/uart.v`.
  `final_top` starts a new read word only when `tx_empty` is high, so the
  two bytes of a word always fit in the TX FIFO.
* `pll`: a Quartus ALTPLL with 50 MHz in and 133 MHz on `c0`.

Quartus project files: `rtl/synch_fifo.v`, `rtl/sdram_interface.v`,
`board/de10_lite/rtl/*.v`, the `uart` and `pll` sources, and
`board/de10_lite/final_top.sdc`.

## Verification

```
make test       # FIFO, controller (all 32 parameter sets), board top-level
make lint       # Verilator -Wall, every parameter set
make synth      # Yosys synthesis, checks the FIFO maps to M9K block RAM
make mutation   # injects known bugs and checks the testbench catches each one
make sim CLK_FREQ=143 BL=8 BT=INTR WM=1 SEED=3   # one run, writes build/sdram.vcd
```

You need Icarus Verilog, Verilator, Yosys and Python 3. CI runs all of the
above on every push (`.github/workflows/verify.yml`).

**SDRAM model** (`sim/sdram_model.v`). It stores data and flags any of the
following:

* Commands before the 100 µs power-up wait.
* A wrong init order, or fewer than 8 refreshes before LOAD MODE REGISTER.
* Reserved mode register bits set, or a CAS latency that does not match the
  clock.
* ACTIVE to a bank that is already active; READ/WRITE to an idle bank;
  refresh or LMR with a bank open.
* tRCD, tRP, tRC, tRAS, tRRD, tDPL or tMRD violations.
* Refresh gaps over 7.8125 µs.
* Interrupted read or write bursts.

It applies DQM per byte, with read-mask latency 2.

**Controller testbench** (`sim/tb_sdram_interface.v`):

* Drives directed and random traffic through `ready`: back-to-back,
  read-heavy, write-heavy and sparse, plus a row left open across refreshes,
  bank/row switching, both strobes high, commands held during init, and FIFO
  back-pressure.
* Keeps a shadow memory and checks every read word.
* Checks that never-written words are still unwritten, that every accepted
  write lands exactly once, and that DQ never has two drivers.

**Mutation test**. `make mutation` applies 22 single bugs to the RTL and
confirms the testbench fails for each. The list includes every bug found in
the earlier version of the controller.

**Board test** (`board/de10_lite/sim/tb_final_top.v`). It sends UART commands
through `final_top` and the SDRAM model and checks the returned bytes,
including back-to-back reads against a slow UART.

## Limitations

* One open row at a time; there is no bank interleaving.
* SDRAM I/O timing is unconstrained, and `RD_CAPTURE_DELAY` was found on
  hardware (see *Clocking*).
* The UART host protocol has no flow control. If reads are sent faster than
  their data can go out at 9600 baud, the read buffer (512 words) eventually
  fills and the error LED turns on.
