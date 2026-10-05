import { network } from "hardhat";
import { seedAll } from "./lib/seed.js";

const connection = await network.create();
await seedAll(connection, {
  configPath: process.env.SEED_CONFIG,
  delaySeconds: process.env.SEED_DELAY_SECONDS ? Number(process.env.SEED_DELAY_SECONDS) : undefined,
  execute: process.env.SEED_EXECUTE === "true",
  wait: process.env.SEED_WAIT === "true",
});