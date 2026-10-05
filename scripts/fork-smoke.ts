import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { network } from "hardhat";
import { deployAll } from "./lib/deploy.js";
import { seedAll } from "./lib/seed.js";

const connection = await network.create();
const networkName = connection.networkName;

await deployAll(connection, { networkName, delayMs: 0 });
await seedAll(connection, {
  networkName,
  configPath: "seed/example.json",
  delaySeconds: 5,
  wait: true,
});

const statePath = `deployments/${networkName}-seed.json`;
assert.ok(existsSync(statePath), "seed state file missing");
const state = JSON.parse(readFileSync(statePath, "utf8")) as {
  operations: Array<{ status: string; label: string }>;
};
for (const operation of state.operations) {
  assert.equal(operation.status, "executed", `${operation.label} not executed`);
}
console.log(`fork smoke ok: ${state.operations.length} seed operations executed`);