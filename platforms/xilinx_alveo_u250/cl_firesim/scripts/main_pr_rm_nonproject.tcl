# =============================================================================
# main_pr_rm_nonproject.tcl
#
# DFX RM iteration via Vivado's non-project (DCP) flow. Replaces the
# project-mode main_pr_rm.tcl for the per-RM-variant inner loop. Same input
# args, same output partial bit at vivado_proj/firesim_<run>_partial.bit.
#
# Pattern (UG947 abstract-shell DFX, "abs_impl_*.tcl" examples):
#
#   create_project -in_memory -part $part        ;# OOC RM synth
#   read_verilog -sv [glob ./design/split-verilog/*.sv]
#   read_xdc <ooc_clock.xdc>
#   synth_design -mode out_of_context -top <pr_module_name>
#   write_checkpoint -force <rm_synth.dcp>
#   close_project
#
#   add_files <abs_shell.dcp>                    ;# Link RM into shell
#   add_files <rm_synth.dcp>
#   set_property SCOPED_TO_CELLS {<pr_partition_path>} \
#       [get_files <rm_synth.dcp>]
#   link_design -mode default \
#       -reconfig_partitions {<pr_partition_path>} \
#       -part $part -top <top>
#
#   opt_design -directive $opt_dir
#   place_design -directive $pl_dir              ;# Only places RM cells —
#   route_design -directive $rt_dir              ;#   shell is locked.
#
#   write_bitstream -force -cell <pr_partition_path> <partial.bit>
#
# Why non-project?
#   Project-mode main_pr_rm.tcl spends ~6 min on MegaBoom in "RM setup"
#   (open_project, create_reconfig_module, fileset bookkeeping, create_run,
#   open_run synth_1) before any actual work. The flow above does the
#   equivalent in ~20 s of link_design — no project files, no run state.
#
#   Expected per-iteration savings: ~30-40% of total wall.
#
# Args (positional, same shape as main_pr_rm.tcl):
#   ifrequency               (MHz, e.g. 30)
#   istrategy                (TIMING / AREA / SPEED — only used to pick OOC
#                             synth options; impl directives default to
#                             "Default", overridable by FIRESIM_PR_RM_FAST=1)
#   iboard                   (au250 — selects the part)
#   pr_module_name_str       (comma-separated; for our flow, almost always one
#                             entry e.g. "ReconfigurablePrefetcher")
#   pr_partition_path_str    (comma-separated full hierarchy paths)
#   pr_project_path          (path to firesim.xpr — only used to derive the
#                             vivado_proj root; not opened in non-project mode)
#   pr_partition_module_name_str (optional; defaults to pr_module_name_str)
#
# Inputs expected on disk:
#   ${root_dir}/vivado_proj/abs_shell.dcp        (deposited by main_pr.tcl)
#   ${root_dir}/design/split-verilog/*.sv        (RM source)
#
# Outputs:
#   ${root_dir}/vivado_proj/firesim_<run>_partial.bit
#   ${root_dir}/vivado_proj/firesim_<run>_routed.dcp     (shell+RM, for next iter incremental seed)
#   ${root_dir}/vivado_proj/firesim_<run>_rm.dcp         (RM-cell-only DCP)
# =============================================================================

set root_dir [pwd]
set vivado_version [version -short]
set vivado_version_major [string range $vivado_version 0 3]

set ifrequency           [lindex $argv 0]
set istrategy            [lindex $argv 1]
set iboard               [lindex $argv 2]
set pr_module_name_str   [lindex $argv 3]
set pr_partition_path_str [lindex $argv 4]
set pr_project_path       [lindex $argv 5]
set pr_partition_module_name_str [lindex $argv 6]

# ---- arg parse / validate ---------------------------------------------------
set pr_module_names {}
foreach n [split $pr_module_name_str ","] { lappend pr_module_names [string trim $n] }

set pr_partition_paths {}
foreach p [split $pr_partition_path_str ","] { lappend pr_partition_paths [string trim $p] }

if {[llength $pr_module_names] != [llength $pr_partition_paths]} {
    puts "ERROR: pr_module_names ([llength $pr_module_names]) != pr_partition_paths ([llength $pr_partition_paths])"
    exit 1
}

