from __future__ import with_statement, annotations

import abc
import yaml
import json
import time
import random
import string
import logging
import os
from fabric.api import prefix, local, run, env, lcd, parallel, settings  # type: ignore
from fabric.contrib.console import confirm  # type: ignore
from fabric.contrib.project import rsync_project  # type: ignore

from util.streamlogger import InfoStreamLogger
from util.export import create_export_string
from awstools.afitools import firesim_tags_to_description, copy_afi_to_all_regions
from awstools.awstools import (
    send_firesim_notification,
    get_aws_userid,
    get_aws_region,
    auto_create_bucket,
    valid_aws_configure_creds,
    aws_resource_names,
    get_snsname_arn,
)

# imports needed for python type checking
from typing import Optional, Dict, Any, TYPE_CHECKING

if TYPE_CHECKING:
    from buildtools.buildconfig import BuildConfig

rootLogger = logging.getLogger()


def get_deploy_dir() -> str:
    """Determine where the firesim/deploy directory is and return its path.

    Returns:
        Path to firesim/deploy directory.
    """
    deploydir = local("pwd", capture=True)
    return deploydir


class BitBuilder(metaclass=abc.ABCMeta):
    """Abstract class to manage how to build a bitstream for a build config.

    Attributes:
        build_config: Build config to build a bitstream for.
        args: Args (i.e. options) passed to the bitbuilder.
    """

    build_config: BuildConfig
    args: Dict[str, Any]

    def __init__(self, build_config: BuildConfig, args: Dict[str, Any]) -> None:
        """
        Args:
            build_config: Build config to build a bitstream for.
            args: Args (i.e. options) passed to the bitbuilder.
        """
        self.build_config = build_config
        self.args = args

    @abc.abstractmethod
    def setup(self) -> None:
        """Any setup needed before `replace_rtl`, `build_driver`, and `build_bitstream` is run."""
        raise NotImplementedError

    def replace_rtl(self) -> None:
        """Generate Verilog from build config. Should run on the manager host."""
        rootLogger.info(
            f"Building Verilog for {self.build_config.get_chisel_quintuplet()}"
        )

        deploy_dir = get_deploy_dir()
        with InfoStreamLogger("stdout"), prefix(f"cd {deploy_dir}/../"), prefix(
            create_export_string({"RISCV", "PATH", "LD_LIBRARY_PATH"})
        ), prefix("source sourceme-manager.sh --skip-ssh-setup"), InfoStreamLogger(
            "stdout"
        ), prefix(
            "cd sim/"
        ):
            run(self.build_config.make_recipe("replace-rtl", deploy_dir))

    def build_driver(self) -> None:
        """Build FireSim FPGA driver from build config. Should run on the manager host."""
        rootLogger.info(
            f"Building FPGA driver for {self.build_config.get_chisel_quintuplet()}"
        )

        deploy_dir = get_deploy_dir()
        with InfoStreamLogger("stdout"), prefix(f"cd {deploy_dir}/../"), prefix(
            create_export_string({"RISCV", "PATH", "LD_LIBRARY_PATH"})
        ), prefix("source sourceme-manager.sh --skip-ssh-setup"), prefix("cd sim/"):
            run(self.build_config.make_recipe("driver", deploy_dir))

    @abc.abstractmethod
    def build_bitstream(self, bypass: bool = False) -> bool:
        """Run bitstream build and terminate the build host at the end.
        Must run after `replace_rtl` and `build_driver` are run.

        Args:
            bypass: If true, immediately return and terminate build host. Used for testing purposes.

        Returns:
            Boolean indicating if the build passed or failed.
        """
        raise NotImplementedError

    def get_metadata_string(self) -> str:
        """Standardized metadata format used across different FPGA platforms"""
        # construct the "tags" we store in the metadata description
        tag_build_quintuplet = self.build_config.get_chisel_quintuplet()
        tag_deploy_quintuplet = self.build_config.get_effective_deploy_quintuplet()

        tag_build_triplet = self.build_config.get_chisel_triplet()
        tag_deploy_triplet = self.build_config.get_effective_deploy_triplet()

        tag_build_makefrag = self.build_config.get_deploy_makefrag()
        tag_deploy_makefrag = self.build_config.get_deploy_makefrag()

        # the asserts are left over from when we tried to do this with tags
        # - technically I don't know how long these descriptions are allowed to be,
        # but it's at least 2048 chars, so I'll leave these here for now as sanity
        # checks.
        assert (
            len(tag_build_quintuplet) <= 255
        ), "ERR: does not support tags longer than 256 chars for build_quintuplet"
        assert (
            len(tag_deploy_quintuplet) <= 255
        ), "ERR: does not support tags longer than 256 chars for deploy_quintuplet"
        assert (
            len(tag_build_triplet) <= 255
        ), "ERR: does not support tags longer than 256 chars for build_triplet"
        assert (
            len(tag_deploy_triplet) <= 255
        ), "ERR: does not support tags longer than 256 chars for deploy_triplet"
        if tag_build_makefrag:
            assert (
                len(tag_build_makefrag) <= 255
            ), "ERR: does not support tags longer than 256 chars for build_makefrag"
        if tag_deploy_makefrag:
            assert (
                len(tag_deploy_makefrag) <= 255
            ), "ERR: does not support tags longer than 256 chars for deploy_makefrag"

        is_dirty_str = local(
            "if [[ $(git status --porcelain) ]]; then echo '-dirty'; fi", capture=True
        )
        hash = local("git rev-parse HEAD", capture=True)
        tag_fsimcommit = hash + is_dirty_str

        assert (
            len(tag_fsimcommit) <= 255
        ), "ERR: aws does not support tags longer than 256 chars for fsimcommit"

        # construct the serialized description from these tags.
        return firesim_tags_to_description(
            tag_build_quintuplet,
            tag_deploy_quintuplet,
            tag_build_triplet,
            tag_deploy_triplet,
            tag_fsimcommit,
            tag_build_makefrag,
            tag_deploy_makefrag,
        )


