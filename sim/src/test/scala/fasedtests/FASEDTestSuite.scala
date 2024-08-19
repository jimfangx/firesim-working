//See LICENSE for license details.

package firesim.fasedtests

import java.io.File

import scala.io.Source
import org.scalatest.Suites

import firesim.TestSuiteUtil._
import firesim.midasexamples.BaseConfigs

/** Different runtime-configuration modes extend this trait. See below. */
sealed trait RuntimeConfig {
  def behaviorString: String
}

/** Use the .conf generated by GG by default. */
case object DefaultRuntimeConfig extends RuntimeConfig {
  val behaviorString = "with default runtime conf"
}

/** Provide no conf file. PlusArgs must be called out in the test class. */
case object EmptyRuntimeConfig extends RuntimeConfig {
  val behaviorString = "with no base runtime conf"
}

/** Specific an alternate path to a conf file. */
case class CustomRuntimeConfig(pathRelativeToSim: String) extends RuntimeConfig {
  val behaviorString = s"with runtime conf ${pathRelativeToSim}"
}

/** A specialization of TestSuiteCommon for FASED-specific testing. Mostly handles differences in the makefrag vs
  * midasexamples..
  *
  * @param targetName
  *   DESIGN: target top-level module class
  * @param targetConfigs
  *   TARGET_CONFIG: config string to parameterize the target
  * @param platformConfigs
  *   PLATFORM_CONFIG: config string to configure GG
  * @param baseRuntimeConfig
  *   Default runtime conf handling for runtest
  * @param additionalPlusArgs
  *   Non-standard plusargs to add to runTest invocations by default
  */
abstract class FASEDTest(
  override val targetName:      String,
  override val targetConfigs:   String,
  override val platformConfigs: Seq[String]   = Seq(),
  baseRuntimeConfig:            RuntimeConfig = DefaultRuntimeConfig,
  additionalPlusArgs:           Seq[String]   = Seq(),
) extends firesim.TestSuiteCommon("fasedtests") {

  override def basePlatformConfig = BaseConfigs.F1

  def invokeMlSimulator(backend: String, debug: Boolean, args: Seq[String]) = {
    make((s"run-${backend}%s".format(if (debug) "-debug" else "") +: args): _*)
  }

  def runTest(
    backend:            String,
    debug:              Boolean,
    logFile:            Option[File]   = None,
    baseRuntimeConfig:  RuntimeConfig  = baseRuntimeConfig,
    additionalPlusArgs: Seq[String]    = additionalPlusArgs,
    additionalMakeArgs: Seq[String]    = Seq(),
    behaviorSpec:       Option[String] = None,
  ) = {
    val runtimeConfArg: Option[String] = baseRuntimeConfig match {
      case DefaultRuntimeConfig      => None
      case EmptyRuntimeConfig        => Some("COMMON_SIM_ARGS=")
      case CustomRuntimeConfig(path) => Some(s"COMMON_SIM_ARGS=${Source.fromFile(path).getLines.mkString(" ")}")
    }
    val plusArgs                       = Seq(s"""EXTRA_SIM_ARGS=${additionalPlusArgs.mkString(" ")}""")
    val logArg                         = logFile.map { logName => s"LOGFILE=${logName}" }

    val makeArgs =
      runtimeConfArg ++:
        plusArgs ++:
        logArg ++:
        additionalMakeArgs

    it should behaviorSpec.getOrElse("run") in {
      assert(invokeMlSimulator(backend, debug, makeArgs) == 0)
    }
  }

  override def defineTests(backend: String, debug: Boolean): Unit = runTest(backend, debug)
}

class AXI4FuzzerLBPTest extends FASEDTest("AXI4Fuzzer", "DefaultConfig")

// Sanity checks that target output is the same when using the default runtime
// configuration and the hardwired values.
class CheckHardwiredValuesTest extends FASEDTest("AXI4Fuzzer", "NT10e3_AddrBits16_DefaultConfig") {
  override def defineTests(backend: String, debug: Boolean): Unit = {
    val logA = new File(s"$outDir/using-runtime-conf.out")
    runTest(backend, debug, logFile = Some(logA), behaviorSpec = Some("run using a runtime.conf"))

    val logB = new File(s"$outDir/using-hardwired-settings.out")
    runTest(
      backend,
      debug,
      logFile            = Some(logB),
      baseRuntimeConfig  = EmptyRuntimeConfig,
      additionalPlusArgs = Seq("+mm_useHardwareDefaultRuntimeSettings_0"),
      behaviorSpec       = Some("run using initialization values"),
    )

    "Initialization values for configuration registers" should "produce the same target behavior as using the default runtime.conf" in {
      val aLines = extractLines(logA, "AXI4FuzzMaster_0", headerLines = 0)
      val bLines = extractLines(logB, "AXI4FuzzMaster_0", headerLines = 0)
      diffLines(aLines, bLines, logA.getName, logB.getName)
    }
  }
}

class AXI4FuzzerMultiChannelTest extends FASEDTest("AXI4Fuzzer", "FuzzMask3FFF_QuadFuzzer_QuadChannel_DefaultConfig")
class AXI4FuzzerFCFSTest         extends FASEDTest("AXI4Fuzzer", "FCFSConfig")
class AXI4FuzzerFRFCFSTest       extends FASEDTest("AXI4Fuzzer", "FRFCFSConfig")
class AXI4FuzzerLLCDRAMTest      extends FASEDTest("AXI4Fuzzer", "LLCDRAMConfig") {
  //override def runTests = {
  //  // Check that the memory model uses the correct number of MSHRs
  //  val maxMSHRs = targetParams(LlcKey).get.mshrs.max
  //  val runtimeValues = Set((maxMSHRs +: Seq.fill(3)(Random.nextInt(maxMSHRs - 1) + 1)):_*).toSeq
  //  runtimeValues.foreach({ runtimeMSHRs: Int =>
  //    val plusArgs = Seq(s"+mm_llc_activeMSHRs=${runtimeMSHRs}",
  //                   s"+expect_llc_peakMSHRsUsed=${runtimeMSHRs}")
  //    val extraSimArgs = Seq(s"""EXTRA_SIM_ARGS='${plusArgs.mkString(" ")}' """)
  //    runTest("verilator", false, args = extraSimArgs, name = s"correctly execute and use at most ${runtimeMSHRs} MSHRs")
  //   })
  //}
}

// Generate a target memory system that uses the whole host memory system.
class BaselineMultichannelTest
    extends FASEDTest("AXI4Fuzzer", "AddrBits22_QuadFuzzer_DefaultConfig", Seq("AddrBits22_SmallQuadChannelHostConfig"))

// Checks that id-reallocation works for platforms with limited ID space
class NarrowIdConstraint extends FASEDTest("AXI4Fuzzer", "DefaultConfig", Seq("ConstrainedIdHostConfig"))

// Suite Collections for CI
class CIGroupA
    extends Suites(
      new AXI4FuzzerLBPTest,
      new AXI4FuzzerFRFCFSTest,
    )

class CIGroupB
    extends Suites(
      new AXI4FuzzerLLCDRAMTest,
      new NarrowIdConstraint,
    )
