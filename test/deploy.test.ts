import assert from "node:assert/strict";
import { readFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { deployAll, type DeployResult } from "../scripts/lib/deploy.js";

const CONTRACT_NAMES = [
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

describe("deploy script", async function () {
  const connection = await network.create();
  const deploymentsDir = mkdtempSync(join(tmpdir(), "wavvy-deploy-"));
  const options = {
    networkName: "test-network",
    deploymentsDir,
    delayMs: 0,
    verify: false,
    quiet: true,
  };
  let first: DeployResult;

  it("deploys every contract and writes a complete deployment file", async function () {
    first = await deployAll(connection, options);

    assert.deepEqual(first.reused, []);
    assert.deepEqual([...first.deployed].sort(), [...CONTRACT_NAMES].sort());
    assert.equal(first.record.adminRenounced, true);
    assert.match(first.record.timelock, /^0x[0-9a-fA-F]{40}$/);

    for (const name of CONTRACT_NAMES) {
      assert.match(first.record.contracts[name], /^0x[0-9a-fA-F]{40}$/, name);
    }

    const file = JSON.parse(readFileSync(join(deploymentsDir, "test-network.json"), "utf8"));
    assert.equal(file.chainId, first.record.chainId);
    assert.equal(file.timelock, first.record.timelock);
    for (const name of CONTRACT_NAMES) {
      assert.equal(file.contracts[name], first.record.contracts[name], name);
    }
  });

  it("is idempotent: a second run reuses every address", async function () {
    const second = await deployAll(connection, options);

    assert.deepEqual(second.deployed, []);
    assert.deepEqual([...second.reused].sort(), [...CONTRACT_NAMES].sort());
    assert.equal(second.record.timelock, first.record.timelock);
    for (const name of CONTRACT_NAMES) {
      assert.equal(second.record.contracts[name], first.record.contracts[name], name);
    }
  });

  it("requires an explicit long delay for mainnet deployments", async function () {
    await assert.rejects(
      deployAll(connection, { ...options, networkName: "monadMainnet" }),
      /TIMELOCK_DELAY_SECONDS between 86400 and 172800/,
    );
  });

  it("hands every admin role to the timelock", async function () {
    const { viem } = connection;
    for (const name of CONTRACT_NAMES) {
      const contract = await viem.getContractAt(name, first.record.contracts[name] as `0x${string}`);
      const adminRole = await contract.read.DEFAULT_ADMIN_ROLE();
      assert.equal(await contract.read.hasRole([adminRole, first.record.timelock]), true, name);
    }
  });
});