class F2BitBuilder(BitBuilder):
    """Bit builder class that builds a AWS EC2 F2 AGFI (bitstream) from the build config.

    Attributes:
        s3_bucketname: S3 bucketname for AFI builds.
    """

    s3_bucketname: str

    def __init__(self, build_config: BuildConfig, args: Dict[str, Any]) -> None:
        super().__init__(build_config, args)
        self._parse_args()

    def _parse_args(self) -> None:
        """Parse bitbuilder arguments."""
        self.s3_bucketname = self.args["s3_bucket_name"]
        if valid_aws_configure_creds():
            if self.args["append_userid_region"]:
                self.s3_bucketname += "-" + get_aws_userid() + "-" + get_aws_region()

            aws_resource_names_dict = aws_resource_names()
            if aws_resource_names_dict["s3bucketname"] is not None:
                # in tutorial mode, special s3 bucket name
                self.s3_bucketname = aws_resource_names_dict["s3bucketname"]

    def setup(self) -> None:
        auto_create_bucket(self.s3_bucketname)

        # check to see email notifications can be subscribed
        get_snsname_arn()

    def cl_dir_setup(self, chisel_quintuplet: str, dest_build_dir: str) -> str:
        """Setup CL_DIR on build host.

        Args:
            chisel_quintuplet: Build config chisel quintuplet used to uniquely identify build dir.
            dest_build_dir: Destination base directory to use.

        Returns:
            Path to CL_DIR directory (that is setup) or `None` if invalid.
        """
        fpga_build_postfix = f"hdk/cl/developer_designs/cl_{chisel_quintuplet}"

        # local paths
        local_awsfpga_dir = f"{get_deploy_dir()}/../platforms/f2/aws-fpga-firesim-f2"

        dest_f2_platform_dir = f"{dest_build_dir}/platforms/f2/"
        dest_awsfpga_dir = f"{dest_f2_platform_dir}/aws-fpga-firesim-f2"

        # copy aws-fpga to the build instance.
        # do the rsync, but ignore any checkpoints that might exist on this machine
        # (in case builds were run locally)
        # extra_opts -l preserves symlinks
        with prefix("cd ../"):
            # use local version of aws_fpga on build farm nodes
            aws_fpga_upstream_version = local(
                "git -C platforms/f2/aws-fpga-firesim-f2 describe --tags --always --dirty",
                capture=True,
            )
            if "-dirty" in aws_fpga_upstream_version:
                aws_fpga_upstream_version = aws_fpga_upstream_version.replace("-dirty", "")
                rootLogger.critical(
                    "Unable to use local changes to aws-fpga. Continuing without them."
                )

        run(f"mkdir -p {dest_f2_platform_dir}")
        with prefix("cd " + dest_f2_platform_dir):
            run("git clone https://github.com/firesim/aws-fpga-firesim-f2.git")
        with prefix("cd " + dest_awsfpga_dir):
            run("git checkout " + aws_fpga_upstream_version)

        rsync_cap = rsync_project(
            local_dir=local_awsfpga_dir,
            remote_dir=dest_f2_platform_dir,
            ssh_opts="-o StrictHostKeyChecking=no",
            exclude=["hdk/cl/developer_designs/cl_*", ".git", "hdk/common/ip", "hdk/common/shell_stable/hlx"],
            extra_opts="-l",
            capture=True,
        )
        rootLogger.debug(rsync_cap)
        rootLogger.debug(rsync_cap.stderr)
        rsync_cap = rsync_project(
            local_dir=f"{local_awsfpga_dir}/{fpga_build_postfix}/*",
            remote_dir=f"{dest_awsfpga_dir}/{fpga_build_postfix}",
            exclude=["build/checkpoints", ".git", "hdk/common/ip", "hdk/common/shell_stable/hlx"],
            ssh_opts="-o StrictHostKeyChecking=no",
            extra_opts="-l",
            capture=True,
        )
        rootLogger.debug(rsync_cap)
        rootLogger.debug(rsync_cap.stderr)

        return f"{dest_awsfpga_dir}/{fpga_build_postfix}"

    def build_bitstream(self, bypass: bool = False) -> bool:
        """Run Vivado, convert tar -> AGFI/AFI, and then terminate the instance at the end.

        Args:
            bypass: If true, immediately return and terminate build host. Used for testing purposes.

        Returns:
            Boolean indicating if the build passed or failed.
        """
        build_farm = self.build_config.build_config_file.build_farm

        if bypass:
            build_farm.release_build_host(self.build_config)
            return True

        # The default error-handling procedure. Send an email and teardown instance
        def on_build_failure():
            """Terminate build host and notify user that build failed"""

            message_title = "FireSim FPGA Build Failed"

            message_body = (
                "Your FPGA build failed for quintuplet: "
                + self.build_config.get_chisel_quintuplet()
            )

            send_firesim_notification(message_title, message_body)

            rootLogger.info(message_title)
            rootLogger.info(message_body)

            build_farm.release_build_host(self.build_config)

        rootLogger.info("Building AWS F2 AGFI from Verilog")

        local_deploy_dir = get_deploy_dir()
        fpga_build_postfix = (
            f"hdk/cl/developer_designs/cl_{self.build_config.get_chisel_quintuplet()}"
        )
        local_results_dir = (
            f"{local_deploy_dir}/results-build/{self.build_config.get_build_dir_name()}"
        )

        # 'cl_dir' holds the eventual directory in which vivado will run.
        cl_dir = self.cl_dir_setup(
            self.build_config.get_chisel_quintuplet(),
            build_farm.get_build_host(self.build_config).dest_build_dir,
        )

        vivado_rc = 0

        # copy script to the cl_dir and execute
        rsync_cap = rsync_project(
            local_dir=f"{local_deploy_dir}/../platforms/f2/build-bitstream.sh",
            remote_dir=f"{cl_dir}/",
            ssh_opts="-o StrictHostKeyChecking=no",
            extra_opts="-l",
            capture=True,
        )
        rootLogger.debug(rsync_cap)
        rootLogger.debug(rsync_cap.stderr)

        # get the frequency and strategy
        fpga_frequency = self.build_config.get_frequency()
        build_strategy = self.build_config.get_strategy().name

        with InfoStreamLogger("stdout"), settings(warn_only=True):
            vivado_result = run(
                f"{cl_dir}/build-bitstream.sh --cl_dir {cl_dir} --frequency {fpga_frequency} --strategy {build_strategy}"
            )
            vivado_rc = vivado_result.return_code

            if vivado_result != 0:
                rootLogger.info("Printing error output:")
                for line in vivado_result.splitlines()[-100:]:
                    rootLogger.info(line)

        # put build results in the result-build area

        rsync_cap = rsync_project(
            local_dir=f"{local_results_dir}/",
            remote_dir=cl_dir,
            ssh_opts="-o StrictHostKeyChecking=no",
            upload=False,
            extra_opts="-l",
            capture=True,
        )
        rootLogger.debug(rsync_cap)
        rootLogger.debug(rsync_cap.stderr)

        if vivado_rc != 0:
            on_build_failure()
            return False

        if not self.aws_create_afi():
            on_build_failure()
            return False

        build_farm.release_build_host(self.build_config)

        return True

    def aws_create_afi(self) -> Optional[bool]:
        """Convert the tarball created by Vivado build into an Amazon Global FPGA Image (AGFI).

        Args:
            build_config: Build config to determine paths.

        Returns:
            `True` on success, `None` on error.
        """
        local_deploy_dir = get_deploy_dir()
        local_results_dir = (
            f"{local_deploy_dir}/results-build/{self.build_config.get_build_dir_name()}"
        )

        afi = None
        agfi = None
        s3bucket = self.s3_bucketname
        afiname = self.build_config.name

        description = self.get_metadata_string()

        # if we're unlucky, multiple vivado builds may launch at the same time. so we
        # append the build node IP + a random string to diff them in s3
        global_append = (
            "-"
            + str(env.host_string)
            + "-"
            + "".join(
                random.SystemRandom().choice(string.ascii_uppercase + string.digits)
                for _ in range(10)
            )
            + ".tar"
        )

        with lcd(
            f"{local_results_dir}/cl_{self.build_config.get_chisel_quintuplet()}/build/checkpoints/"
        ):
            files = local("ls *.tar", capture=True)
            rootLogger.debug(files)
            rootLogger.debug(files.stderr)
            tarfile = files.split()[-1]
            s3_tarfile = tarfile + global_append
            localcap = local(
                "aws s3 cp " + tarfile + " s3://" + s3bucket + "/dcp/" + s3_tarfile,
                capture=True,
            )
            rootLogger.debug(localcap)
            rootLogger.debug(localcap.stderr)
            agfi_afi_ids = local(
                f"""aws ec2 create-fpga-image --input-storage-location Bucket={s3bucket},Key={"dcp/" + s3_tarfile} --logs-storage-location Bucket={s3bucket},Key={"logs/"} --name "{afiname}" --description "{description}" """,
                capture=True,
            )
            rootLogger.debug(agfi_afi_ids)
            rootLogger.debug(agfi_afi_ids.stderr)
            rootLogger.debug("create-fpge-image result: " + str(agfi_afi_ids))
            ids_as_dict = json.loads(agfi_afi_ids)
            agfi = ids_as_dict["FpgaImageGlobalId"]
            afi = ids_as_dict["FpgaImageId"]
            rootLogger.info("Resulting AGFI: " + str(agfi))
            rootLogger.info("Resulting AFI: " + str(afi))

        rootLogger.info("Waiting for create-fpga-image completion.")
        checkstate = "pending"
        with lcd(local_results_dir):
            while checkstate == "pending":
                imagestate = local(
                    f"aws ec2 describe-fpga-images --fpga-image-id {afi} | tee AGFI_INFO",
                    capture=True,
                )
                state_as_dict = json.loads(imagestate)
                checkstate = state_as_dict["FpgaImages"][0]["State"]["Code"]
                rootLogger.info("Current state: " + str(checkstate))
                time.sleep(10)

        if checkstate == "available":
            # copy the image to all regions for the current user
            copy_afi_to_all_regions(afi)

            message_title = "FireSim FPGA Build Completed"
            agfi_entry = afiname + ":\n"
            agfi_entry += "    agfi: " + agfi + "\n"
            agfi_entry += "    deploy_quintuplet_override: null\n"
            agfi_entry += "    custom_runtime_config: null\n"
            message_body = (
                "Your AGFI has been created!\nAdd\n\n"
                + agfi_entry
                + "\nto your config_hwdb.yaml to use this hardware configuration."
            )

            send_firesim_notification(message_title, message_body)

            rootLogger.info(message_title)
            rootLogger.info(message_body)

            # for convenience when generating a bunch of images. you can just
            # cat all the files in this directory after your builds finish to get
            # all the entries to copy into config_hwdb.yaml
            hwdb_entry_file_location = f"{local_deploy_dir}/built-hwdb-entries/"
            local("mkdir -p " + hwdb_entry_file_location)
            with open(hwdb_entry_file_location + "/" + afiname, "w") as outputfile:
                outputfile.write(agfi_entry)

            if self.build_config.post_build_hook:
                localcap = local(
                    f"{self.build_config.post_build_hook} {local_results_dir}",
                    capture=True,
                )
                rootLogger.debug("[localhost] " + str(localcap))
                rootLogger.debug("[localhost] " + str(localcap.stderr))

            rootLogger.info(
                f"Build complete! AFI ready. See {os.path.join(hwdb_entry_file_location,afiname)}."
            )
            return True
        else:
            return None

