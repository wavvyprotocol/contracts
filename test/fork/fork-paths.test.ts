import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { encodeAbiParameters, keccak256, parseAbiParameters, toBytes, type Address } from "viem";
import { deployAll, type DeploymentRecord } from "../../scripts/lib/deploy.js";
import { seedAll } from "../../scripts/lib/seed.js";

/// Fork tests run against the Monad mainnet fork and exercise the oracle
/// update and liquidation paths on a full deployment. They need network access
/// through FORK_RPC_URL; without it they are skipped with this reason.
const skipReason = process.env.FORK_RPC_URL ? false : "FORK_RPC_URL is not set";

describe("monad fork paths", { skip: skipReason }, async function () {
  const connection = await network.create("hardhatFork");
  const publicClient = await connection.viem.getPublicClient();
  const wallets = await connection.viem.getWalletClients();
  const [, reporterWallet, traderWallet, whaleWallet, liquidatorWallet] = wallets;
  const deploymentsDir = mkdtempSync(join(tmpdir(), "wavvy-fork-"));

  const metricId = keccak256(toBytes("tiktok:fork-creator:followers"));
  const creatorId = keccak256(toBytes("tiktok:fork-creator"));

  const seedConfig = {
    typeDefaults: [
      {
        marketType: 0,
        params: {
          maxLeverage: "3000000000000000000",
          minMargin: "10000000000000000000",
          openInterestCap: "1000000000000000000000000",
          maintenanceMarginBps: 1000,
          liquidationPenaltyBps: 250,
          liquidatorShareBps: 6000,
          tradingFeeBps: 10,
          markDeviationPauseBps: 500,
          fundingCoefficient: "1000000000000000000",
          maxFundingRatePerBlock: "1000000000000000",
          creatorShareBps: 3000,
          copyFeeBps: 500,
          curatorShareBps: 5000,
        },
      },
    ],
    metrics: [
      {
        metricId,
        heartbeat: 3600,
        twapWindow: 120,
        minTwapWindow: 60,
        maxDeviationBps: 500,
        circuitBreakerBps: 2000,
      },
    ],
    configureMarkets: [{ marketId: 1, marketType: 0 }],
    markets: [
      {
        marketId: 1,
        marketType: 0,
        metricId,
        creatorIds: [creatorId],
        initialPrice: "1000000000000000000000",
        virtualDepth: "1000000000000000000000",
      },
    ],
    grants: [
      { contract: "WavvyOracle", role: "CRE_REPORTER_ROLE", account: reporterWallet.account.address },
      { contract: "MockUSDC", role: "MINTER_ROLE", account: traderWallet.account.address },
      { contract: "MockUSDC", role: "MINTER_ROLE", account: whaleWallet.account.address },
    ],
    creForwarder: reporterWallet.account.address,
  };

  let record: DeploymentRecord;

  it("deploys the stack and seeds oracles, risk, and a market through the timelock", async function () {
    const seedPath = join(deploymentsDir, "seed.json");
    writeFileSync(seedPath, `${JSON.stringify(seedConfig, null, 2)}\n`);

    const deploy = await deployAll(connection, {
      networkName: "hardhatFork",
      deploymentsDir,
      delayMs: 0,
      verify: false,
      quiet: true,
    });
    record = deploy.record;
    assert.equal(deploy.deployed.length, 13);
    assert.equal(record.adminRenounced, true);

    await seedAll(connection, {
      networkName: "hardhatFork",
      configPath: seedPath,
      statePath: join(deploymentsDir, "seed-state.json"),
      delaySeconds: Number(await (await connection.viem.getContractAt("WavvyTimelock", record.timelock as Address)).read.getMinDelay()),
      wait: true,
    });

    const oracle = await connection.viem.getContractAt("WavvyOracle", record.contracts.WavvyOracle as Address);
    assert.equal(
      String(await oracle.read.creForwarder()).toLowerCase(),
      reporterWallet.account.address.toLowerCase(),
    );

    const factory = await connection.viem.getContractAt("WavvyFactory", record.contracts.WavvyFactory as Address);
    assert.equal(await factory.read.marketExists([1n]), true);

    const amm = await connection.viem.getContractAt("WavvyAMM", record.contracts.WavvyAMM as Address);
    assert.equal(await amm.read.marketExists([1n]), true);
  });

  it("oracle update path: reports move the value and the TWAP", async function () {
    const oracle = await connection.viem.getContractAt("WavvyOracle", record.contracts.WavvyOracle as Address);
    const first = await publicClient.getBlock({ blockTag: "latest" });

    await oracle.write.onReport(["0x", encodeReport(metricId, 1_000n * 10n ** 18n, first.timestamp)], {
      account: reporterWallet.account,
    });

    // Advance the simulated chain far enough for the TWAP window to be valid.
    const testClient = await connection.viem.getTestClient();
    await testClient.increaseTime({ seconds: 120 });
    await testClient.mine({ blocks: 1 });
    const second = await publicClient.getBlock({ blockTag: "latest" });

    await oracle.write.onReport(["0x", encodeReport(metricId, 1_000n * 10n ** 18n, second.timestamp)], {
      account: reporterWallet.account,
    });

    assert.equal(await oracle.read.latestValue([metricId]), 1_000n * 10n ** 18n);
    assert.equal(await oracle.read.isFresh([metricId]), true);
    assert.equal(await oracle.read.lastUpdateAt([metricId]), second.timestamp);
    assert.equal(await oracle.read.getTWAP([metricId]), 1_000n * 10n ** 18n);
  });

  it("liquidation path: an underwater position is liquidated onchain", async function () {
    const house = await connection.viem.getContractAt("WavvyHouse", record.contracts.WavvyHouse as Address);
    const vault = await connection.viem.getContractAt("WavvyVault", record.contracts.WavvyVault as Address);
    const position = await connection.viem.getContractAt("WavvyPosition", record.contracts.WavvyPosition as Address);
    const usdc = await connection.viem.getContractAt("MockUSDC", record.contracts.MockUSDC as Address);
    const amm = await connection.viem.getContractAt("WavvyAMM", record.contracts.WavvyAMM as Address);

    const trader = traderWallet.account.address;
    const whale = whaleWallet.account.address;

    for (const [wallet, amount] of [
      [traderWallet, 10_000n * 10n ** 18n],
      [whaleWallet, 200_000n * 10n ** 18n],
    ] as const) {
      await usdc.write.mint([wallet.account.address, amount], { account: wallet.account });
      await usdc.write.approve([record.contracts.WavvyVault as Address, amount], { account: wallet.account });
      await vault.write.deposit([amount], { account: wallet.account });
    }

    await house.write.openPosition([1n, true, 100n * 10n ** 18n, 3n * 10n ** 18n, 0n], {
      account: traderWallet.account,
    });
    await house.write.openPosition([1n, false, 150_000n * 10n ** 18n, 3n * 10n ** 18n, 0n], {
      account: whaleWallet.account,
    });

    // The index follows the mark, so the liquidation runs inside the band.
    const mark = (await amm.read.markPrice([1n])) as bigint;
    const block = await publicClient.getBlock({ blockTag: "latest" });
    const oracle = await connection.viem.getContractAt("WavvyOracle", record.contracts.WavvyOracle as Address);
    await oracle.write.onReport(["0x", encodeReport(metricId, mark, block.timestamp)], {
      account: reporterWallet.account,
    });

    const marginBefore = await position.read.totalMargin();
    assert.ok(marginBefore > 0n);

    await house.write.liquidate([1n], { account: liquidatorWallet.account });

    const marginAfter = await position.read.totalMargin();
    assert.ok(marginAfter < marginBefore, "liquidation must reduce open margin");

    const vaultBacking = await vault.read.totalBacking();
    const totalBalances = await vault.read.totalBalances();
    assert.ok(vaultBacking >= totalBalances, "vault backing invariant");
  });
});

function encodeReport(metricId: `0x${string}`, value: bigint, observedAt: bigint): `0x${string}` {
  return encodeAbiParameters(parseAbiParameters("bytes32 metricId, uint256 value, uint64 observedAt, uint8 status"), [
    metricId,
    value,
    observedAt,
    0,
  ]);
}