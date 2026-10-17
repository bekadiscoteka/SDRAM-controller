#!/usr/bin/env python3
"""Mutation test: checks that the testbench catches known controller bugs.

Each mutant applies one source edit to a copy of the RTL and runs the
controller testbench. A mutant "survives" when the testbench still passes,
which means the bench has a blind spot. Exit status is 1 if any survive.
"""
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORK = ROOT / "build" / "mutants"
CTRL = "sdram_interface.v"
FIFO = "synch_fifo.v"
WM1 = ["-Ptb_sdram_interface.BURST_WR_MODE=1"]
F143 = ["-Ptb_sdram_interface.CLK_FREQ=143"]

# (name, file, original text, mutated text, extra iverilog args)
MUTANTS = [
    ("precharge the new command's bank", CTRL,
     "DRAM_BA			<= open_bank;", "DRAM_BA			<= h_bank;", []),
    ("PRE cuts a read burst", CTRL,
     "RD_TO_PRE	= BURST_LENGTH - 1,", "RD_TO_PRE	= 0,", []),
    ("tRAS ignored", CTRL, "ACT_TO_PRE	= T_RAS - 1,", "ACT_TO_PRE	= 0,", []),
    ("tRC ignored", CTRL, "ACT_TO_ACT	= T_RC - 1,", "ACT_TO_ACT	= 0,", []),
    ("tRCD ignored", CTRL, "ACT_TO_RW	= T_RCD - 1,", "ACT_TO_RW	= 0,", []),
    ("tDPL ignored", CTRL, "WR_TO_PRE	= BLW - 1 + T_DPL,", "WR_TO_PRE	= BLW - 1,", []),
    ("no read->write turnaround", CTRL,
     "RD_TO_WR	= CAS + BURST_LENGTH + 1,", "RD_TO_WR	= 0,", []),
    ("143 MHz with tRP of 133 MHz", CTRL, "T_RP	= FAST ? 3 : 2,", "T_RP	= 2,", F143),
    ("143 MHz with CL2", CTRL, "CAS		= FAST ? 3 : 2,", "CAS		= 2,", F143),
    ("refresh interval too long", CTRL,
     "REF_INTERVAL	= (CLK_FREQ * 78) / 10 - 16;", "REF_INTERVAL	= (CLK_FREQ * 80) / 10;", []),
    ("short power-up wait", CTRL,
     "POWERUP_CYCLES	= CLK_FREQ * POWERUP_US + 16,", "POWERUP_CYCLES	= 4,", []),
    ("only 2 init refreshes", CTRL, "if (init_refs == 7)", "if (init_refs == 1)", []),
    ("reserved mode register bit set", CTRL, "{3'b000,", "{3'b001,", []),
    ("read captured a cycle early", CTRL,
     "valid	<= rd_sr[CAS + RD_CAPTURE_DELAY];", "valid	<= rd_sr[CAS + RD_CAPTURE_DELAY - 1];", []),
    ("row compare ignores row", CTRL,
     "wire row_hit = h_ok && h_bank == open_bank && h_row == open_row;",
     "wire row_hit = h_ok && h_bank == open_bank;", []),
    ("unmatched burst slot not masked (low byte)", CTRL,
     "DRAM_LDQM	<= 1;		// nothing", "DRAM_LDQM	<= 0;		// nothing", WM1),
    ("merged write not popped", CTRL,
     "pop = do_read || do_write || wr_merge;", "pop = do_read || do_write;", WM1),
    ("burst order ignores wrap", CTRL,
     "burst_col = (base & ~mask) | ((base + {6'b0, k}) & mask);", "burst_col = base + {6'b0, k};", WM1),
    ("merge ignores row/bank", CTRL,
     "wr_left != 0 && row_hit && h_we", "wr_left != 0 && h_ok && h_we", WM1),
    ("fifo never full", FIFO, "assign full		= (w_ptr + 1'b1) == r_ptr;", "assign full		= 0;", []),
    ("fifo skips entries", FIFO, "r_ptr <= r_ptr + 1'b1;", "r_ptr <= r_ptr + 2'd2;", []),
    ("commands accepted during init", CTRL,
     ".w_en		( (write ^ read) && ready		),", ".w_en		( write ^ read					),", []),
]


def run(name, fname, old, new, extra):
    d = WORK / "m"
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    for f in (CTRL, FIFO):
        shutil.copy(ROOT / "rtl" / f, d / f)
    src = (d / fname).read_text()
    if old not in src:
        return "PATTERN NOT FOUND"
    (d / fname).write_text(src.replace(old, new, 1))
    vvp = d / "tb.vvp"
    subprocess.run(["iverilog", "-g2012", "-o", str(vvp), "-s", "tb_sdram_interface", *extra,
                    str(d / FIFO), str(d / CTRL),
                    str(ROOT / "sim" / "sdram_model.v"), str(ROOT / "sim" / "tb_sdram_interface.v")],
                   check=True, capture_output=True)
    out = subprocess.run(["vvp", "-n", str(vvp), "+ops=8000"], capture_output=True, text=True).stdout
    return "SURVIVED" if "\nPASS" in "\n" + out else "killed"


def main():
    survivors = 0
    for m in MUTANTS:
        result = run(*m)
        print(f"{result:18s} {m[0]}")
        if result != "killed":
            survivors += 1
    print(f"{len(MUTANTS) - survivors}/{len(MUTANTS)} mutants killed")
    return 1 if survivors else 0


if __name__ == "__main__":
    sys.exit(main())
