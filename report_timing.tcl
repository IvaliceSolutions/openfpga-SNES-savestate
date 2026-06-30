# Run with: quartus_sta -t report_timing.tcl   (after a compile)
# Emits the worst-case setup paths with full register source/dest detail.
project_open projects/snes_pocket.qpf
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_timing -setup -npaths 15 -detail full_path -file projects/output_files/worst_paths.rpt
project_close