class VitisBitBuilder(BitBuilder):
    """Bit builder class that builds a Vitis bitstream from the build config.

    Attributes:
        device: vitis fpga platform string to use for building the bitstream
    """

    device: str

    def __init__(self, build_config: BuildConfig, args: Dict[str, Any]) -> None:
        super().__init__(build_config, args)
        self._parse_args()

    def _parse_args(self) -> None:
        """Parse bitbuilder arguments."""
        self.device = self.args["device"]

    def setup(self) -> None:
        return

    def cl_dir_setup(self, chisel_quintuplet: str, dest_build_dir: str) -> str:
        """Setup CL_DIR on build host.

        Args:
            chisel_quintuplet: Build config chisel quintuplet used to uniquely identify build dir.
            dest_build_dir: Destination base directory to use.

        Returns:
            Path to CL_DIR directory (that is setup) or `None` if invalid.
        """
        fpga_build_postfix = f"cl_{chisel_quintuplet}"

        # local paths
        local_vitis_dir = f"{get_deploy_dir()}/../platforms/vitis"

        dest_vitis_dir = "{}/platforms/vitis".format(dest_build_dir)

        # copy vitis to the build instance.
        # do the rsync, but ignore any checkpoints that might exist on this machine
        # (in case builds were run locally)
        # extra_opts -l preserves symlinks

        run("mkdir -p {}".format(dest_vitis_dir))
        run("rm -rf {}/{}".format(dest_vitis_dir, fpga_build_postfix))
        rsync_cap = rsync_project(
            local_dir=local_vitis_dir,
            remote_dir=dest_vitis_dir,
            ssh_opts="-o StrictHostKeyChecking=no",
            exclude="cl_*",
            extra_opts="-l",
            capture=True,
        )
        rootLogger.debug(rsync_cap)
        rootLogger.debug(rsync_cap.stderr)
        rsync_cap = rsync_project(
            local_dir="{}/{}/".format(local_vitis_dir, fpga_build_postfix),
            remote_dir="{}/{}".format(dest_vitis_dir, fpga_build_postfix),
            ssh_opts="-o StrictHostKeyChecking=no",
            extra_opts="-l",
            capture=True,
        )
        rootLogger.debug(rsync_cap)
        rootLogger.debug(rsync_cap.stderr)

        return f"{dest_vitis_dir}/{fpga_build_postfix}"

    def build_bitstream(self, bypass: bool = False) -> bool:
        """Run Vitis to generate an xclbin. Then terminate the instance at the end.

        Args:
            bypass: If true, immediately return and terminate build host. Used for testing purposes.

        Returns:
            Boolean indicating if the build passed or failed.
        """
        build_farm = self.build_config.build_config_file.build_farm

        if bypass:
            build_farm.release_build_host(self.build_config)
            return True

        # The default error-handling procedure. Send an email and teardown instance
        def on_build_failure():
            """Terminate build host and notify user that build failed"""

            message_title = "FireSim Vitis FPGA Build Failed"

            message_body = (
                "Your FPGA build failed for quintuplet: "
                + self.build_config.get_chisel_quintuplet()
            )

            rootLogger.info(message_title)
            rootLogger.info(message_body)

            build_farm.release_build_host(self.build_config)

        rootLogger.info("Building Vitis Bitstream from Verilog")

        local_deploy_dir = get_deploy_dir()
        fpga_build_postfix = f"cl_{self.build_config.get_chisel_quintuplet()}"
        local_results_dir = (
            f"{local_deploy_dir}/results-build/{self.build_config.get_build_dir_name()}"
        )

        # 'cl_dir' holds the eventual directory in which vivado will run.
        cl_dir = self.cl_dir_setup(
            self.build_config.get_chisel_quintuplet(),
            build_farm.get_build_host(self.build_config).dest_build_dir,
        )

        vitis_rc = 0
        # copy script to the cl_dir and execute
        rsync_cap = rsync_project(
            local_dir=f"{local_deploy_dir}/../platforms/vitis/build-bitstream.sh",
            remote_dir=f"{cl_dir}/",
            ssh_opts="-o StrictHostKeyChecking=no",
            extra_opts="-l",
            capture=True,
        )
        rootLogger.debug(rsync_cap)
        rootLogger.debug(rsync_cap.stderr)

        fpga_frequency = self.build_config.get_frequency()
        build_strategy = self.build_config.get_strategy().name

        with InfoStreamLogger("stdout"), settings(warn_only=True):
            vitis_result = run(
                f"{cl_dir}/build-bitstream.sh --build_dir {cl_dir} --device {self.device} --frequency {fpga_frequency} --strategy {build_strategy}"
            )
            vitis_rc = vitis_result.return_code

            if vitis_rc != 0:
                rootLogger.info("Printing error output:")
                for line in vitis_result.splitlines()[-100:]:
                    rootLogger.info(line)

        # put build results in the result-build area

        rsync_cap = rsync_project(
            local_dir=f"{local_results_dir}/",
            remote_dir=cl_dir,
            ssh_opts="-o StrictHostKeyChecking=no",
            upload=False,
            extra_opts="-l",
            capture=True,
        )
        rootLogger.debug(rsync_cap)
        rootLogger.debug(rsync_cap.stderr)

        if vitis_rc != 0:
            on_build_failure()
            return False

        hwdb_entry_name = self.build_config.name
        local_cl_dir = f"{local_results_dir}/{fpga_build_postfix}"

        bit_path = f"{local_cl_dir}/bitstream/build_dir.{self.device}/firesim.xclbin"
        tar_staging_path = f"{local_cl_dir}/{self.build_config.PLATFORM}"
        tar_name = "firesim.tar.gz"

        # store files into staging dir
        local(f"rm -rf {tar_staging_path}")
        local(f"mkdir -p {tar_staging_path}")

        # store bitfile
        local(f"cp {bit_path} {tar_staging_path}")

        # store metadata string
        local(f"""echo '{self.get_metadata_string()}' >> {tar_staging_path}/metadata""")

        # form tar.gz
        with prefix(f"cd {local_cl_dir}"):
            local(f"tar zcvf {tar_name} {self.build_config.PLATFORM}/")

        hwdb_entry = hwdb_entry_name + ":\n"
        hwdb_entry += f"    bitstream_tar: file://{local_cl_dir}/{tar_name}\n"
        hwdb_entry += f"    deploy_quintuplet_override: null\n"
        hwdb_entry += "    custom_runtime_config: null\n"

        message_title = "FireSim FPGA Build Completed"
        message_body = (
            "Your bitstream has been created!\nAdd\n\n"
            + hwdb_entry
            + "\nto your config_hwdb.yaml to use this hardware configuration."
        )

        rootLogger.info(message_title)
        rootLogger.info(message_body)

        # for convenience when generating a bunch of images. you can just
        # cat all the files in this directory after your builds finish to get
        # all the entries to copy into config_hwdb.yaml
        hwdb_entry_file_location = f"{local_deploy_dir}/built-hwdb-entries/"
        local("mkdir -p " + hwdb_entry_file_location)
        with open(hwdb_entry_file_location + "/" + hwdb_entry_name, "w") as outputfile:
            outputfile.write(hwdb_entry)

        if self.build_config.post_build_hook:
            localcap = local(
                f"{self.build_config.post_build_hook} {local_results_dir}", capture=True
            )
            rootLogger.debug("[localhost] " + str(localcap))
            rootLogger.debug("[localhost] " + str(localcap.stderr))

        rootLogger.info(
            f"Build complete! Vitis bitstream ready. See {os.path.join(hwdb_entry_file_location,hwdb_entry_name)}."
        )

        build_farm.release_build_host(self.build_config)

        return True


