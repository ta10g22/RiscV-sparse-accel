# ============================================================
# Synopsys Design Constraints (SDC) - DE1-SoC SpMM Accelerator
# ============================================================
# Target: 50 MHz clock
# ============================================================

# Primary Clock - 50 MHz from on-board oscillator
create_clock -name clk_50mhz -period 20.000 [get_ports clk_50mhz]

# Derive PLL clocks if any (not used in initial version)
derive_pll_clocks

# Derive clock uncertainty
derive_clock_uncertainty

# ============================================================
# Input Delays
# ============================================================
# Assume 5ns input delay for switches and buttons (conservative)
set_input_delay -clock clk_50mhz -max 5.0 [get_ports {sw[*]}]
set_input_delay -clock clk_50mhz -min 0.0 [get_ports {sw[*]}]
set_input_delay -clock clk_50mhz -max 5.0 [get_ports {key[*]}]
set_input_delay -clock clk_50mhz -min 0.0 [get_ports {key[*]}]
set_input_delay -clock clk_50mhz -max 5.0 [get_ports n_reset]
set_input_delay -clock clk_50mhz -min 0.0 [get_ports n_reset]

# UART input
set_input_delay -clock clk_50mhz -max 5.0 [get_ports uart_rx]
set_input_delay -clock clk_50mhz -min 0.0 [get_ports uart_rx]

# ============================================================
# Output Delays
# ============================================================
# Assume 5ns output delay for LEDs and displays (conservative)
set_output_delay -clock clk_50mhz -max 5.0 [get_ports {led[*]}]
set_output_delay -clock clk_50mhz -min 0.0 [get_ports {led[*]}]
set_output_delay -clock clk_50mhz -max 5.0 [get_ports {hex0[*]}]
set_output_delay -clock clk_50mhz -min 0.0 [get_ports {hex0[*]}]
set_output_delay -clock clk_50mhz -max 5.0 [get_ports {hex1[*]}]
set_output_delay -clock clk_50mhz -min 0.0 [get_ports {hex1[*]}]

# UART output
set_output_delay -clock clk_50mhz -max 5.0 [get_ports uart_tx]
set_output_delay -clock clk_50mhz -min 0.0 [get_ports uart_tx]

# ============================================================
# False Paths
# ============================================================
# Asynchronous reset (use synchronizer in RTL)
set_false_path -from [get_ports n_reset]

# Switch inputs are async (use synchronizer in RTL)  
set_false_path -from [get_ports {sw[*]}]
set_false_path -from [get_ports {key[*]}]

# LED outputs don't need strict timing
set_false_path -to [get_ports {led[*]}]
set_false_path -to [get_ports {hex0[*]}]
set_false_path -to [get_ports {hex1[*]}]

# ============================================================
# Multicycle Paths (if needed)
# ============================================================
# Memory reads may take 2 cycles - uncomment if timing fails
# set_multicycle_path -from [get_registers {*ram*}] -to [get_registers {*}] -setup -end 2
# set_multicycle_path -from [get_registers {*ram*}] -to [get_registers {*}] -hold -end 1
