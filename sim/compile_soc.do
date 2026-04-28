

quit -sim


if {[file exists work]} {
    vdel -lib work -all
}
vlib work
vmap work work

puts "============================================================"
puts " Compiling SoC Integration Testbench"
puts "============================================================"


puts "Compiling common testbench files..."
vlog -sv ../tb/common/tb_pkg.sv
vlog -sv ../tb/common/clk_reset.sv


puts "Compiling PicoRV32..."
vlog -sv ../ip/picorv32/picorv32.v +define+PICORV32_REGS_INIT_ZERO


puts "Compiling RTL..."
vlog -sv ../rtl/accel_datapath.sv
vlog -sv ../rtl/accel_ctrl.sv
vlog -sv ../rtl/accel_top.sv


puts "Compiling SoC testbench..."
vlog -sv +incdir+.. ../tb/integ/soc_tb.sv

puts "============================================================"
puts " Compilation Complete"
puts "============================================================"


puts "Starting simulation..."
vsim -voptargs=+acc work.soc_tb +firmware=../sw/driver/firmware.hex


add wave -position insertpoint sim:/soc_tb/*


run -all

puts "============================================================"
puts " Simulation Complete"
puts "============================================================"
