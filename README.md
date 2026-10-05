# Wavvy contracts

Solidity contracts for Wavvy: oracle layer, vAMM perpetuals core, position NFT,
insurance fund, creator rewards, curator registry, risk manager, and timelock.

## Toolchain

- Node.js v24.21.0
- npm 11.19.0
- Hardhat v3.18.1 with the Viem toolbox
- Solidity 0.8.x, OpenZeppelin Contracts v5, PRBMath v4
- Monad

## Install

```bash
npm install
```

## Compile and test

```bash
npx hardhat compile
npx hardhat test
```

## Architecture

- `WavvyOracle` keeps per-metric observation rings and their guards (staleness,
  deviation, circuit breaker). Only the CRE forwarder and the fallback keeper
  can report, and a missing metric is never posted as zero. `WavvyIndexOracle`
  computes index values onchain from constituent TWAPs at zero oracle cost.
- `WavvyVault` is the single custody point. Every protocol account (users, the
  position ledger, treasury, insurance, creator escrow, curator stake) holds a
  wad balance inside it; token movement happens only on deposit and withdraw.
- `WavvyAMM` is a per-market constant product on virtual reserves. The mark
  price is quote over base and funding accrues per block into a cumulative
  index that positions checkpoint against.
- `WavvyHouse` opens, closes, and liquidates positions and settles PnL between
  vault accounts against the treasury, with the insurance fund as backstop.
  Ownership always resolves through the position NFT holder.
- `WavvyPosition` is the ERC721 ledger: margin, size, entry price, and the
  funding checkpoint live on the token id, so transfers move the position.
- `WavvyFactory` registers curated markets and wires each market's price
  source. `WavvyCreatorRewards` escrows creator fee shares per creator id,
  `WavvyCurator` records staked calls and copy fees, `WavvyInsurance` backstops
  bad debt.
- `WavvyRiskManager` is the single source of limits; the house and the AMM read
  it on every state-changing call. Every admin action routes through
  `WavvyTimelock`, and the deployer holds no admin role after handover.

## Deploy

The deploy script deploys every contract in dependency order, wires the roles, hands every admin role to the timelock, renounces the deployer, verifies on
live networks, and records addresses in `deployments/<network>.json`.

```bash
# dry run against a Monad mainnet fork
npx hardhat run scripts/deploy.ts --network hardhatFork

# full fork smoke: deploy plus seed through the timelock, one process
DEPLOY_DELAY_MS=0 TIMELOCK_DELAY_SECONDS=5 npx hardhat run scripts/fork-smoke.ts --network hardhatFork

# Monad testnet
npx hardhat run scripts/deploy.ts --network monadTestnet
```

Environment variables used by the deploy:

| Variable | Purpose |
| --- | --- |
| `MONAD_TESTNET_RPC_URL` | Monad testnet RPC endpoint |
| `MONAD_MAINNET_RPC_URL` | Monad mainnet RPC endpoint |
| `FORK_RPC_URL` | Fork RPC endpoint for `hardhatFork` |
| `DEPLOYER_PRIVATE_KEY` | Deployer key; only a funded testnet key belongs here |
| `ETHERSCAN_API_KEY` | Etherscan v2 key covering Monadscan verification |
| `TIMELOCK_DELAY_SECONDS` | Timelock delay used at deploy; short on testnet |
| `TREASURY_ADDRESS` | Protocol fee account; defaults to the deployer |
| `GRANTS_POOL_ADDRESS` | Sweep destination for dormant creator balances |
| `TIMELOCK_PROPOSER` | Who may schedule timelock operations; defaults to the deployer |
| `CRE_REPORTER_ADDRESS` | CRE forwarder granted the oracle reporter role and pinned on the oracle |
| `CRE_WORKFLOW_ID` | Expected CRE workflow id, with the two below |
| `CRE_WORKFLOW_NAME` | Expected CRE workflow name (up to 10 bytes) |
| `CRE_WORKFLOW_OWNER` | Expected CRE workflow owner |
| `FALLBACK_KEEPER_ADDRESS` | Fallback keeper granted the oracle fallback role |
| `PAUSER_ADDRESS` | Emergency pauser role holder |
| `MOCK_USDC_MINTER` | Test USDC minter role holder |
| `DEPLOY_DELAY_MS` | Pause between transactions, default 1500 |
| `RISK_FUNDING_COEFFICIENT` | Funding k for the seeded risk defaults |
| `RISK_MAX_FUNDING_RATE_PER_BLOCK` | Funding cap per block for the seeded risk defaults |
| `RISK_OI_CAP` | Open interest cap for the seeded risk defaults |
| `RISK_MIN_MARGIN` | Minimum margin for the seeded risk defaults, default 10e18 |

