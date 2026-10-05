import hre from "hardhat";
import type { NetworkConnection } from "hardhat/types/network";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { verifyContract } from "@nomicfoundation/hardhat-verify/verify";
import { logger } from "./logger.js";

export type DeploymentRecord = {
  network: string;
  chainId: number;
  treasury: string;
  grantsPool: string;
  timelock: string;
  timelockDelay: number;
  timelockProposer: string;
  adminRenounced: boolean;
  riskSeeded: boolean;
  contracts: Record<string, string>;
  updatedAt: string;
};

export type DeployOptions = {
  networkName: string;
  deploymentsDir?: string;
  delayMs?: number;
  verify?: boolean;
  quiet?: boolean;
};

export type DeployResult = {
  record: DeploymentRecord;
  deployed: string[];
  reused: string[];
  verified: string[];
  verificationFailures: string[];
};

const DEPLOY_ORDER = [
  "MockUSDC",
  "WavvyRiskManager",
  "WavvyOracle",
  "WavvyIndexOracle",
  "WavvyVault",
  "WavvyAMM",
  "WavvyHouse",
  "WavvyPosition",
  "WavvyInsurance",
  "WavvyFactory",
  "WavvyCreatorRewards",
  "WavvyCurator",
  "WavvyTimelock",
] as const;

type ContractName = (typeof DEPLOY_ORDER)[number];

const SOURCES: Record<ContractName, string> = {
  MockUSDC: "contracts/mocks/MockUSDC.sol:MockUSDC",
  WavvyRiskManager: "contracts/risk/WavvyRiskManager.sol:WavvyRiskManager",
  WavvyOracle: "contracts/oracle/WavvyOracle.sol:WavvyOracle",
  WavvyIndexOracle: "contracts/oracle/WavvyIndexOracle.sol:WavvyIndexOracle",
  WavvyVault: "contracts/core/WavvyVault.sol:WavvyVault",
  WavvyAMM: "contracts/core/WavvyAMM.sol:WavvyAMM",
  WavvyHouse: "contracts/core/WavvyHouse.sol:WavvyHouse",
  WavvyPosition: "contracts/core/WavvyPosition.sol:WavvyPosition",
  WavvyInsurance: "contracts/core/WavvyInsurance.sol:WavvyInsurance",
  WavvyFactory: "contracts/core/WavvyFactory.sol:WavvyFactory",
  WavvyCreatorRewards: "contracts/core/WavvyCreatorRewards.sol:WavvyCreatorRewards",
  WavvyCurator: "contracts/core/WavvyCurator.sol:WavvyCurator",
  WavvyTimelock: "contracts/governance/WavvyTimelock.sol:WavvyTimelock",
};

const ADMIN_HANDOVER_TARGETS: ContractName[] = [
  "MockUSDC",
  "WavvyRiskManager",
  "WavvyOracle",
  "WavvyIndexOracle",
  "WavvyVault",
  "WavvyAMM",
  "WavvyHouse",
  "WavvyPosition",
  "WavvyInsurance",
  "WavvyFactory",
  "WavvyCreatorRewards",
  "WavvyCurator",
  "WavvyTimelock",
];

const DEFAULT_TIMELOCK_DELAY_SECONDS = 3600;
const DEFAULT_DEPLOY_DELAY_MS = 1500;

async function pause(ms: number): Promise<void> {
  if (ms <= 0) {
    return;
  }
  const { promise, resolve } = Promise.withResolvers<void>();
  setTimeout(resolve, ms);
  await promise;
}

type LooseContract = {
  address: `0x${string}`;
  read: Record<string, (...args: unknown[]) => Promise<unknown>>;
  write: Record<string, (...args: unknown[]) => Promise<`0x${string}`>>;
  deploymentTransaction?: () => { hash: `0x${string}` } | null;
};

