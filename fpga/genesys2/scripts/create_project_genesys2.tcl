################################################################################
# create_project_genesys2.tcl
#
# Creates a Vivado project for the CV32E40X core targeting the Genesys-2
# board (Kintex-7 XC7K325T-2FFG900C), pulling sources from the cloned
# openhwgroup/cv32e40x repo plus the Genesys-2-specific wrapper/constraints.
#
# Usage (from Vivado Tcl console, or `vivado -mode batch -source`):
#   cd <repo_root>/fpga/genesys2/scripts
#   source create_project_genesys2.tcl
#
# Assumes this script lives at: <repo_root>/fpga/genesys2/scripts/
################################################################################

# ------------------------------------------------------------------------
# 1. Project settings — edit these if your layout or top module differs
# ------------------------------------------------------------------------
set proj_name       "cv32e40x_genesys2"
set proj_dir        "../vivado_proj"
set part_name       "xc7k325tffg900-2"
set top_module      "cv32e40x_wrapper_genesys2"

# Resolve repo root relative to this script's location, so the script works
# no matter where the repo is cloned to (D:\..., C:\Dev\..., etc.)
set script_dir      [file dirname [file normalize [info script]]]
set repo_root       [file normalize "$script_dir/../../.."]
set core_rtl_dir    "$repo_root/rtl"
set fpga_rtl_dir    "$repo_root/fpga/genesys2/rtl"
set fpga_xdc_dir    "$repo_root/fpga/genesys2/constraints"
set mem_init_dir    "$repo_root/fpga/genesys2/mem_init_file"
set wcfg_file       "$repo_root/fpga/genesys2/waveform_file/cv32e40x_wrapper_genesys2_behav.wcfg"

puts "INFO: repo_root      = $repo_root"
puts "INFO: core_rtl_dir   = $core_rtl_dir"
puts "INFO: fpga_rtl_dir   = $fpga_rtl_dir"
puts "INFO: fpga_xdc_dir   = $fpga_xdc_dir"
puts "INFO: mem_init_dir   = $mem_init_dir"

# ------------------------------------------------------------------------
# 2. Create the project
# ------------------------------------------------------------------------
create_project $proj_name $proj_dir -part $part_name -force

set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

# ------------------------------------------------------------------------
# 3. Generate required IPs: Clocking Wizard + 2x Block Memory Generator
#
#    NOTE: Clocking Wizard's internal MMCM parameters (CLKFBOUT_MULT_F,
#    CLKOUT0_DIVIDE_F, DIVCLK_DIVIDE, etc.) are computed automatically by
#    Vivado's Tcl parameter-propagation model from the input/output
#    frequencies below -- you do not set them directly. Property names
#    below match Vivado 2018.2's clk_wiz 6.0 and blk_mem_gen 8.4 CONFIG
#    schema; if any property is rejected on your install, open the IP
#    in the GUI once (Tools > Report > Report IP Status, or just
#    double-click it in Sources) to confirm the exact name, since a few
#    property names have shifted across point releases.
# ------------------------------------------------------------------------

# --- 3a. Clocking Wizard: 200 MHz single-ended in -> 50 MHz MMCM out ---
create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 \
    -module_name clk_wiz_0

