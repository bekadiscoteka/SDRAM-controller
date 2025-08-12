# SDRAM Controller for Terasic DE10-Lite

## Overview
This project implements a functional SDRAM controller in Verilog for the ISSI -7 SDRAM chip used on the Terasic DE10-Lite FPGA board.  
The controller handles initialization, periodic refresh, single and burst read/write operations, and parameterizable CAS latency and burst modes.

It is designed for **functional correctness first**, with future optimization possible for burst efficiency and reduced latency.

---

## Features
- **Compatible SDRAM**: ISSI -7 (DE10-Lite onboard SDRAM)
- **Clock frequencies supported**: 133 MHz and 143 MHz
- **Automatic initialization sequence**
- **Auto-refresh** with configurable timing
- **Burst read/write support** (sequential or interleaved)
- **Parameterizable CAS latency**
- **Separate read/write ready signaling**
- **Bidirectional DQ bus handling**
- **Active-low SDRAM command signals control**

---

## Parameters
| Parameter       | Default | Description |
|-----------------|---------|-------------|
| `CLK_FREQ`      | 133     | SDRAM clock in MHz (`133` or `143`) |
| `BURST_LENGTH`  | 4       | Number of words in a burst |
| `BURST_TYPE`    | "SEQ"   | `"SEQ"` for sequential burst, `"INTR"` for interleaved |
| `BURST_WR_MODE` | 0       | `0`: burst for read only, `1`: burst for both read and write |

---

## Ports

### System Interface
| Signal      | Dir   | Width | Description |
|-------------|-------|-------|-------------|
| `clk`       | in    | 1     | Controller clock (matches SDRAM clock) |
| `reset`     | in    | 1     | Active-high reset |
| `valid`     | out   | 1     | Controller ready for new command |
| `ready`     | out   | 1     | Data available after read or write completion |
| `address`   | in    | 25    | 25-bit address (bank/row/column encoded) |
| `data_in`   | in    | 16    | Data to write |
| `data_out`  | out   | 16    | Data read from SDRAM |
| `read`      | in    | 1     | Start read operation |
| `write`     | in    | 1     | Start write operation |

### SDRAM Interface
| Signal      | Dir   | Width | Description |
|-------------|-------|-------|-------------|
| `DRAM_DQ`   | inout | 16    | SDRAM data bus |
| `DRAM_ADDR` | out   | 13    | Address bus |
| `DRAM_BA`   | out   | 2     | Bank address |
| `DRAM_CLK`  | out   | 1     | SDRAM clock |
| `DRAM_CKE`  | out   | 1     | SDRAM clock enable |
| `DRAM_LDQM` | out   | 1     | Lower byte mask |
| `DRAM_HDQM` | out   | 1     | Upper byte mask |
| `DRAM_nWE`  | out   | 1     | Write enable (active low) |
| `DRAM_nCAS` | out   | 1     | Column address strobe (active low) |
| `DRAM_nRAS` | out   | 1     | Row address strobe (active low) |
| `DRAM_nCS`  | out   | 1     | Chip select (active low) |

---

## Internal Address Mapping
address[24:23] → Bank
address[22:10] → Row
address[9:0] → Column

---

## Operation
1. **Initialization**
   - Performs Precharge All, Auto-Refresh (2×), and Load Mode Register commands.
   - Waits required delays based on CAS latency and SDRAM datasheet.

2. **Idle**
   - Waits for `read` or `write` command when `valid` is high.

3. **Read**
   - Issues ACTIVATE, READ commands, and captures data after CAS latency.
   - Handles burst termination as configured.

4. **Write**
   - Issues ACTIVATE, WRITE commands, drives data after correct delay.
   - Supports burst mode or single writes.

5. **Refresh**
   - Periodically executes auto-refresh commands when `REFRESH_COUNTER` expires.

---

## Timing Parameters
Timing constants are based on **CAS latency** and the ISSI -7 SDRAM datasheet:
- `CAS` — 2 or 3 cycles depending on `CLK_FREQ`
- `RP`, `RCD`, `RC`, `RAS` — row precharge, activation, and cycle timings
- `AUTO_REFRESH_T` — refresh interval (~1040 cycles)

---

## Example Instantiation
```verilog
sdram_interface #(
    .CLK_FREQ(133),
    .BURST_LENGTH(4),
    .BURST_TYPE("SEQ"),
    .BURST_WR_MODE(0)
) dram_ctrl (
    .clk(clk_133MHz),
    .reset(rst),
    .address(addr),
    .data_in(wr_data),
    .data_out(rd_data),
    .read(rd_en),
    .write(wr_en),
    .valid(cmd_ready),
    .ready(data_ready),
    // SDRAM pins mapping
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
