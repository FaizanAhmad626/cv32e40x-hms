################################################################################
# apply_forces.tcl
#
# Forces the top-level clock and reset ports for behavioral simulation, since
# there is no testbench -- the wrapper module itself is the simulation DUT.
#
# Loaded automatically via XSIM.SIMULATE.CUSTOM_TCL (set on the sim_1
# fileset in create_project_genesys2.tcl), so this runs every time
# simulation is launched from the GUI, with no manual `source` step needed.
#
# EDIT the two port names below to match your actual top-level ports on
# cv32e40x_wrapper_genesys2 before running.
################################################################################

set top_module "cv32e40x_wrapper_genesys2"

set clk_p_port "clk_p_i"
set clk_n_port "clk_n_i"
set rst_port   "rst_ni"

set clk_p_path "/${top_module}/${clk_p_port}"
set clk_n_path "/${top_module}/${clk_n_port}"
set rst_path   "/${top_module}/${rst_port}"

# 200 MHz differential input clock: 5 ns period, 2.5 ns half-period.
# clk_n_i is the complement of clk_p_i, so it's forced with inverted timing.
add_force $clk_p_path {0 0ns} {1 2.5ns} -repeat_every 5ns
add_force $clk_n_path {1 0ns} {0 2.5ns} -repeat_every 5ns

# Active-low reset: 0 (asserted) for the first 100 ns, then 1 (released).
add_force $rst_path {0 0ns} {1 100ns}

puts "INFO: forced $clk_p_path/$clk_n_path (200 MHz differential) and $rst_path (releases at 100 ns)"

run 1000ns
