import { readFileSync, existsSync, writeFileSync } from "node:fs";
import hre from "hardhat";
import { encodeFunctionData, keccak256, toBytes, type Abi, type Address } from "viem";
import type { NetworkConnection } from "hardhat/types/network";
import { logger } from "./logger.js";

type MetricConfig = {
  metricId: `0x${string}`;
  heartbeat: number;
  twapWindow: number;
  minTwapWindow: number;
  maxDeviationBps: number;
  circuitBreakerBps: number;
};

type MarketConfig = {
  marketId: number;
  marketType: number;
  metricId: `0x${string}`;
  creatorIds: `0x${string}`[];
  initialPrice: string;
  virtualDepth: string;
};

type IndexMarketConfig = {
  marketId: number;
  metricIds: `0x${string}`[];
  baselines: string[];
};

type RiskParamsConfig = {
  maxLeverage: string;
  minMargin: string;
  openInterestCap: string;
  maintenanceMarginBps: number;
  liquidationPenaltyBps: number;
  liquidatorShareBps: number;
  tradingFeeBps: number;
  markDeviationPauseBps: number;
  fundingCoefficient: string;
  maxFundingRatePerBlock: string;
  creatorShareBps: number;
  copyFeeBps: number;
  curatorShareBps: number;
};

type TypeDefaultsConfig = { marketType: number; params: RiskParamsConfig };

type GrantConfig = {
  contract: "WavvyOracle" | "MockUSDC";
  role: "CRE_REPORTER_ROLE" | "FALLBACK_KEEPER_ROLE" | "MINTER_ROLE";
  account: `0x${string}`;
};

type SeedConfig = {
  typeDefaults?: TypeDefaultsConfig[];
  metrics?: MetricConfig[];
  markets?: MarketConfig[];
  configureMarkets?: Array<{ marketId: number; marketType: number }>;
  indexMarkets?: IndexMarketConfig[];
  grants?: GrantConfig[];
  creForwarder?: `0x${string}`;
};

type SeedOperation = {
  label: string;
  target: Address;
  data: `0x${string}`;
  salt: `0x${string}`;
  operationId?: `0x${string}`;
  readyAt?: number;
  status: "planned" | "scheduled" | "executed";
};

const sleep = async (seconds: number): Promise<void> => {
  const { promise, resolve } = Promise.withResolvers<void>();
  setTimeout(resolve, seconds * 1000);
  await promise;
};

function loadDeployment(networkName: string): { contracts: Record<string, string>; timelock: string } {
  const path = `deployments/${networkName}.json`;
  if (!existsSync(path)) {
    throw new Error(`no deployment record at ${path}; run scripts/deploy.ts first`);
  }
  return JSON.parse(readFileSync(path, "utf8"));
}


export type SeedOptions = {
  networkName?: string;
  configPath?: string;
  delaySeconds?: number;
  execute?: boolean;
  wait?: boolean;
  /** State file path, default deployments/<network>-seed.json. */
  statePath?: string;
};

