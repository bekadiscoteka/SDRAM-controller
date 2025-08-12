
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