class XilinxAlveoBitBuilder(BitBuilder):
    """Bit builder class that builds a Xilinx Alveo bitstream from the build config."""

    BOARD_NAME: Optional[str]

    def _resolve_pr_base(self, local_deploy_dir: str) -> tuple[Optional[str], Optional[dict]]:
        """Resolve manager-local base artifacts before talking to the build host.

        `results-build` belongs to the manager, not to a remote build farm.
        The returned project is staged separately below, which makes a base
        built on one machine usable for an RM build on another machine.
        """
        project = self.build_config.get_pr_project_path()
        recipe = self.build_config.get_pr_base_recipe()
        if recipe and not project:
            from pathlib import Path
            recipes = self.build_config.build_config_file.all_build_recipes
            if recipe not in recipes:
                raise Exception(f"Unknown pr_base_recipe '{recipe}'")
            base = recipes[recipe]
            if base.get("PLATFORM") != self.build_config.PLATFORM:
                raise Exception(
                    f"DFX base '{recipe}' targets {base.get('PLATFORM')}, not {self.build_config.PLATFORM}"
                )
            quintuplet = "-".join((self.build_config.PLATFORM, base["TARGET_PROJECT"], base["DESIGN"], base["TARGET_CONFIG"], base["PLATFORM_CONFIG"]))
            candidates = sorted((Path(local_deploy_dir) / "results-build").glob(f"*-{recipe}"), reverse=True)
            for result in candidates:
                candidate = result / f"cl_{quintuplet}" / "vivado_proj" / "firesim.xpr"
                if candidate.is_file() and (candidate.parent / "pr_metadata.json").is_file():
                    project = str(candidate)
                    break
            if not project:
                raise Exception(f"No completed DFX base for '{recipe}' with firesim.xpr and pr_metadata.json")
        if not project:
            return None, None
        metadata_path = os.path.join(os.path.dirname(project), "pr_metadata.json")
        try:
            with open(metadata_path) as metadata_file:
                return project, json.load(metadata_file)
        except (OSError, json.JSONDecodeError) as error:
            raise Exception(f"Unable to read base PR metadata at {metadata_path}: {error}")

    def __init__(self, build_config: BuildConfig, args: Dict[str, Any]) -> None:
        super().__init__(build_config, args)
        self.BOARD_NAME = None

    def setup(self) -> None:
        return

    def cl_dir_setup(self, chisel_quintuplet: str, dest_build_dir: str) -> str:
        """Setup CL_DIR on build host.

        Args:
            chisel_quintuplet: Build config chisel quintuplet used to uniquely identify build dir.
            dest_build_dir: Destination base directory to use.

        Returns:
            Path to CL_DIR directory (that is setup) or `None` if invalid.
        """
        fpga_build_postfix = f"cl_{chisel_quintuplet}"

        # local paths
        local_alveo_dir = (
            f"{get_deploy_dir()}/../platforms/{self.build_config.PLATFORM}"
        )

        dest_alveo_dir = f"{dest_build_dir}/platforms/{self.build_config.PLATFORM}"

        # copy alveo files to the build instance.
        # do the rsync, but ignore any checkpoints that might exist on this machine
        # (in case builds were run locally)
        # extra_opts -L resolves symlinks

        run(f"mkdir -p {dest_alveo_dir}")
        run("rm -rf {}/{}".format(dest_alveo_dir, fpga_build_postfix))
        rsync_cap = rsync_project(
            local_dir=local_alveo_dir,
            remote_dir=dest_alveo_dir,
            ssh_opts="-o StrictHostKeyChecking=no",
            exclude="cl_*",
            extra_opts="-L",
            capture=True,
        )
        rootLogger.debug(rsync_cap)
        rootLogger.debug(rsync_cap.stderr)
        rsync_cap = rsync_project(
            local_dir=f"{local_alveo_dir}/{fpga_build_postfix}/",
            remote_dir=f"{dest_alveo_dir}/{fpga_build_postfix}",
            ssh_opts="-o StrictHostKeyChecking=no",
            extra_opts="-L",
            capture=True,
        )
        rootLogger.debug(rsync_cap)
        rootLogger.debug(rsync_cap.stderr)

        if self.build_config.PLATFORM in ("xilinx_alveo_u250", "corigine_xb10"):
            # replace-rtl snapshots the platform scripts in cl_<quintuplet>.
            # Refresh that snapshot at build time so a buildbitstream retry
            # uses the current upstream normal Tcl and current PR Tcl without
            # requiring another Golden Gate run.
            script_sync = rsync_project(
                local_dir=f"{local_alveo_dir}/cl_firesim/scripts/",
                remote_dir=f"{dest_alveo_dir}/{fpga_build_postfix}/scripts",
                ssh_opts="-o StrictHostKeyChecking=no",
                extra_opts="-L",
                capture=True,
            )
            if script_sync.return_code != 0:
                raise Exception(f"Could not stage current {self.build_config.PLATFORM} Tcl scripts: {script_sync.stderr}")
            rootLogger.debug(script_sync)

        return f"{dest_alveo_dir}/{fpga_build_postfix}"

    def build_bitstream(self, bypass: bool = False) -> bool:
        """Run Vivado to generate an bit file. Then terminate the instance at the end.

        Args:
            bypass: If true, immediately return and terminate build host. Used for testing purposes.

        Returns:
            Boolean indicating if the build passed or failed.
        """
        build_farm = self.build_config.build_config_file.build_farm

        if bypass:
            build_farm.release_build_host(self.build_config)
            return True

        # The default error-handling procedure. Send an email and teardown instance
        def on_build_failure():
            """Terminate build host and notify user that build failed"""

            message_title = (
                f"FireSim Xilinx Alveo {self.build_config.PLATFORM} FPGA Build Failed"
            )

            message_body = (
                "Your FPGA build failed for quintuplet: "
                + self.build_config.get_chisel_quintuplet()
            )

            rootLogger.info(message_title)
            rootLogger.info(message_body)

            build_farm.release_build_host(self.build_config)

        rootLogger.info(
            f"Building Xilinx Alveo {self.build_config.PLATFORM} Bitstream from Verilog"
        )

        local_deploy_dir = get_deploy_dir()
        fpga_build_postfix = f"cl_{self.build_config.get_chisel_quintuplet()}"
        local_results_dir = (
            f"{local_deploy_dir}/results-build/{self.build_config.get_build_dir_name()}"
        )

        enable_pr = self.build_config.get_enable_pr()
        if enable_pr and self.build_config.PLATFORM in ("xilinx_alveo_u250", "corigine_xb10"):
            local_platform = f"{local_deploy_dir}/../platforms/{self.build_config.PLATFORM}"
            local_design = f"{local_platform}/{fpga_build_postfix}/design"
            splitter = f"{local_deploy_dir}/../sim/scripts/split-verilog.py"
            local(
                f"python3 {splitter} {local_design}/FireSim-generated.sv "
                f"-o {local_design}/split-verilog"
            )

        # 'cl_dir' holds the eventual directory in which vivado will run.
        cl_dir = self.cl_dir_setup(
            self.build_config.get_chisel_quintuplet(),
            build_farm.get_build_host(self.build_config).dest_build_dir,
        )

        alveo_rc = 0
        # copy script to the cl_dir and execute
        rsync_cap = rsync_project(
            local_dir=f"{local_deploy_dir}/../platforms/{self.build_config.PLATFORM}/build-bitstream.sh",
            remote_dir=f"{cl_dir}/",
            ssh_opts="-o StrictHostKeyChecking=no",
            extra_opts="-L",
            capture=True,
        )
        rootLogger.debug(rsync_cap)
        rootLogger.debug(rsync_cap.stderr)

        project, base_metadata = self._resolve_pr_base(local_deploy_dir) if enable_pr else (None, None)
        if base_metadata:
            expected_parts = {
                "xilinx_alveo_u250": "xcu250-figd2104-2l-e",
                "corigine_xb10": "xcvu19p-fsvb3824-2-e",
            }
            expected_part = expected_parts.get(self.build_config.PLATFORM)
            if expected_part and base_metadata.get("part", "").lower() != expected_part:
                raise Exception(
                    f"DFX base part {base_metadata.get('part')!r} does not match "
                    f"{self.build_config.PLATFORM} ({expected_part})"
                )
        fpga_frequency = self.build_config.get_frequency()
        if fpga_frequency is None and base_metadata:
            fpga_frequency = float(base_metadata["frequency_mhz"])
        if fpga_frequency is None:
            raise Exception("DFX RM is missing a base frequency in pr_metadata.json")
        build_strategy = self.build_config.get_strategy().name

        module_names = self.build_config.get_pr_module_name()
        partition_paths = self.build_config.get_pr_partition_path()
        if base_metadata:
            modules = base_metadata.get("pr_modules", [])
            module_names = module_names or [item["module_name"] for item in modules]
            partition_paths = partition_paths or [path for item in modules for path in item.get("partition_paths", [])]
        if enable_pr and not module_names:
            raise Exception("No DFX module name was supplied or found in base metadata")

        # An RM must never write into the archived base. Stage the complete CL
        # directory (XPR, abstract shell, metadata, and referenced sources) to
        # the remote build host and rewrite only the remote project path.
        remote_project = None
        if project:
            base_cl = os.path.dirname(os.path.dirname(project))
            remote_base = f"{cl_dir}/base_project"
            run(f"rm -rf {remote_base} && mkdir -p {remote_base}")
            staged = rsync_project(local_dir=f"{base_cl}/", remote_dir=f"{remote_base}/", ssh_opts="-o StrictHostKeyChecking=no", extra_opts="-L", capture=True)
            if staged.return_code != 0:
                raise Exception(f"Could not stage DFX base to build host: {staged.stderr}")
            remote_project = f"{remote_base}/vivado_proj/{os.path.basename(project)}"

        command = f"{cl_dir}/build-bitstream.sh --cl_dir {cl_dir} --frequency {fpga_frequency} --strategy {build_strategy} --board {self.BOARD_NAME}"
        if enable_pr:
            command += f" --enable_pr true --pr_module_name {','.join(module_names)}"
            if partition_paths:
                command += f" --pr_partition_path {','.join(partition_paths)}"
            if remote_project:
                command += f" --pr_project_path {remote_project} --pr_mode {self.build_config.get_pr_mode()}"

        with InfoStreamLogger("stdout"), settings(warn_only=True):
            alveo_result = run(command)
            alveo_rc = alveo_result.return_code

            if alveo_rc != 0:
                rootLogger.info("Printing error output:")
                for line in alveo_result.splitlines()[-100:]:
                    rootLogger.info(line)

        # put build results in the result-build area

        rsync_cap = rsync_project(
            local_dir=f"{local_results_dir}/",
            remote_dir=cl_dir,
            ssh_opts="-o StrictHostKeyChecking=no",
            upload=False,
            extra_opts="-l",
            capture=True,
        )
        rootLogger.debug(rsync_cap)
        rootLogger.debug(rsync_cap.stderr)

        if alveo_rc != 0:
            on_build_failure()
            return False

        # make hwdb entry from locally stored results

        hwdb_entry_name = self.build_config.name
        local_cl_dir = f"{local_results_dir}/{fpga_build_postfix}"
        bit_path = f"{local_cl_dir}/vivado_proj/firesim.bit"
        mcs_path = f"{local_cl_dir}/vivado_proj/firesim.mcs"
        mcs_secondary_path = f"{local_cl_dir}/vivado_proj/firesim_secondary.mcs"
        tar_staging_path = f"{local_cl_dir}/{self.build_config.PLATFORM}"
        tar_name = "firesim.tar.gz"

        # store files into staging dir
        local(f"rm -rf {tar_staging_path}")
        local(f"mkdir -p {tar_staging_path}")

        # An RM tar deliberately contains only its partial plus compatibility
        # metadata. A base tar keeps the normal full-bit layout unchanged.
        if enable_pr and project:
            # The proven non-project Tcl writes beside the staged base XPR;
            # project-mode Tcl writes into the current CL's vivado_proj.
            partial_candidates = (
                f"{local_cl_dir}/vivado_proj/firesim_impl_rm_0_partial.bit",
                f"{local_cl_dir}/base_project/vivado_proj/firesim_impl_rm_0_partial.bit",
            )
            partial_path = next((path for path in partial_candidates if os.path.isfile(path)), None)
            if partial_path is None:
                raise Exception(f"DFX RM partial bitstream missing; checked {partial_candidates}")
            local(f"cp {partial_path} {tar_staging_path}/firesim_partial.bit")
            local(f"cp {os.path.dirname(project)}/pr_metadata.json {tar_staging_path}/pr_metadata.json")
            local(f"sha256sum {os.path.dirname(project)}/firesim.bit | awk '{{print $1}}' > {tar_staging_path}/compatible_base_bit.sha256")
            tar_name = "firesim_partial.tar.gz"
        else:
            local(f"cp {bit_path} {tar_staging_path}")
            local(f"cp {mcs_path} {tar_staging_path}")
            if self.build_config.PLATFORM == "xilinx_vcu118":
                local(f"cp {mcs_secondary_path} {tar_staging_path}")

        # store metadata string
        local(f"""echo '{self.get_metadata_string()}' >> {tar_staging_path}/metadata""")

        # form tar.gz
        with prefix(f"cd {local_cl_dir}"):
            local(f"tar zcvf {tar_name} {self.build_config.PLATFORM}/")

        # The driver was built with the bitstream. Preserve it alongside the
        # base artifact so an RM built/run on other machines needs no checkout.
        driver_dir = f"{local_cl_dir}/driver"
        driver_tar = f"{local_cl_dir}/driver-bundle.tar.gz"
        if os.path.isdir(driver_dir):
            local(f"tar -C {driver_dir} -czf {driver_tar} .")

        hwdb_bitstream_tar = f"{local_cl_dir}/{tar_name}"
        hwdb_driver_tar = driver_tar if os.path.isfile(driver_tar) else None
        if enable_pr and project:
            # An RM archive contains only a partial bitstream. Its HWDB entry
            # must still name the matching base's full bitstream and driver;
            # partial_bitstream_tar supplies the overlay programmed afterward.
            base_cl = os.path.dirname(os.path.dirname(project))
            hwdb_bitstream_tar = f"{base_cl}/firesim.tar.gz"
            if not os.path.isfile(hwdb_bitstream_tar):
                raise Exception(
                    f"Matching DFX base bitstream archive is missing: {hwdb_bitstream_tar}"
                )
            base_driver_tar = f"{base_cl}/driver-bundle.tar.gz"
            hwdb_driver_tar = (
                base_driver_tar if os.path.isfile(base_driver_tar) else None
            )

        hwdb_entry = hwdb_entry_name + ":\n"
        hwdb_entry += f"    bitstream_tar: file://{hwdb_bitstream_tar}\n"
        if hwdb_driver_tar:
            hwdb_entry += f"    driver_tar: file://{hwdb_driver_tar}\n"
        if enable_pr and project:
            hwdb_entry += f"    partial_bitstream_tar: file://{local_cl_dir}/{tar_name}\n"
        hwdb_entry += f"    deploy_quintuplet_override: null\n"
        hwdb_entry += "    custom_runtime_config: null\n"

        message_title = "FireSim FPGA Build Completed"
        message_body = f"Your bitstream has been created!\nAdd\n\n{hwdb_entry}\nto your config_hwdb.yaml to use this hardware configuration."

        rootLogger.info(message_title)
        rootLogger.info(message_body)

        # for convenience when generating a bunch of images. you can just
        # cat all the files in this directory after your builds finish to get
        # all the entries to copy into config_hwdb.yaml
        hwdb_entry_file_location = f"{local_deploy_dir}/built-hwdb-entries/"
        local("mkdir -p " + hwdb_entry_file_location)
        with open(hwdb_entry_file_location + "/" + hwdb_entry_name, "w") as outputfile:
            outputfile.write(hwdb_entry)

        if self.build_config.post_build_hook:
            localcap = local(
                f"{self.build_config.post_build_hook} {local_results_dir}", capture=True
            )
            rootLogger.debug("[localhost] " + str(localcap))
            rootLogger.debug("[localhost] " + str(localcap.stderr))

        rootLogger.info(
            f"Build complete! Xilinx Alveo {self.build_config.PLATFORM} bitstream ready. See {os.path.join(hwdb_entry_file_location,hwdb_entry_name)}."
        )

        build_farm.release_build_host(self.build_config)

        return True