# Derive vivado_proj/ root from --pr_project_path. We don't open the .xpr.
if {$pr_project_path eq "" || ![file isdirectory [file dirname $pr_project_path]]} {
    puts "ERROR: --pr_project_path must point at <cl_dir>/vivado_proj/firesim.xpr (or any file in vivado_proj/)"
    exit 1
}
set vivado_proj_dir [file dirname $pr_project_path]

set abs_shell_dcp "${vivado_proj_dir}/abs_shell.dcp"
if {![file exists $abs_shell_dcp]} {
    puts "ERROR: abstract shell DCP not found at $abs_shell_dcp"
    puts "       Run a base PR build (main_pr.tcl) first; it surfaces the DCP."
    exit 1
}

set sv_dir "${root_dir}/design/split-verilog"
if {![file isdirectory $sv_dir]} {
    puts "ERROR: split-verilog dir missing: $sv_dir"
    exit 1
}

# Source PR-only helpers + board file (sets $part, $board_part).
set project_scripts_dir [file dirname [file normalize [info script]]]
source ${project_scripts_dir}/utils_pr.tcl
source ${project_scripts_dir}/platform_env_pr.tcl
set board_tcl ${project_scripts_dir}/${iboard}.tcl
if {![file exists $board_tcl]} {
    puts "ERROR: board file not found: $board_tcl"
    exit 1
}
source $board_tcl
puts "Part: $part  Board part: $board_part"

# Strategy file just sets synth_directive, synth_options for OOC synth.
set strategy_file ${project_scripts_dir}/strategies/strategy_${istrategy}_pr.tcl
if {[file exists $strategy_file]} {
    source $strategy_file
} else {
    puts "WARNING: no strategy file at $strategy_file; using defaults"
    set synth_directive   "Default"
    set synth_options     ""
}

# Implementation directives. Same FIRESIM_PR_RM_FAST=1 knob as project mode.
set rm_fast [expr {[info exists ::env(FIRESIM_PR_RM_FAST)] && $::env(FIRESIM_PR_RM_FAST) ne "0"}]
if {$rm_fast} {
    set opt_dir   "RuntimeOptimized"
    set place_dir "Quick"
    set route_dir "Quick"
    puts "FIRESIM_PR_RM_FAST=1 -> Quick directives on opt/place/route"
} else {
    set opt_dir   "Default"
    set place_dir "Default"
    set route_dir "Default"
}

set top_level_name overall_fpga_top

# ---- timing helpers ---------------------------------------------------------
set script_start_time [clock seconds]
set timing_log {}
proc format_time { seconds } {
    set h [expr {int($seconds / 3600)}]; set m [expr {int(($seconds % 3600) / 60)}]; set s [expr {int($seconds % 60)}]
    if {$h > 0} { return [format "%dh %dm %ds" $h $m $s] }
    if {$m > 0} { return [format "%dm %ds" $m $s] }
    return [format "%ds" $s]
}
proc log_timing { phase start } {
    global timing_log
    set now [clock seconds]; set dt [expr {$now - $start}]
    lappend timing_log [list $phase $dt]
    puts "TIMING: $phase took [format_time $dt]"
    return $now
}

set phase_start [clock seconds]

# =============================================================================
# Per-RM iteration. Most flows have one RM but the data flow is per-list-entry.
# =============================================================================
file mkdir ${vivado_proj_dir}
set produced_partials {}
set produced_full_bits {}

