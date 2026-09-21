# write reports

open_run impl_1

# Report final timing
report_timing_summary -file ${rpt_dir}/final_timing_summary.rpt

# Report utilization
report_utilization -hierarchical -hierarchical_percentages -file ${rpt_dir}/final_utilization.rpt

# Report RAM utilization
report_ram_utilization -include_lutram -file ${rpt_dir}/final_ram_utilization.rpt -csv ${rpt_dir}/final_ram_utilization.csv

# Report clock utilization
report_clock_utilization -file ${rpt_dir}/final_clock_utilization.rpt

close_design

# write bit/mcs

set firesim_bit_path ${root_dir}/vivado_proj/firesim.bit

file copy -force ${root_dir}/vivado_proj/firesim.runs/${impl_run}/${top_level_name}.bit ${firesim_bit_path}

if {$pr_enabled} {
  # Stable artifacts consumed by an RM build on any remote host.
  set abstract_shells [glob -nocomplain ${root_dir}/vivado_proj/firesim.runs/${impl_run}/abs_shell_*.dcp]
  if {[llength $abstract_shells] == 0} {
    error "DFX implementation did not emit an abstract shell checkpoint"
  }
  file copy -force [lindex $abstract_shells 0] ${root_dir}/vivado_proj/abs_shell.dcp
  for {set i 0} {$i < [llength $pr_partition_paths]} {incr i} {
    write_bitstream -force -cell [lindex $pr_partition_paths $i] \
      ${root_dir}/vivado_proj/firesim_impl_rm_${i}_partial.bit
  }
}

write_cfgmem -force -format mcs -interface SPIx4 -size 1024 -loadbit "up 0x01002000 ${firesim_bit_path}" -verbose ${root_dir}/vivado_proj/firesim.mcs
