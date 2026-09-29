# XB-10 FireSim and prefetcher DFX

The normal XB-10 shell in this directory targets the Corigine XB-10's
`xcvu19p-fsvb3824-2-e`. It uses the board's pin XDC, XDMA PCIe interface,
and one 8 GiB DDR4 channel. The platform recipe is
`deploy/bit-builder-recipes/corigine_xb10.yaml`; a normal Rocket example is
`sims/firesim-staging/sample_config_build_recipes.yaml` in the parent Chipyard
checkout.

DFX uses the same board shell and FireSim driver. The base build marks each
`ReconfigurablePrefetcher` instance as a reconfigurable partition and produces
`firesim.bit`, `firesim.xpr`, `abs_shell.dcp`, and `pr_metadata.json`. An RM build
uses the matching base's abstract shell and packages a partial bitstream. The
RM build runs `pr_verify` against that shell before it writes the partial.
The runtime checks the base bitstream SHA-256 before programming the partial.

The example recipes are named `xb10_rocket_dfx_base`,
`xb10_rocket_dfx_rm_ampm`, `xb10_megaboom_dfx_base`, and
`xb10_megaboom_dfx_rm_ampm` in
`sims/firesim-staging/sample_config_build_recipes_dfx.yaml`. Build a base
first, then its corresponding RM. Set `builds_to_run` to one recipe at a time.
The RM's `pr_base_recipe` must resolve to a completed base build with the same
FPGA part, FireSim platform, static hierarchy, and wrapper ports.

## VU19P floorplan

The U250 Pblock coordinates do not apply to the VU19P. For one RP, the XB-10
script derives an initial Pblock from the CLB, DSP, BRAM, and URAM sites in
`SLR3` of the selected VU19P device. Set `FIRESIM_XB10_PR_SLR` to a different
SLR name if the base design requires it. This initial region is intentionally
large; inspect its resource balance, hard IP proximity, routing, and timing in
Vivado before using the resulting partial bitstream on a board.

For a reviewed floorplan, create
`platforms/corigine_xb10/cl_firesim/scripts/pr_pblock_regions.tcl`. The file
must set one site-range list per partition, in the same order as the discovered
partition paths. For example:

```tcl
set pr_pblock_regions [list \
    {SLICE_X...Y...:SLICE_X...Y... DSP48E2_X...Y...:DSP48E2_X...Y... RAMB18_X...Y...:RAMB18_X...Y... RAMB36_X...Y...:RAMB36_X...Y...}]
```

Only use coordinates obtained from the VU19P Device view. For multiple RPs,
this file is required and its regions must not overlap. The Pblock helper
sets `SNAPPING_MODE ON` and `RESET_AFTER_RECONFIG true` for each RP.

## Artifacts and runtime

A normal or DFX base build generates a full `firesim.tar.gz` and a driver
bundle. An RM build generates `firesim_partial.tar.gz` and an HWDB entry that
points to the matching base full bitstream and driver. Use that generated HWDB
entry for `firesim infrasetup` and `firesim runworkload`. FireSim programs the
full image, checks the compatibility digest, overlays the partial, and resets
the simulation.

Any change to board pins, PCIe/DDR IP, clocking, static RTL, wrapper ports, or
Pblock geometry requires a new base and new RMs. VU19P partial bitstreams
cannot be used with a U250 base.

## Runtime commands on an XB-10 host

Run `firesim managerinit --platform corigine_xb10` once to select the XB-10
deploy manager in `config_runtime.yaml`. Add either generated HWDB entry to
`config_hwdb.yaml`, select it as `target_config.default_hw_config`, and set
the externally provisioned run-farm host and FPGA count in `config_runtime.yaml`.

The normal command sequence is:

```text
firesim enumeratefpgas
firesim infrasetup
firesim runworkload
```

`enumeratefpgas` creates the BDF-to-JTAG-target database. `infrasetup` stages
the driver and artifacts, programs the full base image, and overlays the
partial image when the selected HWDB entry contains `partial_bitstream_tar`.
`runworkload` then starts the regular FireSim simulation command path.

The deploy manager discovers `vivado_lab` and `hw_server` from
`FIRESIM_VIVADO_BIN`/`FIRESIM_HW_SERVER_BIN`, the Xilinx installation
environment, or `PATH`. Source the Vivado Lab settings script before running
FireSim, or set the two FireSim variables to the executable paths.
