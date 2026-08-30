################################################################################
# create_project_genesys2.tcl
#
# Creates the Vivado project for CV32E40X on the Genesys-2 board.
# Vivado 2025.2.
#
# Usage, from the Vivado Tcl console:
#   source <repo_root>/fpga/genesys2/scripts/create_project_genesys2.tcl
#
################################################################################

# ------------------------------------------------------------------------
# 1. Settings
# ------------------------------------------------------------------------
set proj_name   "cv32e40x_genesys2"
set part_name   "xc7k325tffg900-2"
set top_module  "cv32e40x_wrapper_genesys2"

# Memory depth in 32-bit words. 16384 words = 64 KB.
# This must match MEM_DEPTH in memory_controller.sv and LENGTH(MEM) in link.ld.
set mem_depth   16384

# Work out where the repo is, based on where this script lives.
# [info script] is this file's path; going up three levels reaches the repo root.
set script_dir   [file dirname [file normalize [info script]]]
set repo_root    [file normalize "$script_dir/../../.."]

set core_rtl_dir "$repo_root/rtl"
set fpga_root    "$repo_root/fpga/genesys2"
set fpga_rtl_dir "$fpga_root/rtl"
set fpga_xdc_dir "$fpga_root/constraints"
set coe_file     "$fpga_root/mem_init_file/sum.coe"
set proj_dir     "$fpga_root/vivado_proj"
set wcfg_file    "$fpga_root/waveform_file/cv32e40x_wrapper_genesys2_behav.wcfg"

puts "INFO: repo_root = $repo_root"

# ------------------------------------------------------------------------
# 2. Create the project
# ------------------------------------------------------------------------
create_project $proj_name $proj_dir -part $part_name -force

set_property target_language    Verilog [current_project]
set_property simulator_language Mixed   [current_project]

# ------------------------------------------------------------------------
# 3. Clocking Wizard: 200 MHz in, 50 MHz out
#
# The IBUFDS that turns the board's LVDS clock pair into a single-ended
# signal is in the wrapper, so the wizard sees a single-ended input.
# ------------------------------------------------------------------------
create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 -module_name clk_wiz_0

set_property -dict [list \
    CONFIG.PRIM_IN_FREQ               {200.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {50.000} \
    CONFIG.RESET_TYPE                 {ACTIVE_LOW} \
    CONFIG.USE_LOCKED                 {false} \
] [get_ips clk_wiz_0]

# ------------------------------------------------------------------------
# 4. Unified memory: true dual port RAM, 16384 x 32
#
# Output registers must stay false on both ports. That keeps the BRAM read
# latency at 1 cycle, which is what memory_controller assumes when it delays
# rvalid by one cycle.
# ------------------------------------------------------------------------
create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 -module_name blk_mem_gen_0

set_property -dict [list \
    CONFIG.Memory_Type                                {True_Dual_Port_RAM} \
    CONFIG.Assume_Synchronous_Clk                     {true} \
    CONFIG.Use_Byte_Write_Enable                      {true} \
    CONFIG.Byte_Size                                  {8} \
    CONFIG.Write_Width_A                              {32} \
    CONFIG.Read_Width_A                               {32} \
    CONFIG.Write_Depth_A                              {16384} \
    CONFIG.Operating_Mode_A                           {READ_FIRST} \
    CONFIG.Enable_A                                   {Always_Enabled} \
	CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Write_Width_B                              {32} \
    CONFIG.Read_Width_B                               {32} \
    CONFIG.Operating_Mode_B                           {READ_FIRST} \
    CONFIG.Enable_B                                   {Always_Enabled} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
    CONFIG.Load_Init_File                             {true} \
    CONFIG.Coe_File                                   [file normalize $coe_file] \
] [get_ips blk_mem_gen_0]

# ------------------------------------------------------------------------
# 5. Add the CV32E40X core RTL
#
# find_hdl_files walks a directory and returns every .sv and .v file inside
# it, including subdirectories.
#
# Note: this adds everything under rtl/. The simulation-only folders
# (bhv/, sva/, tb/) are outside rtl/ in this repo, so they are not picked up.
# ------------------------------------------------------------------------
proc find_hdl_files {dir} {
    set result {}
    foreach f [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $f]} {
            lappend result {*}[find_hdl_files $f]
        } elseif {[string match "*.sv" $f] || [string match "*.v" $f]} {
            lappend result $f
        }
    }
    return $result
}

set core_rtl_files [find_hdl_files $core_rtl_dir]
puts "INFO: adding [llength $core_rtl_files] core RTL files"
add_files -norecurse -fileset sources_1 $core_rtl_files

# ------------------------------------------------------------------------
# 6. Add the Genesys-2 wrapper and memory controller
# ------------------------------------------------------------------------
set fpga_rtl_files [find_hdl_files $fpga_rtl_dir]
puts "INFO: adding [llength $fpga_rtl_files] wrapper RTL files"
add_files -norecurse -fileset sources_1 $fpga_rtl_files

# Where the core's package/header files live
set_property include_dirs "$core_rtl_dir/include" [get_filesets sources_1]
set_property include_dirs "$core_rtl_dir/include" [get_filesets sim_1]

# ------------------------------------------------------------------------
# 7. Add the constraints
# ------------------------------------------------------------------------
set xdc_files [glob -nocomplain -directory $fpga_xdc_dir "*.xdc"]
puts "INFO: adding [llength $xdc_files] constraint files"
add_files -norecurse -fileset constrs_1 $xdc_files

# ------------------------------------------------------------------------
# 8. Set the top module
#
# There is no testbench, so the wrapper is the top for both synthesis
# and simulation.
# ------------------------------------------------------------------------
set_property top $top_module [get_filesets sources_1]
set_property top $top_module [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# ------------------------------------------------------------------------
# 9. Simulation setup
#
# apply_forces.tcl drives the clock and reset. Setting it as custom_tcl
# makes Vivado run it automatically every time simulation is launched.
# ------------------------------------------------------------------------
set_property -name {xsim.simulate.custom_tcl} \
             -value [file normalize "$script_dir/apply_forces.tcl"] \
             -objects [get_filesets sim_1]

add_files -fileset sim_1 -norecurse $wcfg_file
set_property xsim.view [file normalize $wcfg_file] [get_filesets sim_1]

# ------------------------------------------------------------------------
# 10. Done
# ------------------------------------------------------------------------
puts "INFO: project created at $proj_dir"