class XilinxAlveoU200BitBuilder(XilinxAlveoBitBuilder):
    def __init__(self, build_config: BuildConfig, args: Dict[str, Any]) -> None:
        super().__init__(build_config, args)
        self.BOARD_NAME = "au200"


class XilinxAlveoU280BitBuilder(XilinxAlveoBitBuilder):
    def __init__(self, build_config: BuildConfig, args: Dict[str, Any]) -> None:
        super().__init__(build_config, args)
        self.BOARD_NAME = "au280"


class XilinxAlveoU250BitBuilder(XilinxAlveoBitBuilder):
    def __init__(self, build_config: BuildConfig, args: Dict[str, Any]) -> None:
        super().__init__(build_config, args)
        self.BOARD_NAME = "au250"


class CorigineXB10BitBuilder(XilinxAlveoBitBuilder):
    def __init__(self, build_config: BuildConfig, args: Dict[str, Any]) -> None:
        super().__init__(build_config, args)
        self.BOARD_NAME = "xb10"


class XilinxVCU118BitBuilder(XilinxAlveoBitBuilder):
    """Bit builder class that builds a Xilinx VCU118 bitstream from the build config."""

    BOARD_NAME: Optional[str]

    def __init__(self, build_config: BuildConfig, args: Dict[str, Any]) -> None:
        super().__init__(build_config, args)
        self.BOARD_NAME = "xilinx_vcu118"

    def cl_dir_setup(self, chisel_quintuplet: str, dest_build_dir: str) -> str:
        """Setup CL_DIR on build host.

        Args:
            chisel_quintuplet: Build config chisel quintuplet used to uniquely identify build dir.
            dest_build_dir: Destination base directory to use.

        Returns:
            Path to CL_DIR directory (that is setup) or `None` if invalid.
        """
        fpga_build_postfix = f"cl_{chisel_quintuplet}"

        # local paths
        local_alveo_dir = f"{get_deploy_dir()}/../platforms/{self.build_config.PLATFORM}/garnet-firesim"

        dest_alveo_dir = (
            f"{dest_build_dir}/platforms/{self.build_config.PLATFORM}/garnet-firesim"
        )

        # copy alveo files to the build instance.
        # do the rsync, but ignore any checkpoints that might exist on this machine
        # (in case builds were run locally)
        # extra_opts -L resolves symlinks

        run(f"mkdir -p {dest_alveo_dir}")
        run("rm -rf {}/{}".format(dest_alveo_dir, fpga_build_postfix))
        rsync_cap = rsync_project(
            local_dir=local_alveo_dir + "/",
            remote_dir=dest_alveo_dir,
            ssh_opts="-o StrictHostKeyChecking=no",
            exclude="cl_*",
            extra_opts="-L",
            capture=True,
        )
        rootLogger.debug(rsync_cap)
        rootLogger.debug(rsync_cap.stderr)
        rsync_cap = rsync_project(
            local_dir=f"{local_alveo_dir}/{fpga_build_postfix}/",
            remote_dir=f"{dest_alveo_dir}/{fpga_build_postfix}",
            ssh_opts="-o StrictHostKeyChecking=no",
            extra_opts="-L",
            capture=True,
        )
        rootLogger.debug(rsync_cap)
        rootLogger.debug(rsync_cap.stderr)

        return f"{dest_alveo_dir}/{fpga_build_postfix}"