for {set i 0} {$i < [llength $pr_module_names]} {incr i} {
    set pr_module_name    [lindex $pr_module_names $i]
    set pr_partition_path [lindex $pr_partition_paths $i]
    set run_name          "impl_rm_${i}"

    puts "=================================================="
    puts "RM ${i}: $pr_module_name -> $pr_partition_path"
    puts "=================================================="

    # ------------------------------------------------------------------------
    # Step 1: OOC synthesize the RM in a fresh in-memory project.
    # ------------------------------------------------------------------------
    set ooc_phase_start [clock seconds]

    create_project -in_memory -part $part
    set_property board_part $board_part [current_project]

    set sv_files [glob -nocomplain "${sv_dir}/*.sv"]
    if {[llength $sv_files] == 0} {
        puts "ERROR: no .sv files in $sv_dir"
        exit 1
    }
    read_verilog -sv $sv_files

    # OOC clock constraint: same period as the host clock target.
    set ooc_xdc "${vivado_proj_dir}/rm_xdc/${run_name}_ooc.xdc"
    file mkdir [file dirname $ooc_xdc]
    set fh [open $ooc_xdc w]
    set ooc_period [expr {1000.0 / $ifrequency}]
    puts $fh "create_clock -name user_clock -period $ooc_period \[get_ports clock\]"
    close $fh
    read_xdc $ooc_xdc
    set_property USED_IN {out_of_context} [get_files $ooc_xdc]

    # OOC synth.
    if {[catch {
        synth_design -mode out_of_context -top $pr_module_name -part $part
    } err]} {
        puts "ERROR: OOC synthesis failed for $pr_module_name: $err"
        exit 1
    }

    set rm_synth_dcp "${vivado_proj_dir}/firesim_${run_name}_synth.dcp"
    write_checkpoint -force $rm_synth_dcp
    close_project

    set phase_start [log_timing "RM ${i} OOC synthesis" $ooc_phase_start]

    # ------------------------------------------------------------------------
    # Step 2: Link the RM synth.dcp into the abstract shell + opt/place/route.
    # The abstract shell has all static-region cells locked (HD.* properties
    # and locked routes), so place_design / route_design only touch the
    # cells inside the Pblock.
    # ------------------------------------------------------------------------
    set link_phase_start [clock seconds]

    add_files $abs_shell_dcp
    add_files $rm_synth_dcp
    set_property SCOPED_TO_CELLS [list $pr_partition_path] \
        [get_files $rm_synth_dcp]

    link_design -mode default \
        -reconfig_partitions [list $pr_partition_path] \
        -part $part -top $top_level_name

    set phase_start [log_timing "RM ${i} link_design" $link_phase_start]

    set impl_phase_start [clock seconds]
    opt_design -directive $opt_dir
    place_design -directive $place_dir
    route_design -directive $route_dir
    set phase_start [log_timing "RM ${i} opt+place+route" $impl_phase_start]

    # Optional: report final timing on the host_clock.
    set wns [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
    puts "  RM ${i} post-route WNS: $wns ns"

    # ------------------------------------------------------------------------
    # Step 3: Save shell+RM routed DCP and per-cell RM DCP. Useful for next-
    # iteration incremental, debugging, and matches the project-mode outputs.
    # ------------------------------------------------------------------------
    set shell_routed_dcp "${vivado_proj_dir}/firesim_${run_name}_routed.dcp"
    set rm_cell_dcp      "${vivado_proj_dir}/firesim_${run_name}_rm.dcp"
    write_checkpoint -force $shell_routed_dcp
    write_checkpoint -force -cell $pr_partition_path $rm_cell_dcp

    # ------------------------------------------------------------------------
    # Step 4: Emit the partial bitstream for this cell only.
    # ------------------------------------------------------------------------
    set bit_phase_start [clock seconds]
    set partial_bit "${vivado_proj_dir}/firesim_${run_name}_partial.bit"

    # Disable bitstream compression on partials (tiny RM, compression saves
    # ~nothing and adds latency on partial-load via JTAG/PCAP). Don't touch
    # CONFIG_MODE — U250's board files set BITSTREAM.CONFIG.SPI_BUSWIDTH=4
    # for boot-flash purposes and the tutorial's "S_SELECTMAP32" override
    # collides with that. Partial reconfig over PCIe XDMA goes via PCAP/ICAP
    # and doesn't depend on CONFIG_MODE anyway.
    set_property bitstream.general.compress false [current_design]

    write_bitstream -force -cell $pr_partition_path $partial_bit
    set phase_start [log_timing "RM ${i} write_bitstream" $bit_phase_start]
    puts "  Partial bit: $partial_bit  ([expr {[file size $partial_bit] / 1024}] KB)"

    # ------------------------------------------------------------------------
    # Step 4b (optional): also emit a full bitstream (static + this RM
    # combined). Useful when the runtime can't reliably partial-reconfig in
    # place — e.g. when the partition needs an explicit reset post-swap that
    # the static doesn't yet drive. The full bit's flash takes ~90s vs ~35s
    # for partial, but full-flash triggers GSR and brings the design up
    # cleanly. Triggered by FIRESIM_PR_RM_EMIT_FULL=1.
    #
    # Non-project (abstract-shell) flow CAN'T emit a full bit directly: the
    # abstract shell DCP omits static frame data (LUT INITs, BRAM contents,
    # etc.), so write_bitstream without -cell fails with
    #     [Common 17-69] The current design is an abstract shell design.
    #     Bitstream generation is supported only for a partial bit file
    #     of a reconfigurable cell.
    # We work around this by closing the abstract shell, re-opening the
    # original full base routed DCP, swapping in the just-routed RM via
    # read_checkpoint -cell, then write_bitstream (no -cell).
    if {[info exists ::env(FIRESIM_PR_RM_EMIT_FULL)] && $::env(FIRESIM_PR_RM_EMIT_FULL) ne "0"} {
        set full_phase_start [clock seconds]
        set full_bit "${vivado_proj_dir}/firesim_${run_name}_full.bit"

        # Find the original base's full routed DCP. main_pr.tcl deposits it
        # at <root_dir>/incremental_ref.dcp on a successful base PR build.
        # Fall back to globbing firesim.runs/idr_impl_1*/* and impl_1/*.
        set full_base_dcp ""
        if {[file exists "${root_dir}/incremental_ref.dcp"]} {
            set full_base_dcp "${root_dir}/incremental_ref.dcp"
        } else {
            set globs [glob -nocomplain \
                "${vivado_proj_dir}/firesim.runs/idr_impl_1*/idr_postroute.dcp" \
                "${vivado_proj_dir}/firesim.runs/idr_impl_1*/*_routed.dcp" \
                "${vivado_proj_dir}/firesim.runs/impl_1/*_routed.dcp"]
            if {[llength $globs] > 0} {
                set full_base_dcp [lindex $globs 0]
            }
        }
        if {$full_base_dcp eq ""} {
            puts "WARNING: FIRESIM_PR_RM_EMIT_FULL=1 but no full base routed DCP"
            puts "         found. Skipping full-bit emit. Looked for"
            puts "         <root_dir>/incremental_ref.dcp and"
            puts "         vivado_proj/firesim.runs/idr_impl_1*/*.dcp"
            puts "         Run a base PR build via main_pr.tcl first."
        } else {
            puts "  Reopening full base DCP for full-bit emit: $full_base_dcp"
            close_design
            open_checkpoint $full_base_dcp
            # Black-box the RP cell, then read in the new RM's routed DCP.
            update_design -cells $pr_partition_path -black_box
            lock_design -level routing
            read_checkpoint -cell $pr_partition_path $rm_cell_dcp
            # Re-enable compression on the full bit — saves O(MB) without
            # measurable load-time hit.
            set_property bitstream.general.compress true [current_design]
            write_bitstream -force $full_bit
            set phase_start [log_timing "RM ${i} write_bitstream (full)" $full_phase_start]
            puts "  Full bit:    $full_bit  ([expr {[file size $full_bit] / 1024 / 1024}] MB)"
            lappend produced_full_bits $full_bit
        }
    }

    close_design
    lappend produced_partials $partial_bit
}

# ---- summary ---------------------------------------------------------------
set total_time [expr {[clock seconds] - $script_start_time}]
puts "=========================================="
puts "BUILD TIMING SUMMARY (PR RM NON-PROJECT MODE)"
puts "=========================================="
foreach e $timing_log {
    puts [format "  %-35s %s" [lindex $e 0] [format_time [lindex $e 1]]]
}
puts "=========================================="
puts [format "  %-35s %s" "TOTAL BUILD TIME" [format_time $total_time]]
puts "=========================================="
puts "Partial bitstreams emitted:"
foreach p $produced_partials {
    puts "  $p"
}
if {[llength $produced_full_bits] > 0} {
    puts "Full bitstreams emitted (FIRESIM_PR_RM_EMIT_FULL=1):"
    foreach f $produced_full_bits {
        puts "  $f"
    }
}
puts "Done!"
