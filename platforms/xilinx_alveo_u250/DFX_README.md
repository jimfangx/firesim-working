# U250 Dynamic Function eXchange (DFX)

DFX keeps FireSim's platform, bridges, core, memory system, PCIe, and driver
in a static region and changes one explicitly wrapped Chisel module as a
reconfigurable module (RM). It is opt-in and does not affect normal U250,
other FPGA, or AWS F2 recipes.

Start with the examples in `deploy/sample-backup-configs/`:

```bash
cp sample-backup-configs/sample_config_build_recipes_dfx.yaml config_build_recipes.yaml
# Select rocket_dfx_base in config_build.yaml, then:
firesim buildbitstream
# Select rocket_dfx_rm_ampm and run buildbitstream again.
```

The base produces `firesim.bit`, `firesim.xpr`, `abs_shell.dcp`, and
`pr_metadata.json`. An RM recipe names that exact base through
`pr_base_recipe`; the manager resolves the artifact locally, verifies its
manifest, and rsyncs an immutable copy to the remote build host. This is the
supported build-host/run-host split: never point a run configuration at a
different full bitstream than the RM's base.

An RM HWDB entry contains all three artifacts:

```yaml
rocket_dfx_ampm:
  bitstream_tar: file:///shared/results/<base>/firesim.tar.gz
  driver_tar: file:///shared/results/<base>/driver-bundle.tar.gz
  partial_bitstream_tar: file:///shared/results/<rm>/firesim_partial.tar.gz
  deploy_quintuplet_override: null
  custom_runtime_config: null
```

`firesim infrasetup` verifies the full-bit SHA-256 against the partial tar,
programs the full bit, overlays the partial, and injects a long reset pulse.
If the hashes differ it aborts before programming.

## New module families

Write a wrapper extending the family’s abstract module plus
`firechip.dfx.DfxReconfigurableWrapper`, set a stable `wrapperName`, give it
a fixed IO contract, and instantiate exactly one inner `Module` without
conditionals. Then add a CDE config adapter that replaces the ordinary factory
with that wrapper, add a DFX target config, and make a new base. The Vivado,
manager, artifact, and runtime portions need no family-specific change.

Changing the wrapper hierarchy/name, its ports, static logic, FPGA part,
clock, Pblock, or driver ABI requires a new base. Only logic wholly below the
existing wrapper is eligible for an RM-only build.