export async function deployAll(
  connection: NetworkConnection,
  options: DeployOptions,
): Promise<DeployResult> {
  const quiet = options.quiet ?? false;
  const envDelayMs = process.env.DEPLOY_DELAY_MS;
  const delayMs = options.delayMs ?? (envDelayMs ? Number(envDelayMs) : DEFAULT_DEPLOY_DELAY_MS);
  const deploymentsDir = options.deploymentsDir ?? "deployments";
  const recordPath = join(deploymentsDir, `${options.networkName}.json`);

  const log = {
    error: (msg: string, ctx?: Record<string, unknown>) => {
      if (!quiet) logger.error(msg, ctx);
    },
    success: (msg: string, ctx?: Record<string, unknown>) => {
      if (!quiet) logger.success(msg, ctx);
    },
    info: (msg: string, ctx?: Record<string, unknown>) => {
      if (!quiet) logger.info(msg, ctx);
    },
    debug: (msg: string, ctx?: Record<string, unknown>) => {
      if (!quiet) logger.debug(msg, ctx);
    },
  };

  const { viem } = connection;
  const publicClient = await viem.getPublicClient();
  const [walletClient] = await viem.getWalletClients();
  const deployer = walletClient.account.address;

  mkdirSync(deploymentsDir, { recursive: true });

  const existing: DeploymentRecord | null = existsSync(recordPath)
    ? (JSON.parse(readFileSync(recordPath, "utf8")) as DeploymentRecord)
    : null;

  const chainId = await publicClient.getChainId();
  const configuredDelay = Number(process.env.TIMELOCK_DELAY_SECONDS);
  const mainnetLike = /mainnet/i.test(options.networkName);
  if (
    mainnetLike
      && !(Number.isFinite(configuredDelay) && configuredDelay >= 86_400 && configuredDelay <= 172_800)
  ) {
    throw new Error(
      "mainnet deployments require TIMELOCK_DELAY_SECONDS between 86400 and 172800 seconds (24 to 48 hours)",
    );
  }
  const timelockDelay =
    Number.isFinite(configuredDelay) && configuredDelay > 0 ? configuredDelay : DEFAULT_TIMELOCK_DELAY_SECONDS;
  const record: DeploymentRecord = existing ?? {
    network: options.networkName,
    chainId,
    treasury: process.env.TREASURY_ADDRESS ?? deployer,
    grantsPool: process.env.GRANTS_POOL_ADDRESS ?? deployer,
    timelock: "",
    timelockDelay,
    timelockProposer: process.env.TIMELOCK_PROPOSER ?? deployer,
    adminRenounced: false,
    riskSeeded: false,
    contracts: {},
    updatedAt: new Date().toISOString(),
  };

  if (!existing && timelockDelay !== configuredDelay) {
    log.info("TIMELOCK_DELAY_SECONDS is not a positive number; using the default delay", { timelockDelay });
  }
  if (!existing && record.treasury === deployer) {
    log.info("treasury defaults to the deployer; set TREASURY_ADDRESS for a real deployment");
  }
  if (existing && existing.chainId !== chainId) {
    throw new Error(`deployment file chainId ${existing.chainId} does not match network ${chainId}`);
  }

  const writeRecord = (): void => {
    record.updatedAt = new Date().toISOString();
    writeFileSync(recordPath, `${JSON.stringify(record, null, 2)}\n`);
  };

  const deployed: string[] = [];
  const reused: string[] = [];

  const contractAt = async (name: ContractName): Promise<LooseContract> =>
    (await connection.viem.getContractAt(name, record.contracts[name] as `0x${string}`)) as unknown as LooseContract;

  const argsFor = (name: ContractName): unknown[] => {
    const c = record.contracts;
    switch (name) {
      case "MockUSDC":
        return [deployer];
      case "WavvyRiskManager":
        return [deployer];
      case "WavvyOracle":
        return [deployer];
      case "WavvyIndexOracle":
        return [c.WavvyOracle, deployer];
      case "WavvyVault":
        return [c.MockUSDC, deployer];
      case "WavvyAMM":
        return [c.WavvyRiskManager, deployer];
      case "WavvyHouse":
        return [c.WavvyVault, c.WavvyAMM, c.WavvyOracle, c.WavvyIndexOracle, record.treasury, deployer];
      case "WavvyPosition":
        return [deployer];
      case "WavvyInsurance":
        return [c.WavvyVault, deployer];
      case "WavvyFactory":
        return [c.WavvyAMM, c.WavvyHouse, deployer];
      case "WavvyCreatorRewards":
        return [c.WavvyVault, record.grantsPool, deployer];
      case "WavvyCurator":
        return [c.WavvyVault, deployer];
      case "WavvyTimelock":
        return [record.timelockDelay, [record.timelockProposer], ["0x0000000000000000000000000000000000000000"], deployer];
    }
  };

  const artifactNames = await hre.artifacts.getAllFullyQualifiedNames();
  for (const library of ["WavvyMath", "TWAPLib", "FundingLib"]) {
    let linked = false;
    for (const name of artifactNames) {
      const artifact = await hre.artifacts.readArtifact(name);
      if (JSON.stringify(artifact.linkReferences).includes(library)) {
        linked = true;
        break;
      }
    }
    if (linked) {
      throw new Error(`library ${library} is linked by a consumer; add it to the deploy order`);
    }
    log.info("library is internal with no linked consumers; nothing to deploy", { library });
  }

  const send = async (label: string, tx: Promise<`0x${string}`>): Promise<void> => {
    const hash = await tx;
    await publicClient.waitForTransactionReceipt({ hash });
    log.success(`${label} confirmed`, { tx: hash });
    await pause(delayMs);
  };

  const hasCode = async (address: string): Promise<boolean> => {
    const code = await publicClient.getBytecode({ address: address as `0x${string}` });
    return code !== undefined && code !== "0x";
  };

  // Deploy (or reuse) every contract in order.
  for (const name of DEPLOY_ORDER) {
    const address = record.contracts[name];
    if (address && (await hasCode(address))) {
      log.info("reusing existing deployment", { contract: name, address });
      reused.push(name);
      continue;
    }
    const args = argsFor(name);
    const instance = (await viem.deployContract(name, args as never)) as unknown as LooseContract;
    const txHash = instance.deploymentTransaction?.()?.hash;
    if (txHash) {
      const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
      if (receipt.status !== "success") {
        throw new Error(`deployment transaction for ${name} reverted`);
      }
    }
    record.contracts[name] = instance.address;
    if (name === "WavvyTimelock") {
      record.timelock = instance.address;
    }
    deployed.push(name);
    writeRecord();
    log.success("deployed", { contract: name, address: instance.address, tx: txHash });
    await pause(delayMs);
  }

  // Wire the house to its collaborators. Idempotent: skipped when already set.
  const house = await contractAt("WavvyHouse");
  const wiredPosition = (await house.read.position()) as string;
  if (wiredPosition.toLowerCase() !== record.contracts.WavvyPosition.toLowerCase()) {
    await send(
      "house.setSystem",
      house.write.setSystem([
        record.contracts.WavvyPosition,
        record.contracts.WavvyRiskManager,
        record.contracts.WavvyInsurance,
        record.contracts.WavvyFactory,
        record.contracts.WavvyCreatorRewards,
        record.contracts.WavvyCurator,
      ]),
    );
  } else {
    log.debug("house already wired");
  }

  const grantRole = async (contractName: ContractName, roleName: string, account: string): Promise<void> => {
    const contract = await contractAt(contractName);
    const role = (await contract.read[roleName]()) as `0x${string}`;
    const has = (await contract.read.hasRole([role, account])) as boolean;
    if (has) {
      log.debug("role already granted", { contract: contractName, role: roleName, account });
      return;
    }
    await send(`${contractName}.grantRole(${roleName})`, contract.write.grantRole([role, account]));
  };

  // Operational wiring. Contract-to-contract roles first.
  await grantRole("WavvyVault", "HOUSE_ROLE", record.contracts.WavvyHouse);
  await grantRole("WavvyVault", "SYSTEM_ROLE", record.contracts.WavvyCurator);
  await grantRole("WavvyAMM", "HOUSE_ROLE", record.contracts.WavvyHouse);
  await grantRole("WavvyAMM", "MARKET_ADMIN_ROLE", record.contracts.WavvyFactory);
  await grantRole("WavvyHouse", "MARKET_ADMIN_ROLE", record.contracts.WavvyFactory);
  await grantRole("WavvyPosition", "HOUSE_ROLE", record.contracts.WavvyHouse);
  await grantRole("WavvyInsurance", "HOUSE_ROLE", record.contracts.WavvyHouse);
  await grantRole("WavvyCreatorRewards", "HOUSE_ROLE", record.contracts.WavvyHouse);
  await grantRole("WavvyCurator", "HOUSE_ROLE", record.contracts.WavvyHouse);

  // Governance: market creation after handover runs through the timelock.
  await grantRole("WavvyFactory", "MARKET_ADMIN_ROLE", record.timelock);
  await grantRole("MockUSDC", "MINTER_ROLE", record.timelock);

  // Optional operational addresses from the environment.
  const optionalRoles: Array<[ContractName, string, string | undefined, string]> = [
    ["WavvyOracle", "CRE_REPORTER_ROLE", process.env.CRE_REPORTER_ADDRESS, "granted once the CRE forwarder is known"],
    ["WavvyOracle", "FALLBACK_KEEPER_ROLE", process.env.FALLBACK_KEEPER_ADDRESS, "granted once the fallback keeper wallet is known"],
    ["WavvyRiskManager", "PAUSER_ROLE", process.env.PAUSER_ADDRESS, "granted once the pauser wallet is known"],
    ["MockUSDC", "MINTER_ROLE", process.env.MOCK_USDC_MINTER, "granted once the test USDC minter is known"],
  ];
  for (const [contractName, roleName, account, note] of optionalRoles) {
    if (account) {
      await grantRole(contractName, roleName, account);
    } else {
      log.info(`${roleName} not granted; ${note}`, { contract: contractName });
    }
  }

  // Pin the CRE forwarder and workflow rule when configured, so a live deployment only accepts reports from the expected workflow.
  const forwarder = process.env.CRE_REPORTER_ADDRESS;
  if (forwarder) {
    const oracleContract = await contractAt("WavvyOracle");
    const current = (await oracleContract.read.creForwarder()) as string;
    if (current.toLowerCase() !== forwarder.toLowerCase()) {
      await send("WavvyOracle.setCreForwarder", oracleContract.write.setCreForwarder([forwarder]));
    }
  }
  const workflowId = process.env.CRE_WORKFLOW_ID;
  const workflowName = process.env.CRE_WORKFLOW_NAME;
  const workflowOwner = process.env.CRE_WORKFLOW_OWNER;
  if (workflowId && workflowName && workflowOwner) {
    const oracleContract = await contractAt("WavvyOracle");
    const nameHex = Buffer.from(workflowName, "utf8").toString("hex").slice(0, 20).padEnd(20, "0");
    await send(
      "WavvyOracle.setWorkflowRule",
      oracleContract.write.setWorkflowRule([workflowId, `0x${nameHex}`, workflowOwner]),
    );
  }

  if (!record.riskSeeded) {
    const fundingCoefficient = process.env.RISK_FUNDING_COEFFICIENT;
    const maxFundingRatePerBlock = process.env.RISK_MAX_FUNDING_RATE_PER_BLOCK;
    const openInterestCap = process.env.RISK_OI_CAP;
    if (fundingCoefficient && maxFundingRatePerBlock && openInterestCap) {
      const risk = await contractAt("WavvyRiskManager");
      const params = (maxLeverage: bigint) => ({
        maxLeverage,
        minMargin: BigInt(process.env.RISK_MIN_MARGIN ?? "10000000000000000000"),
        openInterestCap: BigInt(openInterestCap),
        maintenanceMarginBps: 1000n,
        liquidationPenaltyBps: 250n,
        liquidatorShareBps: 6000n,
        tradingFeeBps: 10n,
        markDeviationPauseBps: 500n,
        fundingCoefficient: BigInt(fundingCoefficient),
        maxFundingRatePerBlock: BigInt(maxFundingRatePerBlock),
        creatorShareBps: 3000n,
        copyFeeBps: 500n,
        curatorShareBps: 5000n,
      });
      await send("risk.setTypeDefaults(single-name)", risk.write.setTypeDefaults([0, params(3n * 10n ** 18n)]));
      await send("risk.setTypeDefaults(index)", risk.write.setTypeDefaults([1, params(5n * 10n ** 18n)]));
      record.riskSeeded = true;
      writeRecord();
    } else {
      log.info("risk type defaults not seeded; set RISK_FUNDING_COEFFICIENT, RISK_MAX_FUNDING_RATE_PER_BLOCK and RISK_OI_CAP to seed them");
    }
  }

  // Handover: every admin role moves to the timelock, the deployer renounces.
  if (!record.adminRenounced) {
    const timelock = record.timelock;
    for (const name of ADMIN_HANDOVER_TARGETS) {
      const contract = await contractAt(name);
      const adminRole = (await contract.read.DEFAULT_ADMIN_ROLE()) as `0x${string}`;
      const deployerIsAdmin = (await contract.read.hasRole([adminRole, deployer])) as boolean;
      if (!deployerIsAdmin) {
        log.debug("deployer already renounced", { contract: name });
        continue;
      }
      if (name === "WavvyTimelock") {
        await send("WavvyTimelock.renounceRole(DEFAULT_ADMIN_ROLE)", contract.write.renounceRole([adminRole, deployer]));
        continue;
      }
      await send(`${name}.grantRole(DEFAULT_ADMIN_ROLE -> timelock)`, contract.write.grantRole([adminRole, timelock]));
      await send(`${name}.renounceRole(DEFAULT_ADMIN_ROLE)`, contract.write.renounceRole([adminRole, deployer]));
    }
    record.adminRenounced = true;
    writeRecord();
  } else {
    log.debug("admin handover already complete");
  }

  writeRecord();

  const verified: string[] = [];
  const verificationFailures: string[] = [];
  const networkConfig = (hre.config.networks as Record<string, { type?: string } | undefined>)[
    connection.networkName
  ];
  const networkIsLive = networkConfig?.type === "http";
  const shouldVerify = (options.verify ?? true) && networkIsLive;
  if (!shouldVerify) {
    log.info("verification skipped", {
      reason: options.verify === false ? "disabled" : "not a live network",
      network: connection.networkName,
    });
  } else if (!process.env.ETHERSCAN_API_KEY) {
    log.info("verification skipped; ETHERSCAN_API_KEY is not set");
  } else {
    for (const name of DEPLOY_ORDER) {
      const address = record.contracts[name];
      log.info("verifying", { contract: name, address });
      try {
        const ok = await verifyContract(
          { address, constructorArgs: argsFor(name), contract: SOURCES[name] },
          hre,
        );
        if (ok) {
          verified.push(name);
          log.success("verified", { contract: name, address });
        } else {
          verificationFailures.push(name);
          log.error("verification returned false", { contract: name, address });
        }
      } catch (error) {
        verificationFailures.push(name);
        log.error("verification failed", {
          contract: name,
          address,
          reason: error instanceof Error ? error.message : String(error),
        });
      }
    }
  }

  return { record, deployed, reused, verified, verificationFailures };
}