################################################################################
# create_project_mic_test.tcl
#
# Creates the Vivado project for the TDM microphone test on the SCU35
# Evaluation Board: mic_tdm_top drives the SB-POLARIS board through J2 on
# PMOD0, and tdm_ila records the samples. Vivado 2025.2.
#
# Usage, from the Vivado Tcl console:
#   source <repo_root>/mic_test/scripts/create_project_mic_test.tcl
#
# The project is created in mic_test/vivado (deleted and recreated if it
# already exists). Everything it needs comes from the repo: rtl/, sim/ and
# constraints/. The ILA core is generated here from its settings.
################################################################################

# ------------------------------------------------------------------------
# 1. Settings
# ------------------------------------------------------------------------
set proj_name   "mic_test"
set part_name   "xcsu35p-sbvb625-2-e"
set board_part  "xilinx.com:scu35:part0:1.0"
set top_module  "mic_tdm_top"
set sim_top     "tb_tdm_master_rx"

# Work out where things are, based on where this script lives.
# [info script] is this file's path; one level up is mic_test/.
set script_dir  [file dirname [file normalize [info script]]]
set mic_root    [file normalize "$script_dir/.."]

set rtl_dir     "$mic_root/rtl"
set sim_dir     "$mic_root/sim"
set xdc_dir     "$mic_root/constraints"
set proj_dir    "$mic_root/vivado"

puts "INFO: mic_root = $mic_root"

# ------------------------------------------------------------------------
# 2. Check the path length
#
# Inserting the ILA's debug hub (dbg_hub) fails on Windows when the
# implementation temp folder, <proj>/<name>.runs/impl_1/.Xil/Vivado-<pid>-<host>,
# is longer than 146 characters. Warn before building, not after.
# If it is too long, map part of the path to a drive letter, for example:
#   subst H: "D:\Documents\SideTasks\20260225_Health_Monitoring_System\HMS_Git"
# and source this script again from H:.
# ------------------------------------------------------------------------
set tmp_path "$proj_dir/$proj_name.runs/impl_1/.Xil/Vivado-99999-[info hostname]"
set tmp_len  [string length $tmp_path]
if {$tmp_len > 146} {
    puts "WARNING: implementation temp path is about $tmp_len characters (limit 146)."
    puts "WARNING: the ILA debug hub will fail to build. Use a shorter path or subst."
} else {
    puts "INFO: implementation temp path is about $tmp_len characters (limit 146)"
}

# ------------------------------------------------------------------------
# 3. Create the project
# ------------------------------------------------------------------------
create_project $proj_name $proj_dir -part $part_name -force

# Use the board definition if the SCU35 board files are installed.
# The project works without it; only the board view in Vivado needs it.
if {[llength [get_board_parts -quiet $board_part]] > 0} {
    set_property board_part $board_part [current_project]
}

set_property target_language    Verilog [current_project]
set_property simulator_language Mixed   [current_project]

# ------------------------------------------------------------------------
# 4. ILA: 7 probes, 8192 samples deep, capture control on
#
# Capture control (C_EN_STRG_QUAL) lets the ILA store only the clock cycles
# where sample_valid = 1, so 8192 entries hold 8192 samples (335 ms of one
# mic, or 1024 per mic) instead of 82 us of clock cycles. It needs at least
# 2 comparators per probe.
#
#   probe0  sample[23:0]   decoded audio value
#   probe1  slot[2:0]      which mic, 0 to 7
#   probe2  sample_valid   1 when a new sample is ready
#   probe3  frame_start    1 at the start of each TDM frame
#   probe4  BCLK           bit clock sent to the mics
#   probe5  WS             frame sync sent to the mics
#   probe6  DATA           raw bit from the mics
# ------------------------------------------------------------------------
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name tdm_ila

set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES       {7}    \
    CONFIG.C_DATA_DEPTH          {8192} \
    CONFIG.C_EN_STRG_QUAL        {1}    \
    CONFIG.ALL_PROBE_SAME_MU_CNT {2}    \
    CONFIG.C_PROBE0_WIDTH        {24}   \
    CONFIG.C_PROBE1_WIDTH        {3}    \
    CONFIG.C_PROBE2_WIDTH        {1}    \
    CONFIG.C_PROBE3_WIDTH        {1}    \
    CONFIG.C_PROBE4_WIDTH        {1}    \
    CONFIG.C_PROBE5_WIDTH        {1}    \
    CONFIG.C_PROBE6_WIDTH        {1}    \
] [get_ips tdm_ila]

generate_target all [get_ips tdm_ila]

# ------------------------------------------------------------------------
# 5. Add the RTL (mic_tdm_top, tdm_master_rx)
# ------------------------------------------------------------------------
set rtl_files [glob -nocomplain -directory $rtl_dir "*.sv" "*.v"]
puts "INFO: adding [llength $rtl_files] RTL files"
add_files -norecurse -fileset sources_1 $rtl_files

# ------------------------------------------------------------------------
# 6. Add the simulation files (testbench and SBM100B mic model)
# ------------------------------------------------------------------------
set sim_files [glob -nocomplain -directory $sim_dir "*.sv" "*.v"]
puts "INFO: adding [llength $sim_files] simulation files"
add_files -norecurse -fileset sim_1 $sim_files

# ------------------------------------------------------------------------
# 7. Add the constraints
#
# The pattern matches .xdc and .XDC (the board file uses capitals).
# ------------------------------------------------------------------------
set xdc_files [glob -nocomplain -directory $xdc_dir {*.[xX][dD][cC]}]
puts "INFO: adding [llength $xdc_files] constraint files"
add_files -norecurse -fileset constrs_1 $xdc_files

# ------------------------------------------------------------------------
# 8. Set the top modules
#
# Synthesis builds mic_tdm_top. Simulation runs the testbench, which tests
# tdm_master_rx against eight mic models.
# ------------------------------------------------------------------------
set_property top $top_module [get_filesets sources_1]
set_property top $sim_top    [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# ------------------------------------------------------------------------
# 9. Simulation setup
#
# The testbench ends itself with $finish after about 3 ms of simulated time
# and prints TEST PASSED, so run until it stops instead of the default 1 us.
# ------------------------------------------------------------------------
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

# ------------------------------------------------------------------------
# 10. Done
# ------------------------------------------------------------------------
puts "INFO: project created at $proj_dir"