Risk type defaults are seeded only when the first three risk variables above
are set: the funding cap is never invented by the script.

After handover the deployer holds no admin role. Market creation, parameter changes, pause resets, and role grants are timelock operations: schedule with
the proposer, wait out the delay, then execute. `pauseMarket` and `tripCircuitBreaker` are the only emergency actions a pauser can take alone.

## Seed

A fresh deployment has no metrics, markets, or risk configuration, so nothing is tradeable. `scripts/seed.ts` turns a JSON plan into timelock operations:
oracle metric registration, per-market risk configuration, market creation,
and index market registration. Start from `seed/example.json`.

```bash
# schedule every operation from the plan (writes deployments/<network>-seed.json)
SEED_CONFIG=seed/monadTestnet.json npx hardhat run scripts/seed.ts --network monadTestnet

# after the timelock delay, execute the scheduled operations
SEED_EXECUTE=true npx hardhat run scripts/seed.ts --network monadTestnet

# or wait out the delay and execute in one run
SEED_WAIT=true npx hardhat run scripts/seed.ts --network monadTestnet
```

| Variable | Purpose |
| --- | --- |
| `SEED_CONFIG` | Path to the seed plan, default `seed/<network>.json` |
| `SEED_DELAY_SECONDS` | Delay used when scheduling, default the timelock's own minimum |
| `SEED_EXECUTE` | Execute previously scheduled operations |
| `SEED_WAIT` | Wait for readiness and execute in the same run |

## Roles

| Contract | Role | Holder after handover | Purpose |
| --- | --- | --- | --- |
| All contracts | `DEFAULT_ADMIN_ROLE` | Timelock | Role and parameter administration |
| WavvyOracle | `CRE_REPORTER_ROLE` | CRE forwarder | Report delivery through `onReport` |
| WavvyOracle | `FALLBACK_KEEPER_ROLE` | Fallback keeper | `postFallback` while CRE data is stale |
| WavvyVault | `HOUSE_ROLE` | WavvyHouse | Position, fee, and liquidation settlement |
| WavvyVault | `SYSTEM_ROLE` | WavvyCurator | Pull a user's stake into the curator account |
| WavvyAMM | `HOUSE_ROLE` | WavvyHouse | Open and close trades |
| WavvyAMM | `MARKET_ADMIN_ROLE` | WavvyFactory | Create market state |
| WavvyHouse | `MARKET_ADMIN_ROLE` | WavvyFactory | Set a market's price source |
| WavvyPosition | `HOUSE_ROLE` | WavvyHouse | Mint, update, and burn position tokens |
| WavvyInsurance | `HOUSE_ROLE` | WavvyHouse | Cover bad debt and payout shortfalls |
| WavvyCreatorRewards | `HOUSE_ROLE` | WavvyHouse | Accrue creator fee shares |
| WavvyCurator | `HOUSE_ROLE` | WavvyHouse | Record copies and credit copy fees |
| WavvyFactory | `MARKET_ADMIN_ROLE` | Timelock | Curated market creation |
| WavvyRiskManager | `PAUSER_ROLE` | Pauser wallet | Emergency pause and breaker trip |
| MockUSDC | `MINTER_ROLE` | Configured minter, timelock | Test collateral minting |

## Verification

Verification runs automatically during deploy on live networks when
`ETHERSCAN_API_KEY` is set, covering Monadscan through the Etherscan v2 API
and Sourcify through MonadVision. To verify one contract manually:

```bash
npx hardhat verify --network monadTestnet <address> <constructor arguments>
```

## Infra products and why

- Monad: high-throughput EVM. Per-block funding accrual and hourly oracle writes stay cheap enough to run continuously.
- QuickNode: Monad RPC endpoint for deploy, verification, and fork tests.
- Chainlink CRE: primary oracle delivery. `WavvyOracle` exposes the CRE receiver entrypoint, the fallback keeper role exists only for staleness emergencies.
- OpenZeppelin Contracts v5: AccessControl, TimelockController, ERC721, SafeERC20, ReentrancyGuard, and Base64 for onchain metadata.
- PRBMath v4 (UD60x18): the fixed-point base for `WavvyMath`, shared by vAMM reserve math, funding index math, and fee computation.