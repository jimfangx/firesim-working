# Fast RM implementation against the immutable abstract shell emitted by a
# DFX base build. Arguments match build-bitstream.sh.
set root_dir [pwd]
set ifrequency [lindex $argv 0]
set iboard [lindex $argv 2]
set module_names [split [lindex $argv 3] ","]
set partition_paths [split [lindex $argv 4] ","]
set project_path [lindex $argv 5]
if {[llength $module_names] != [llength $partition_paths]} { error "DFX RM module/path count mismatch" }
set scripts [file dirname [file normalize [info script]]]
source ${scripts}/platform_env.tcl
source ${scripts}/${iboard}.tcl
set project_dir [file dirname $project_path]
set shell ${project_dir}/abs_shell.dcp
if {![file exists $shell]} { error "DFX base abstract shell missing: $shell" }

for {set i 0} {$i < [llength $module_names]} {incr i} {
  set module [lindex $module_names $i]
  set path [lindex $partition_paths $i]
  create_project -in_memory -part $part
  set split [glob -nocomplain ${root_dir}/design/split-verilog/*.sv]
  if {[llength $split] > 0} {
    read_verilog -sv $split
  } else {
    read_verilog -sv ${root_dir}/design/FireSim-generated.sv
  }
  set xdc ${project_dir}/rm_${i}.xdc
  set fh [open $xdc w]
  puts $fh "create_clock -name user_clock -period [expr {1000.0 / $ifrequency}] \[get_ports clock\]"
  close $fh
  read_xdc $xdc
  synth_design -mode out_of_context -top $module -part $part
  set rm_dcp ${project_dir}/firesim_impl_rm_${i}_synth.dcp
  write_checkpoint -force $rm_dcp
  close_project

  create_project -in_memory -part $part
  add_files $shell
  add_files $rm_dcp
  set_property SCOPED_TO_CELLS [list $path] [get_files $rm_dcp]
  link_design -mode default -reconfig_partitions [list $path] -part $part -top overall_fpga_top
  opt_design
  place_design
  route_design
  write_checkpoint -force ${project_dir}/firesim_impl_rm_${i}_routed.dcp
  write_bitstream -force -cell $path ${root_dir}/vivado_proj/firesim_impl_rm_${i}_partial.bit
  close_project
}