set_property -dict [list \
    CONFIG.PRIM_IN_FREQ                  {200.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ    {50.000} \
    CONFIG.RESET_TYPE                    {ACTIVE_LOW} \
    CONFIG.USE_LOCKED                    {false} \
] [get_ips clk_wiz_0]

generate_target {instantiation_template} [get_files clk_wiz_0.xci]

# --- 3b. Block Memory Generator #0: Single Port ROM, 32x4096, sum.coe ---
create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 \
    -module_name blk_mem_gen_0

set sum_coe_file "$mem_init_dir/sum.coe"
if {![file exists $sum_coe_file]} {
    puts "WARNING: $sum_coe_file not found -- blk_mem_gen_0 will be created"
    puts "         without Load_Init_File. Fix the path and re-run, or"
    puts "         set the Coe File manually in the IP customization GUI."
}

set_property -dict [list \
    CONFIG.Memory_Type          {Single_Port_ROM} \
    CONFIG.Write_Width_A        {32} \
    CONFIG.Write_Depth_A        {4096} \
    CONFIG.Enable_A             {Always_Enabled} \
	CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
] [get_ips blk_mem_gen_0]

if {[file exists $sum_coe_file]} {
    set_property -dict [list \
        CONFIG.Load_Init_File {true} \
        CONFIG.Coe_File       [file normalize $sum_coe_file] \
    ] [get_ips blk_mem_gen_0]
}

generate_target {instantiation_template} [get_files blk_mem_gen_0.xci]

# --- 3c. Block Memory Generator #1: Single Port RAM, 32x4096, byte-write ---
create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 \
    -module_name blk_mem_gen_1

set_property -dict [list \
    CONFIG.Use_Byte_Write_Enable {true} \
    CONFIG.Byte_Size            {8} \
    CONFIG.Write_Width_A        {32} \
    CONFIG.Write_Depth_A        {4096} \
    CONFIG.Read_Width_A         {32} \
    CONFIG.Operating_Mode_A     {READ_FIRST} \
    CONFIG.Enable_A             {Always_Enabled} \
	CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
] [get_ips blk_mem_gen_1]

generate_target {instantiation_template} [get_files blk_mem_gen_1.xci]

puts "INFO: generated IPs: clk_wiz_0, blk_mem_gen_0 (ROM+sum.coe), blk_mem_gen_1 (RAM)"

# ------------------------------------------------------------------------
# 4. Add CV32E40X core RTL (recursively, .sv and .v only)
#    bhv/, sva/, tb/, and constraints/ are intentionally NOT added here:
#    bhv = simulation-only behavioral models, sva = assertion binds not
#    needed for synthesis, tb = testbench, constraints/ = OpenHW's example
#    ASIC-flow SDC which does not belong in the Vivado constraint set.
# ------------------------------------------------------------------------
if {![file isdirectory $core_rtl_dir]} {
    error "ERROR: core RTL directory not found at $core_rtl_dir -- check repo_root path."
}

set core_rtl_files [glob -nocomplain -directory $core_rtl_dir -type f \
    "*.sv" "*.v" \
    [file join "**" "*.sv"] [file join "**" "*.v"]]

# glob's ** pattern needs -tails/-directory handling on some Tcl versions;
# use a directory walk as a robust fallback so this works regardless of
# platform Tcl quirks.
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

if {[llength $core_rtl_files] == 0} {
    error "ERROR: no .sv/.v files found under $core_rtl_dir -- did the clone/submodule populate correctly?"
}

puts "INFO: adding [llength $core_rtl_files] core RTL file(s) from rtl/"
add_files -norecurse -fileset sources_1 $core_rtl_files

# ------------------------------------------------------------------------
# 5. Add your Genesys-2 wrapper/adapter RTL
# ------------------------------------------------------------------------
if {![file isdirectory $fpga_rtl_dir]} {
    puts "WARNING: $fpga_rtl_dir does not exist yet -- skipping wrapper RTL."
    puts "         Create it and add cv32e40x_wrapper_genesys2.sv there, then re-run."
} else {
    set fpga_rtl_files [find_hdl_files $fpga_rtl_dir]
    if {[llength $fpga_rtl_files] > 0} {
        puts "INFO: adding [llength $fpga_rtl_files] Genesys-2 wrapper file(s) from fpga/genesys2/rtl/"
        add_files -norecurse -fileset sources_1 $fpga_rtl_files
    } else {
        puts "WARNING: fpga/genesys2/rtl/ exists but contains no .sv/.v files."
    }
}

# Add include directory for CV32E40X packages (needed if any file uses
# `include instead of package import)
set incl_dirs [list "$core_rtl_dir/include"]
foreach d $incl_dirs {
    if {[file isdirectory $d]} {
        set_property include_dirs $d [get_filesets sources_1]
    }
}

# ------------------------------------------------------------------------
# 6. Add Genesys-2 XDC constraints
# ------------------------------------------------------------------------
if {![file isdirectory $fpga_xdc_dir]} {
    puts "WARNING: $fpga_xdc_dir does not exist yet -- skipping constraints."
    puts "         Create genesys2.xdc there, then re-run or add it manually."
} else {
    set xdc_files [glob -nocomplain -directory $fpga_xdc_dir "*.xdc"]
    if {[llength $xdc_files] > 0} {
        puts "INFO: adding [llength $xdc_files] constraint file(s) from fpga/genesys2/constraints/"
        add_files -norecurse -fileset constrs_1 $xdc_files
    } else {
        puts "WARNING: fpga/genesys2/constraints/ exists but contains no .xdc files."
    }
}

# ------------------------------------------------------------------------
# 7. Set top module and fix compile order
# ------------------------------------------------------------------------
if {[llength [get_files -quiet "*${top_module}.sv"]] > 0 || \
    [llength [get_files -quiet "*${top_module}.v"]]  > 0} {
    set_property top $top_module [current_fileset]
} else {
    puts "WARNING: could not find a source file matching top module '$top_module'."
    puts "         Set it manually once the wrapper file is in place:"
    puts "         set_property top $top_module \[current_fileset\]"
}

update_compile_order -fileset sources_1

# ------------------------------------------------------------------------
# 9. Wire up automatic clock/reset forcing for simulation
#    Since there is no testbench, the wrapper itself is the sim DUT.
#    XSIM.SIMULATE.CUSTOM_TCL runs the given script automatically every
#    time simulation is launched (GUI or launch_simulation), so no manual
#    `source` step is needed after clicking Run Simulation.
# ------------------------------------------------------------------------
set force_script "$script_dir/apply_forces.tcl"

set_property top $top_module [get_filesets sim_1]

if {[file exists $force_script]} {
    set_property -name {xsim.simulate.custom_tcl} \
        -value [file normalize $force_script] \
        -objects [get_filesets sim_1]
    puts "INFO: sim_1 will auto-run $force_script on every simulation launch"
} else {
    puts "WARNING: $force_script not found -- clock/reset will not be forced automatically."
    puts "         Place apply_forces.tcl next to this script, or force manually via the Tcl console."
}

if {[file exists $wcfg_file]} {
    add_files -fileset sim_1 -norecurse $wcfg_file
    set_property xsim.view [file normalize $wcfg_file] [get_filesets sim_1]
    puts "INFO: sim_1 will auto-open $wcfg_file on every simulation launch"
} else {
    puts "WARNING: $wcfg_file not found -- waveform layout will not auto-load."
    puts "         Save one from Vivado (File > Save Waveform Configuration) at that path, then re-run."
}

# ------------------------------------------------------------------------
# 10. Save
# ------------------------------------------------------------------------
puts "INFO: project '$proj_name' created at $proj_dir"
puts "INFO: open it later with: start_gui  (if in batch mode)"
puts "INFO: or open $proj_dir/$proj_name.xpr directly in the Vivado GUI"