export async function seedAll(connection: NetworkConnection, options: SeedOptions): Promise<void> {
  const publicClient = await connection.viem.getPublicClient();
  const [wallet] = await connection.viem.getWalletClients();
  const networkName = options.networkName ?? connection.networkName;
  const networkType = (hre.config.networks as Record<string, { type?: string } | undefined>)[networkName]?.type;
  const simulated = networkType === "edr-simulated";

  const deployment = loadDeployment(networkName);
  const configPath = options.configPath ?? `seed/${networkName}.json`;
  if (!existsSync(configPath)) {
    throw new Error(`no seed config at ${configPath}; copy seed/example.json and edit it`);
  }
  const config = JSON.parse(readFileSync(configPath, "utf8")) as SeedConfig;

  const oracleAbi = (await hre.artifacts.readArtifact("WavvyOracle")).abi as Abi;
  const factoryAbi = (await hre.artifacts.readArtifact("WavvyFactory")).abi as Abi;
  const indexOracleAbi = (await hre.artifacts.readArtifact("WavvyIndexOracle")).abi as Abi;
  const riskAbi = (await hre.artifacts.readArtifact("WavvyRiskManager")).abi as Abi;

  const operations: SeedOperation[] = [];
  const add = (label: string, target: string, abi: Abi, functionName: string, args: unknown[]): void => {
    operations.push({
      label,
      target: target as Address,
      data: encodeFunctionData({ abi, functionName, args }),
      salt: keccak256(toBytes(label)),
      status: "planned",
    });
  };

  for (const defaults of config.typeDefaults ?? []) {
    const p = defaults.params;
    add(`setTypeDefaults ${defaults.marketType}`, deployment.contracts.WavvyRiskManager, riskAbi, "setTypeDefaults", [
      defaults.marketType,
      {
        maxLeverage: BigInt(p.maxLeverage),
        minMargin: BigInt(p.minMargin),
        openInterestCap: BigInt(p.openInterestCap),
        maintenanceMarginBps: BigInt(p.maintenanceMarginBps),
        liquidationPenaltyBps: BigInt(p.liquidationPenaltyBps),
        liquidatorShareBps: BigInt(p.liquidatorShareBps),
        tradingFeeBps: BigInt(p.tradingFeeBps),
        markDeviationPauseBps: BigInt(p.markDeviationPauseBps),
        fundingCoefficient: BigInt(p.fundingCoefficient),
        maxFundingRatePerBlock: BigInt(p.maxFundingRatePerBlock),
        creatorShareBps: BigInt(p.creatorShareBps),
        copyFeeBps: BigInt(p.copyFeeBps),
        curatorShareBps: BigInt(p.curatorShareBps),
      },
    ]);
  }
  for (const metric of config.metrics ?? []) {
    add(`registerMetric ${metric.metricId}`, deployment.contracts.WavvyOracle, oracleAbi, "registerMetric", [
      metric.metricId,
      BigInt(metric.heartbeat),
      BigInt(metric.twapWindow),
      BigInt(metric.minTwapWindow),
      metric.maxDeviationBps,
      metric.circuitBreakerBps,
    ]);
  }
  for (const market of config.configureMarkets ?? []) {
    add(`configureMarket ${market.marketId}`, deployment.contracts.WavvyRiskManager, riskAbi, "configureMarket", [
      BigInt(market.marketId),
      market.marketType,
    ]);
  }
  for (const market of config.markets ?? []) {
    add(`createMarket ${market.marketId}`, deployment.contracts.WavvyFactory, factoryAbi, "createMarket", [
      BigInt(market.marketId),
      market.marketType,
      market.metricId,
      market.creatorIds,
      BigInt(market.initialPrice),
      BigInt(market.virtualDepth),
    ]);
  }
  for (const indexMarket of config.indexMarkets ?? []) {
    add(
      `registerIndexMarket ${indexMarket.marketId}`,
      deployment.contracts.WavvyIndexOracle,
      indexOracleAbi,
      "registerIndexMarket",
      [BigInt(indexMarket.marketId), indexMarket.metricIds, indexMarket.baselines.map((b) => BigInt(b))],
    );
  }

  for (const grant of config.grants ?? []) {
    const abi = grant.contract === "WavvyOracle" ? oracleAbi : (await hre.artifacts.readArtifact("MockUSDC")).abi as Abi;
    const contract = (await connection.viem.getContractAt(
      grant.contract,
      deployment.contracts[grant.contract] as Address,
    )) as unknown as { read: Record<string, () => Promise<unknown>> };
    const role = (await contract.read[grant.role]()) as `0x${string}`;
    add(`grant ${grant.role} to ${grant.account}`, deployment.contracts[grant.contract], abi, "grantRole", [
      role,
      grant.account,
    ]);
  }
  if (config.creForwarder) {
    add("setCreForwarder", deployment.contracts.WavvyOracle, oracleAbi, "setCreForwarder", [config.creForwarder]);
  }

  const statePath = options.statePath ?? `deployments/${networkName}-seed.json`;
  // A simulated chain resets between runs, so recorded progress does not apply:
  // starting from an empty state keeps a fresh fork consistent.
  const state: { operations: SeedOperation[] } = !simulated && existsSync(statePath)
    ? JSON.parse(readFileSync(statePath, "utf8"))
    : { operations: [] };

  const timelock = await connection.viem.getContractAt("WavvyTimelock", deployment.timelock as Address);
  const proposer = wallet.account;

  const minDelay = Number(await timelock.read.getMinDelay());
  const scheduleDelay = BigInt(options.delaySeconds ?? minDelay);
  const executeMode = options.execute === true || options.wait === true;
  const waitMode = options.wait === true;
  const zero = "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`;

  for (const operation of operations) {
    const existing = state.operations.find((o) => o.label === operation.label);
    if (existing?.status === "executed") {
      logger.info("already executed", { label: operation.label });
      continue;
    }
    if (!existing?.operationId) {
      // Schedule.
      const hash = await timelock.write.schedule(
        [operation.target, 0n, operation.data, zero, operation.salt, scheduleDelay],
        { account: proposer },
      );
      await publicClient.waitForTransactionReceipt({ hash });
      const operationId = await timelock.read.hashOperation([
        operation.target,
        0n,
        operation.data,
        zero,
        operation.salt,
      ]);
      operation.operationId = operationId;
      const block = await publicClient.getBlock({ blockTag: "latest" });
      operation.readyAt = Number(block.timestamp) + Number(scheduleDelay);
      operation.status = "scheduled";
      state.operations = [...state.operations.filter((o) => o.label !== operation.label), operation];
      writeFileSync(statePath, `${JSON.stringify(state, null, 2)}\n`);
      logger.success("scheduled", { label: operation.label, tx: hash, operationId });
      continue;
    }

    operation.status = existing.status;
    operation.readyAt = existing.readyAt;
  }

  if (!executeMode && !waitMode) {
    logger.info("scheduling complete; run with SEED_EXECUTE=true after the timelock delay", { statePath });
    return;
  }

  for (const operation of state.operations) {
    if (operation.status === "executed") continue;
    const now = Number((await publicClient.getBlock({ blockTag: "latest" })).timestamp);
    const readyAt = operation.readyAt ?? 0;
    if (now < readyAt) {
      if (!waitMode) {
        logger.info("not ready yet", { label: operation.label, readyAt, now });
        continue;
      }
      const delta = readyAt - now + 1;
      if (simulated) {
        const testClient = await connection.viem.getTestClient();
        await testClient.increaseTime({ seconds: delta });
        await testClient.mine({ blocks: 1 });
      } else {
        await sleep(delta);
      }
    }
    const hash = await timelock.write.execute([operation.target, 0n, operation.data, zero, operation.salt], {
      account: proposer,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") {
      logger.error("execute reverted", { label: operation.label, tx: hash });
      process.exitCode = 1;
      continue;
    }
    operation.status = "executed";
    writeFileSync(statePath, `${JSON.stringify(state, null, 2)}\n`);
    logger.success("executed", { label: operation.label, tx: hash });
  }

  logger.info("seed complete", { statePath });
}