class RHSResearchNitefuryIIBitBuilder(XilinxAlveoBitBuilder):
    """Bit builder class that builds an RHS Research Nitefury II bitstream from the build config."""

    BOARD_NAME: Optional[str]

    def __init__(self, build_config: BuildConfig, args: Dict[str, Any]) -> None:
        super().__init__(build_config, args)
        self.BOARD_NAME = "rhsresearch_nitefury_ii"

    def cl_dir_setup(self, chisel_quintuplet: str, dest_build_dir: str) -> str:
        """Setup CL_DIR on build host.

        Args:
            chisel_quintuplet: Build config chisel quintuplet used to uniquely identify build dir.
            dest_build_dir: Destination base directory to use.

        Returns:
            Path to CL_DIR directory (that is setup) or `None` if invalid.
        """
        fpga_build_postfix = f"Sample-Projects/Project-0/cl_{chisel_quintuplet}"

        # local paths
        local_alveo_dir = f"{get_deploy_dir()}/../platforms/{self.build_config.PLATFORM}/NiteFury-and-LiteFury-firesim"

        dest_alveo_dir = f"{dest_build_dir}/platforms/{self.build_config.PLATFORM}/NiteFury-and-LiteFury-firesim"

        # copy alveo files to the build instance.
        # do the rsync, but ignore any checkpoints that might exist on this machine
        # (in case builds were run locally)
        # extra_opts -L resolves symlinks

        run(f"mkdir -p {dest_alveo_dir}")
        run("rm -rf {}/{}".format(dest_alveo_dir, fpga_build_postfix))
        rsync_cap = rsync_project(
            local_dir=local_alveo_dir + "/",
            remote_dir=dest_alveo_dir,
            ssh_opts="-o StrictHostKeyChecking=no",
            exclude="cl_*",
            extra_opts="-L",
            capture=True,
        )
        rootLogger.debug(rsync_cap)
        rootLogger.debug(rsync_cap.stderr)
        rsync_cap = rsync_project(
            local_dir=f"{local_alveo_dir}/{fpga_build_postfix}/",
            remote_dir=f"{dest_alveo_dir}/{fpga_build_postfix}",
            ssh_opts="-o StrictHostKeyChecking=no",
            extra_opts="-L",
            capture=True,
        )
        rootLogger.debug(rsync_cap)
        rootLogger.debug(rsync_cap.stderr)

        return f"{dest_alveo_dir}/{fpga_build_postfix}"
