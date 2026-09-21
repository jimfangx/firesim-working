#!/usr/bin/env python3
"""Write the portable base-artifact manifest used by DFX RM builders."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--project-dir", required=True)
parser.add_argument("--frequency", required=True, type=float)
parser.add_argument("--modules", required=True)
args = parser.parse_args()
project_dir = Path(args.project_dir)
paths = {}
for line in (project_dir / "pr_partitions.txt").read_text().splitlines():
    module, path = line.split(":", 1)
    paths.setdefault(module, []).append(path)
payload = {
    "schema_version": 1,
    "frequency_mhz": args.frequency,
    "pr_modules": [{"module_name": module, "partition_paths": module_paths} for module, module_paths in paths.items()],
    "artifacts": {"project": "firesim.xpr", "abstract_shell": "abs_shell.dcp", "full_bit": "firesim.bit"},
}
(project_dir / "pr_metadata.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
