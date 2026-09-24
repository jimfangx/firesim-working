#!/usr/bin/env python3
"""Split FireSim's generated SystemVerilog into one source file per module.

Vivado DFX needs the reconfigurable module in its own source file when it
creates a block fileset. This script consumes the monolithic Golden Gate
output; ordinary (non-DFX) FPGA builds continue to use that original file.
"""

import argparse
import re
from pathlib import Path


MODULE = re.compile(r"^\s*module\s+([A-Za-z_][A-Za-z_0-9]*)\b")
ENDMODULE = re.compile(r"^\s*endmodule\b")


def split_verilog(source: Path, output_dir: Path) -> int:
    output_dir.mkdir(parents=True, exist_ok=True)
    outside = []
    body = []
    modules = {}
    name = None

    for line in source.read_text().splitlines(keepends=True):
        declaration = MODULE.match(line)
        if declaration:
            if name is not None:
                raise ValueError(f"nested module declaration inside {name}")
            name = declaration.group(1)
            if name in modules:
                raise ValueError(f"duplicate module {name}")
            body = outside + [line]
            outside = []
        elif ENDMODULE.match(line):
            if name is None:
                raise ValueError("endmodule without a module declaration")
            body.append(line)
            modules[name] = body
            name = None
            body = []
        elif name is None:
            outside.append(line)
        else:
            body.append(line)

    if name is not None:
        raise ValueError(f"unterminated module {name}")
    if not modules:
        raise ValueError(f"no modules found in {source}")

    # Keep directives after the final module (for example an `endif guarding
    # a black-box definition) with that module's source file.
    modules[next(reversed(modules))].extend(outside)
    for module_name, lines in modules.items():
        (output_dir / f"{module_name}.sv").write_text("".join(lines))
    (output_dir / "modules.f").write_text(
        "".join(f"{module_name}.sv\n" for module_name in sorted(modules))
    )
    return len(modules)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("-o", "--output-dir", required=True, type=Path)
    args = parser.parse_args()
    print(f"Split {split_verilog(args.source, args.output_dir)} modules into {args.output_dir}")


if __name__ == "__main__":
    main()
