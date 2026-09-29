variable synth_run [get_runs synth_1]

reset_runs ${synth_run}

set_property -dict [ list \
    STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE ${synth_directive} \
    {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} "${synth_options}" \
] ${synth_run}

# Optional Vivado incremental synthesis seed. When FIRESIM_INCREMENTAL_SYNTH_REF
# points at a prior synth_1's checkpoint (overall_fpga_top.dcp under
# vivado_proj/firesim.runs/synth_1/), Vivado will reuse synth output for
# unchanged modules — UG901 ch. 4 reports up to 50-80% synth-time savings on
# small RTL diffs. Different mechanism from the impl-side INCREMENTAL_CHECKPOINT
# wired in implementation.tcl (which only affects place/route).
if {[info exists ::env(FIRESIM_INCREMENTAL_SYNTH_REF)] && $::env(FIRESIM_INCREMENTAL_SYNTH_REF) ne ""} {
    set synth_ref $::env(FIRESIM_INCREMENTAL_SYNTH_REF)
    if {[file exists $synth_ref]} {
        puts "synthesis: INCREMENTAL_CHECKPOINT (synth_1) -> $synth_ref"
        set_property INCREMENTAL_CHECKPOINT $synth_ref ${synth_run}
    } else {
        puts "synthesis: WARNING — FIRESIM_INCREMENTAL_SYNTH_REF=$synth_ref not found; ignoring"
    }
}

launch_runs ${synth_run} -jobs ${jobs}
wait_on_run ${synth_run}

check_progress ${synth_run} "synthesis failed"
