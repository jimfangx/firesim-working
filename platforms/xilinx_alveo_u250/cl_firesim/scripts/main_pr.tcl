# PR-aware U250 base flow. The shared main.tcl recognizes the two additional
# arguments and performs normal FireSim synthesis/implementation plus DFX
# partition setup, so non-PR builds retain their exact existing entry point.
source [file dirname [file normalize [info script]]]/main.tcl
