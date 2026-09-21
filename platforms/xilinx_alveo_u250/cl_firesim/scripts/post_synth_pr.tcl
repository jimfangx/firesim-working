# Called with synth_1 open by main.tcl. Discover/validate RP cells, mark them
# reconfigurable, constrain snapped Pblocks, and bind the initial RMs.
open_run synth_1
if {[llength $pr_partition_paths] == 0} {
  set discovered {}
  foreach module $pr_module_names {
    set cells [get_cells -hierarchical -filter "REF_NAME == $module" -quiet]
    if {[llength $cells] == 0} { error "DFX module '$module' was not found" }
    foreach cell $cells { lappend discovered [get_property NAME $cell] }
  }
  set pr_partition_paths $discovered
}
if {[llength $pr_partition_paths] != [llength $pr_module_names]} {
  error "DFX module/path count mismatch; provide an explicit path for each module"
}
set partition_specs {}
for {set i 0} {$i < [llength $pr_partition_paths]} {incr i} {
  set path [lindex $pr_partition_paths $i]
  set module [lindex $pr_module_names $i]
  set cell [get_cells $path -quiet]
  if {[llength $cell] != 1} { error "DFX partition cell '$path' was not found" }
  set_property HD.RECONFIGURABLE true $cell
  set pblock pblock_pr_region_${i}
  create_pblock $pblock
  # Conservative U250 fallback region; a family-specific base can replace it
  # through normal XDC before the base is built.
  resize_pblock $pblock -add {SLICE_X117Y424:SLICE_X144Y476 DSP48E2_X16Y170:DSP48E2_X18Y189 RAMB18_X8Y170:RAMB18_X9Y189 RAMB36_X8Y85:RAMB36_X9Y94}
  add_cells_to_pblock $pblock $cell -clear_locs
  set_property SNAPPING_MODE ON [get_pblocks $pblock]
  set_property RESET_AFTER_RECONFIG true [get_pblocks $pblock]
  set rm ${module}_rm_${i}
  set partition_def pr_partition_${module}
  if {[llength [get_partition_defs -quiet $partition_def]] == 0} {
    create_partition_def -name $partition_def -module $module
  }
  create_reconfig_module -name $rm -partition_def [get_partition_defs $partition_def] -define_from $module
  lappend partition_specs "${path}:${rm}"
}
create_pr_configuration -name config_1 -partitions $partition_specs
set_property PR_CONFIGURATION config_1 [get_runs impl_1]
set_property DFX_MODE {ABSTRACT SHELL} [get_runs impl_1]
set out [open ${root_dir}/vivado_proj/pr_partitions.txt w]
for {set i 0} {$i < [llength $pr_partition_paths]} {incr i} {
  puts $out "[lindex $pr_module_names $i]:[lindex $pr_partition_paths $i]"
}
close $out
report_utilization -hierarchical -file ${rpt_dir}/post_synth_utilization.rpt
close_design
