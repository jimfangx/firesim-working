# write reports

open_run synth_1

# Discover partition paths via get_cells if they were not provided.
# The design is already open so this adds no extra open/close overhead.
if {[llength $pr_partition_paths] == 0} {
    puts "Discovering PR partition paths from synthesized design..."

    set discovered_module_names {}
    set discovered_partition_paths {}
    foreach pr_module_name $pr_module_names {
        set cells [get_cells -hierarchical -filter "REF_NAME == $pr_module_name" -quiet]
        if {[llength $cells] == 0} {
            puts "ERROR: No instances of module '$pr_module_name' found in synthesized design"
            exit 1
        }
        puts "  Found [llength $cells] instance(s) of module '$pr_module_name':"
        foreach cell $cells {
            set cell_name [get_property NAME $cell]
            lappend discovered_module_names $pr_module_name
            lappend discovered_partition_paths $cell_name
            puts "    -> $cell_name"
        }
    }
    set pr_module_names $discovered_module_names
    set pr_partition_paths $discovered_partition_paths
    puts "Total PR partitions discovered: [llength $pr_partition_paths]"

    # Write discovered paths for pr_metadata.py to read after Vivado exits
    set dpf [open ${root_dir}/vivado_proj/discovered_pr_paths.txt w]
    for {set j 0} {$j < [llength $pr_module_names]} {incr j} {
        puts $dpf "[lindex $pr_module_names $j]:[lindex $pr_partition_paths $j]"
    }
    close $dpf

    set pr_config_partitions {}
    for {set i 0} {$i < [llength $pr_module_names]} {incr i} {
        set mn [lindex $pr_module_names $i]
        set pp [lindex $pr_partition_paths $i]
        set rm [dict get $module_to_reconfig_module $mn]
        lappend pr_config_partitions "${pp}:${rm}"
        puts "Mapped partition [expr {$i + 1}] at '$pp' to reconfig module '$rm'"
    }
    create_pr_configuration -name config_1 -partitions $pr_config_partitions
    set_property PR_CONFIGURATION config_1 [get_runs impl_1]
    set_property DFX_MODE {ABSTRACT SHELL} [get_runs impl_1]
}

report_utilization -hierarchical -hierarchical_percentages -file ${rpt_dir}/post_synth_utilization.rpt
write_checkpoint ${root_dir}/vivado_proj/firesim.runs/synth_1/synth.dcp

# Define pblock regions for PR partitions. The list is used as a fallback
# when no sized Pblock XDC (from discovery run) is available. Element 0 of
# the list is the rectangle for partition 0, etc.
set pr_pblock_regions [list \
    {SLICE_X117Y424:SLICE_X144Y476 DSP48E2_X16Y170:DSP48E2_X18Y189 LAGUNA_X16Y368:LAGUNA_X19Y473 RAMB18_X8Y170:RAMB18_X9Y189 RAMB36_X8Y85:RAMB36_X9Y94 URAM288_X2Y116:URAM288_X2Y123} \
    {SLICE_X148Y392:SLICE_X174Y415 DSP48E2_X20Y158:DSP48E2_X23Y165 RAMB18_X10Y158:RAMB18_X10Y165 RAMB36_X10Y79:RAMB36_X10Y82} \
    {SLICE_X117Y392:SLICE_X144Y415 DSP48E2_X16Y158:DSP48E2_X18Y165 RAMB18_X8Y158:RAMB18_X9Y165 RAMB36_X8Y79:RAMB36_X9Y82} \
    {SLICE_X148Y453:SLICE_X175Y478 DSP48E2_X20Y182:DSP48E2_X23Y189}
]

# If a discovery run produced a sized Pblock XDC at ${root_dir}/sized_pr_pblock.xdc,
# prefer its rectangle over the hardcoded fallback. The XDC file contains a
# line "set sized_pr_pblock_region_0 {<rectangle>}" we can source.
set sized_xdc "${root_dir}/sized_pr_pblock.xdc"
if {[file exists $sized_xdc]} {
    puts "post_synth_pr: found sized Pblock XDC at $sized_xdc — using discovery-sized rectangle"
    source $sized_xdc
    if {[info exists sized_pr_pblock_region_0]} {
        puts "post_synth_pr: sized region 0 = $sized_pr_pblock_region_0"
        set pr_pblock_regions [lreplace $pr_pblock_regions 0 0 $sized_pr_pblock_region_0]
    }
}

# Get the number of PR partitions
set num_partitions [llength $pr_partition_paths]

# Validate that we have enough pblock regions
if {$num_partitions > [llength $pr_pblock_regions]} {
    puts "WARNING: Number of PR partitions ($num_partitions) exceeds number of defined pblock regions ([llength $pr_pblock_regions])"
    puts "Only creating pblocks for the first [llength $pr_pblock_regions] partitions"
    set num_partitions [llength $pr_pblock_regions]
}

# UltraScale+ DFX Pblock creation helper.
#
# Every reconfigurable-region Pblock must have SNAPPING_MODE=ON (so the
# Pblock aligns to the FPGA's reconfig-capable column boundaries — otherwise
# the partial bitstream can clobber bits outside the RP and corrupt the
# static region on partial load) and RESET_AFTER_RECONFIG=true (so the new
# RM cells come up in a known state after a partial load instead of picking
# up whatever register values the previous RM left behind).
#
# Both properties are easy to forget when adding a new Pblock creation path,
# and the failure mode is silent at build time but catastrophic at runtime
# (PCIe/xdma drops, DDR4 PHY resets, sim hangs). This helper makes the
# invariants non-skippable: create + resize + cells + both HD.* properties
# in a single call. All Pblock creation in DFX flows should go through this.
proc create_reconfigurable_pblock {name region partition_path} {
    puts "create_reconfigurable_pblock: $name at '$partition_path'"
    # Idempotent: if a pblock with this name already exists (e.g. from a
    # prior bitstream_config.xdc that baked the pblock + cells + region) we
    # drop and recreate cleanly. Avoids "Pblock already exists" errors when
    # rebuilding a CL dir whose XDC carries leftover pblock definitions from
    # an earlier successful build.
    if {[llength [get_pblocks -quiet $name]]} {
        puts "  (existing pblock '$name' found from constraints — deleting and recreating)"
        delete_pblocks $name
    }
    create_pblock $name
    resize_pblock $name -add $region
    add_cells_to_pblock $name [get_cells [list $partition_path]] -clear_locs
    set_property SNAPPING_MODE ON         [get_pblocks $name]
    set_property RESET_AFTER_RECONFIG true [get_pblocks $name]
    puts "  assigned region: $region"
    puts "  SNAPPING_MODE=ON, RESET_AFTER_RECONFIG=true"
}

# Create pblocks for each PR partition.
for {set i 0} {$i < $num_partitions} {incr i} {
    create_reconfigurable_pblock \
        "pblock_pr_region_${i}" \
        [lindex $pr_pblock_regions $i] \
        [lindex $pr_partition_paths $i]
}

set_property target_constrs_file ${root_dir}/design/bitstream_config.xdc [current_fileset -constrset]
save_constraints -force

close_design
