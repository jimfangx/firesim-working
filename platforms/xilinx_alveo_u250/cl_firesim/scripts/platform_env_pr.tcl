if {[info exists ::env(VIVADO_JOBS)] && $::env(VIVADO_JOBS) ne ""} {
    set jobs $::env(VIVADO_JOBS)
} else {
    set jobs 8
}
