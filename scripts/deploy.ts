import { network } from "hardhat";
import { deployAll } from "./lib/deploy.js";
import { logger } from "./lib/logger.js";

const connection = await network.create();
const result = await deployAll(connection, { networkName: connection.networkName });

logger.info("deployment summary", {
  network: result.record.network,
  chainId: result.record.chainId,
  deployed: result.deployed.length,
  reused: result.reused.length,
  verified: result.verified.length,
  verificationFailures: result.verificationFailures.length,
  file: `deployments/${result.record.network}.json`,
});

if (result.verificationFailures.length > 0) {
  logger.error("some contracts failed verification", { contracts: result.verificationFailures });
  process.exitCode = 1;
}