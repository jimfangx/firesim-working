# Vivado "Quick everywhere" strategy: RuntimeOptimized synth + Quick place + Quick route.
# Maximum compile-speed; expect lower QoR (achieved freq) than SPEED/TIMING.

set synth_options ""
set synth_directive "RuntimeOptimized"

set opt 1
set opt_options    ""
set opt_directive  "Default"

set place_options   ""
set place_directive "Quick"

set phys_opt 0
set phys_options    ""
set phys_directive  "Default"

set route_options   ""
set route_directive "Quick"

set route_phys_opt 0
set post_phys_options    ""
set post_phys_directive  "Default"
