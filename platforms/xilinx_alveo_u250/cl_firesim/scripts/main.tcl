set root_dir [pwd]
set vivado_version [version -short]
set vivado_version_major [string range $vivado_version 0 3]

set ifrequency           [lindex $argv 0]
set istrategy            [lindex $argv 1]
set iboard               [lindex $argv 2]
# main_pr.tcl passes these two optional arguments. Keeping this switch inside
# the normal project script avoids maintaining two drifting base flows.
set pr_enabled [expr {[llength $argv] >= 4}]
set pr_module_name_str [lindex $argv 3]
set pr_partition_path_str [lindex $argv 4]
set pr_module_names [split $pr_module_name_str ","]
set pr_partition_paths [expr {$pr_partition_path_str eq "" ? {} : [split $pr_partition_path_str ","]}]

proc retrieveVersionedFile { filename version } {
  set first [file rootname $filename]
  set last [file extension $filename]
  if {[file exists ${first}_${version}${last}]} {
    return ${first}_${version}${last}
  }
  return $filename
}

# get utilities
source $root_dir/scripts/utils.tcl

puts "Running with Vivado $vivado_version (Major Version: $vivado_version_major)"

check_file_exists [set sourceFile [retrieveVersionedFile ${root_dir}/scripts/platform_env.tcl $vivado_version]]
source $sourceFile

check_file_exists [set sourceFile [retrieveVersionedFile ${root_dir}/scripts/${iboard}.tcl $vivado_version]]
source $sourceFile

check_file_exists [set sourceFile [retrieveVersionedFile ${root_dir}/scripts/bd_lib/${vivado_version}/create_aurora_exdes.tcl $vivado_version]]
source $sourceFile

# Cleanup
delete_files [list ${root_dir}/vivado_proj/firesim.bit]

create_project -force firesim ${root_dir}/vivado_proj -part $part
set_property board_part $board_part [current_project]
if {$pr_enabled} { set_property PR_FLOW 1 [current_project] }

# Loading all the verilog files
foreach addFile [list \
    ${root_dir}/design/axi_tieoff_master.v \
    ${root_dir}/design/axi.vh \
    ${root_dir}/design/helpers.vh \
    ${root_dir}/design/overall_fpga_top.v \
    ${root_dir}/design/FireSim-generated.defines.vh \
    ${root_dir}/design/aurora/aurora_64b66b_0_driver.v \
    ${root_dir}/design/aurora/aurora_64b66b_0_cdc_sync_exdes.v \
    ${root_dir}/design/aurora/aurora_64b66b_0_utils.v \
] {
  set addFile [retrieveVersionedFile $addFile $vivado_version]
  check_file_exists $addFile
  add_files $addFile
  if {[file extension $addFile] == ".vh"} {
    set_property IS_GLOBAL_INCLUDE 1 [get_files $addFile]
  }
}

# DFX RMs must compile the same per-module sources used by the base. Prefer
# split Verilog when supplied by replace-rtl; retain the monolithic path for
# every existing non-DFX configuration.
set split_verilog_dir ${root_dir}/design/split-verilog
set split_files [glob -nocomplain ${split_verilog_dir}/*.sv]
if {[llength $split_files] > 0} {
  foreach split_file $split_files { add_files $split_file }
} else {
  set generated [retrieveVersionedFile ${root_dir}/design/FireSim-generated.sv $vivado_version]
  check_file_exists $generated
  add_files $generated
}

set desired_host_frequency $ifrequency
set strategy $istrategy

# Loading create_bd.tcl
check_file_exists [set sourceFile ${root_dir}/scripts/create_bd.tcl]
source $sourceFile

# Making wrapper around bd
generate_target all [get_files ${root_dir}/vivado_proj/firesim.srcs/sources_1/bd/design_1/design_1.bd]
update_compile_order -fileset sources_1

if {$pr_enabled} {
  # Establish blocksets before synthesis; each partition's hierarchy is
  # discovered post-synthesis when a path was not supplied in the recipe.
  foreach pr_module_name $pr_module_names {
    if {$pr_module_name ne ""} {
      create_fileset -blockset -define_from $pr_module_name $pr_module_name
    }
  }
}

# Mark top-level name for future steps/cmds
set top_level_name overall_fpga_top

# Report if any IPs need to be updated
report_ip_status

# Adding additional constraint sets
create_fileset -constrset synth_fileset
create_fileset -constrset impl_fileset

if {[file exists [set constrFile [retrieveVersionedFile ${root_dir}/design/FireSim-generated.synthesis.xdc $vivado_version]]]} {
    # map L2 banks to URAMs if possible (might warn if cells not present)
    add_line_to_file 1 $constrFile "set_property RAM_STYLE ULTRA \[get_cells -hierarchical -regexp {.*firesim_top.*cc_banks_.*_reg.*}\]"
    add_files -fileset synth_fileset -norecurse $constrFile
}

if {[file exists [set constrFile [retrieveVersionedFile ${root_dir}/design/FireSim-generated.implementation.xdc $vivado_version]]]} {
    # add impl clock to top of xdc
    add_line_to_file 1 $constrFile "create_generated_clock -name host_clock \[get_pins design_1_i/clk_wiz_0/inst/mmcme4_adv_inst/CLKOUT0\]"
    add_files -fileset impl_fileset -norecurse $constrFile
}


if {[file exists [set constrFile [retrieveVersionedFile ${root_dir}/design/bitstream_config.xdc $vivado_version]]]} {
    add_files -fileset impl_fileset -norecurse $constrFile
}

update_compile_order -fileset sources_1
set_property top $top_level_name [current_fileset]
update_compile_order -fileset sources_1

foreach f [get_files -of [get_filesets synth_fileset]] {
    set_property USED_IN {synthesis} $f
    set_property USED_IN_IMPLEMENTATION 0 $f
    set_property USED_IN_SYNTHESIS 1 $f
}

foreach f [get_files -of [get_filesets impl_fileset]] {
    set_property USED_IN {implementation} $f
    set_property USED_IN_IMPLEMENTATION 1 $f
    set_property USED_IN_SYNTHESIS 0 $f
    set_property PROCESSING_ORDER LATE $f
}

proc set_fileset_for_run_or_delete { fsname runname } {
    if {[llength [get_filesets -quiet $fsname]]} {
        set_property constrset $fsname [get_runs $runname]
    } else {
        delete_fileset $fsname
    }
}
set_fileset_for_run_or_delete synth_fileset synth_1
set_fileset_for_run_or_delete impl_fileset impl_1

set rpt_dir ${root_dir}/vivado_proj/reports
file mkdir ${rpt_dir}

# Set synth/impl strategy vars
check_file_exists [set sourceFile ${root_dir}/scripts/strategies/strategy_${strategy}.tcl]
source $sourceFile

# Run synth/impl and generate collateral. PR must create its partition
# definitions after synthesis and before the implementation run is launched.
foreach sourceFile [list ${root_dir}/scripts/synthesis.tcl] {
  source [retrieveVersionedFile $sourceFile $vivado_version]
}
if {$pr_enabled} {
  source ${root_dir}/scripts/post_synth_pr.tcl
} else {
  source [retrieveVersionedFile ${root_dir}/scripts/post_synth.tcl $vivado_version]
}
source [retrieveVersionedFile ${root_dir}/scripts/implementation.tcl $vivado_version]
source [retrieveVersionedFile ${root_dir}/scripts/post_impl.tcl $vivado_version]

puts "Done!"
exit 0
