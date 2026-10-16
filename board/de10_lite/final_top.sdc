# Timing constraints for final_top on the DE10-Lite.

create_clock -name clk_50mhz -period 20.000 [get_ports {clk_50mhz}]
derive_pll_clocks
derive_clock_uncertainty

# asynchronous / human-speed pins
set_false_path -from [get_ports {reset_n sdram_start rx}]
set_false_path -to   [get_ports {status_leds[*] tx}]

# The SDRAM I/O is not constrained yet. DRAM_CLK is the PLL output sent
# straight to the pin, and the read capture point (RD_CAPTURE_DELAY = 1) was
# found on hardware. For a constrained design, drive DRAM_CLK from a second
# PLL output with a negative phase shift, declare it with
# create_generated_clock and add set_input_delay/set_output_delay for the
# DRAM_* pins from the IS42S16320D tAC/tOH/tIS/tIH values.
