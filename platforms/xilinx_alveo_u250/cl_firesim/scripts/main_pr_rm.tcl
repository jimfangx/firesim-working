# Compatibility entry point for recipes selecting pr_mode: project. The DCP
# abstract-shell implementation is the maintained RM backend and accepts the
# same positional arguments; retaining this filename avoids a divergent API.
source [file dirname [file normalize [info script]]]/main_pr_rm_nonproject.tcl
