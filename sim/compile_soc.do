# ============================================================
# ModelSim Compile Script for SoC Integration Testbench
# ============================================================
# Usage: vsim -c -do "do compile_soc.do"
# ============================================================

# saves me so much headache lol 

# Quit any previous simulation
quit -sim

# Create work library
if {[file exists work]} {
    vdel -lib work -all
}
vlib work
vmap work work

puts "============================================================"
puts " Compiling SoC Integration Testbench"
puts "============================================================"

# Compile order matters! Dependencies first.

# 1. Common testbench packages and interfaces
puts "Compiling common testbench files..."
vlog -sv ../tb/common/tb_pkg.sv
vlog -sv ../tb/common/clk_reset.sv

# 2. PicoRV32 CPU
puts "Compiling PicoRV32..."
vlog -sv ../ip/picorv32/picorv32.v +define+PICORV32_REGS_INIT_ZERO

# 3. RTL modules (order: datapath, ctrl, top)
puts "Compiling RTL..."
vlog -sv ../rtl/accel_datapath.sv
vlog -sv ../rtl/accel_ctrl.sv
vlog -sv ../rtl/accel_top.sv

# 4. SoC testbench
puts "Compiling SoC testbench..."
vlog -sv +incdir+.. ../tb/integ/soc_tb.sv

puts "============================================================"
puts " Compilation Complete"
puts "============================================================"

# Run simulation
puts "Starting simulation..."
vsim -voptargs=+acc work.soc_tb

# Add waves
add wave -position insertpoint sim:/soc_tb/*

# Run the test
run -all

puts "============================================================"
puts " Simulation Complete"
puts "============================================================"
