# NPE Vivado Synthesis
# Target: Artix-7 XC7A35T-1CPG236C
# Run: vivado -mode batch -source synth.tcl

# Create project
create_project -force npe_synth ./npe_synth -part xc7a35t-1cpg236c

# RTL files (parser_pipeline top)
set rtl_files [list \
  [glob ../../rtl/common/npe_pkg.sv] \
  [glob ../../rtl/interfaces/axis_register.sv] \
  [glob ../../rtl/interfaces/axis_fifo.sv] \
  [glob ../../rtl/interfaces/crc32.sv] \
  [glob ../../rtl/parsers/ethernet_parser.sv] \
  [glob ../../rtl/parsers/vlan_parser.sv] \
  [glob ../../rtl/parsers/ipv4_parser.sv] \
  [glob ../../rtl/parsers/udp_parser.sv] \
  [glob ../../rtl/parsers/tcp_parser.sv] \
  [glob ../../rtl/classifiers/match_table.sv] \
  [glob ../../rtl/classifiers/packet_modifier.sv] \
  [glob ../../rtl/filters/rule_engine.sv] \
  [glob ../../rtl/filters/token_bucket.sv] \
  [glob ../../rtl/stats/stats_engine.sv] \
  [glob ../../rtl/memory/flow_table.sv] \
  [glob ../../rtl/schedulers/packet_scheduler.sv] \
  [glob ../../rtl/top/parser_pipeline.sv] \
  [glob ../../rtl/top/register_iface.sv] \
]

read_verilog -sv $rtl_files

# Synthesize the top-level parser_pipeline
synth_design -top parser_pipeline -part xc7a35t-1cpg236c -flatten_hierarchy full

# Report utilization and timing
report_utilization -hierarchical -file utilization.rpt
report_timing -max_paths 10 -file timing.rpt
report_power -file power.rpt

# Write checkpoint
write_checkpoint -force npe_synth.dcp

puts "Synthesis complete."
puts "Utilization: [get_property UTIL [get_design]]"
exit
