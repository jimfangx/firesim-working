#!/bin/bash

# This script is called by FireSim's bitbuilder to create a bit file

# exit script if any command fails
set -e
set -o pipefail

usage() {
    echo "usage: ${0} [OPTIONS]"
    echo ""
    echo "Options"
    echo "   --cl_dir    : Custom logic directory to build Vivado bitstream from"
    echo "   --frequency : Frequency in MHz of the desired FPGA host clock."
    echo "   --strategy  : A string to a precanned set of build directives.
                          See aws-fpga documentation for more info/.
                          For this platform TIMING and AREA supported."
    echo "   --board     : FPGA board {au200,au250,au280}."
    echo "   --enable_pr : enable U250 Vivado DFX mode (true/false)."
    echo "   --pr_module_name / --pr_partition_path : comma-separated RP definition."
    echo "   --pr_project_path : base XPR; selects the RM implementation flow."
    echo "   --pr_mode   : nonproject (default) or project."
    echo "   --help      : Display this message"
    exit "$1"
}

CL_DIR=""
FREQUENCY=""
STRATEGY=""
BOARD=""
ENABLE_PR=false
PR_MODULE_NAME=""
PR_PARTITION_PATH=""
PR_PROJECT_PATH=""
PR_MODE=nonproject

# getopts does not support long options, and is inflexible
while [ "$1" != "" ];
do
    case $1 in
        --help)
            usage 1 ;;
        --cl_dir )
            shift
            CL_DIR=$1 ;;
        --strategy )
            shift
            STRATEGY=$1 ;;
        --frequency )
            shift
            FREQUENCY=$1 ;;
        --board )
            shift
            BOARD=$1 ;;
        --enable_pr )
            shift
            ENABLE_PR=$1 ;;
        --pr_module_name )
            shift
            PR_MODULE_NAME=$1 ;;
        --pr_partition_path )
            shift
            PR_PARTITION_PATH=$1 ;;
        --pr_project_path )
            shift
            PR_PROJECT_PATH=$1 ;;
        --pr_mode )
            shift
            PR_MODE=$1 ;;
        * )
            echo "invalid option $1"
            usage 1 ;;
    esac
    shift
done

if [ -z "$CL_DIR" ] ; then
    echo "no cl directory specified"
    usage 1
fi

if [ -z "$FREQUENCY" ] ; then
    echo "No --frequency specified"
    usage 1
fi

if [ -z "$STRATEGY" ] ; then
    echo "No --strategy specified"
    usage 1
fi

if [ -z "$BOARD" ] ; then
    echo "No --board specified"
    usage 1
fi

cd "$CL_DIR"
if [ "$ENABLE_PR" != true ]; then
    vivado -mode batch -source "$CL_DIR/scripts/main.tcl" -tclargs "$FREQUENCY" "$STRATEGY" "$BOARD"
    exit 0
fi

if [ -z "$PR_MODULE_NAME" ]; then
    echo "--pr_module_name is required for a DFX build" >&2
    exit 1
fi

if [ -n "$PR_PROJECT_PATH" ]; then
    if [ -z "$PR_PARTITION_PATH" ]; then
        echo "DFX RM requires partition paths from base metadata" >&2
        exit 1
    fi
    python3 "$CL_DIR/scripts/pr_metadata.py" validate \
        --root_dir "$CL_DIR" \
        --project_path "$PR_PROJECT_PATH" \
        --pr_module_names "$PR_MODULE_NAME" \
        --pr_partition_paths "$PR_PARTITION_PATH" \
        --frequency "$FREQUENCY" || echo "WARNING: DFX base source validation reported differences"
    case "$PR_MODE" in
      nonproject) script=main_pr_rm_nonproject.tcl ;;
      project) script=main_pr_rm.tcl ;;
      *) echo "invalid --pr_mode $PR_MODE" >&2; exit 1 ;;
    esac
    vivado -mode batch -source "$CL_DIR/scripts/$script" -tclargs "$FREQUENCY" "$STRATEGY" "$BOARD" "$PR_MODULE_NAME" "$PR_PARTITION_PATH" "$PR_PROJECT_PATH"
else
    vivado -mode batch -source "$CL_DIR/scripts/main_pr.tcl" -tclargs "$FREQUENCY" "$STRATEGY" "$BOARD" "$PR_MODULE_NAME" "$PR_PARTITION_PATH"
    VIVADO_INFO_FILE="$CL_DIR/vivado_proj/vivado_build_info.txt"
    DISCOVERED_PATHS_FILE="$CL_DIR/vivado_proj/discovered_pr_paths.txt"
    VIVADO_VERSION=""
    PART=""
    BOARD_PART_VAL=""
    ACTUAL_FREQ=""
    if [ -f "$VIVADO_INFO_FILE" ]; then
        VIVADO_VERSION=$(sed -n 's/^vivado_version=//p' "$VIVADO_INFO_FILE")
        PART=$(sed -n 's/^part=//p' "$VIVADO_INFO_FILE")
        BOARD_PART_VAL=$(sed -n 's/^board_part=//p' "$VIVADO_INFO_FILE")
        ACTUAL_FREQ=$(sed -n 's/^actual_frequency_mhz=//p' "$VIVADO_INFO_FILE")
    fi
    metadata_cmd=(python3 "$CL_DIR/scripts/pr_metadata.py" generate
        --root_dir "$CL_DIR"
        --frequency "${ACTUAL_FREQ:-$FREQUENCY}"
        --strategy "$STRATEGY"
        --pr_module_names "$PR_MODULE_NAME"
        --vivado_version "$VIVADO_VERSION"
        --part "$PART"
        --board_part "$BOARD_PART_VAL")
    if [ -n "$PR_PARTITION_PATH" ]; then
        metadata_cmd+=(--pr_partition_paths "$PR_PARTITION_PATH")
    fi
    if [ -f "$DISCOVERED_PATHS_FILE" ]; then
        metadata_cmd+=(--discovered_paths_file "$DISCOVERED_PATHS_FILE")
    fi
    "${metadata_cmd[@]}"
fi
