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

# XB-10 Pblocks must be derived from XCVU19P sites. A single partition uses
# the CLB/DSP/BRAM/URAM resources in one SLR by default. This is deliberately
# conservative and keeps the RM away from an SLR crossing. For a tighter
# floorplan, or for multiple partitions, put pr_pblock_regions.tcl in this
# scripts directory. It must set pr_pblock_regions to a list of site ranges.
set pr_pblock_regions {}
set region_file "${root_dir}/scripts/pr_pblock_regions.tcl"
if {[file exists $region_file]} {
    source $region_file
} else {
    set pr_slr SLR3
    if {[info exists ::env(FIRESIM_XB10_PR_SLR)]} {
        set pr_slr $::env(FIRESIM_XB10_PR_SLR)
    }
    set slr_object [get_slrs -quiet $pr_slr]
    if {[llength $slr_object] != 1} {
        error "XB-10 DFX: expected one SLR named $pr_slr"
    }
    set slr_sites [get_sites -quiet -of_objects $slr_object]
    if {[llength $slr_sites] == 0} {
        error "XB-10 DFX: no sites found in $pr_slr"
    }
    array set bounds {}
    foreach site $slr_sites {
        set site_name [get_property NAME $site]
        if {![regexp {^(SLICE|DSP48E2|RAMB18|RAMB36|URAM288)_X([0-9]+)Y([0-9]+)$} $site_name -> prefix x y]} {
            continue
        }
        if {![info exists bounds($prefix)]} {
            set bounds($prefix) [list $x $y $x $y]
        } else {
            lassign $bounds($prefix) min_x min_y max_x max_y
            set bounds($prefix) [list \
                [expr {min($min_x, $x)}] [expr {min($min_y, $y)}] \
                [expr {max($max_x, $x)}] [expr {max($max_y, $y)}]]
        }
    }
    if {![info exists bounds(SLICE)]} {
        error "XB-10 DFX: no SLICE sites found in $pr_slr"
    }
    set region {}
    foreach prefix {SLICE DSP48E2 RAMB18 RAMB36 URAM288} {
        if {[info exists bounds($prefix)]} {
            lassign $bounds($prefix) min_x min_y max_x max_y
            lappend region "${prefix}_X${min_x}Y${min_y}:${prefix}_X${max_x}Y${max_y}"
        }
    }
    lappend pr_pblock_regions $region
    puts "XB-10 DFX: generated initial Pblock in $pr_slr: $region"
}

# A discovery pass may provide a smaller, independently reviewed region.
set sized_xdc "${root_dir}/sized_pr_pblock.xdc"
if {[file exists $sized_xdc]} {
    source $sized_xdc
    if {[info exists sized_pr_pblock_region_0]} {
        set pr_pblock_regions [lreplace $pr_pblock_regions 0 0 $sized_pr_pblock_region_0]
    }
}

# Get the number of PR partitions
set num_partitions [llength $pr_partition_paths]

# Every partition needs its own nonoverlapping VU19P region.
if {$num_partitions != [llength $pr_pblock_regions]} {
    error "XB-10 DFX: $num_partitions partitions require $num_partitions Pblock regions; got [llength $pr_pblock_regions]. Supply scripts/pr_pblock_regions.tcl."
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
