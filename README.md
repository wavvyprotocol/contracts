# wavvy-contracts

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

## Environment variables

| Variable | Purpose |
| --- | --- |
| `MONAD_TESTNET_RPC_URL` | Monad testnet RPC endpoint |
| `MONAD_MAINNET_RPC_URL` | Monad mainnet RPC endpoint |
| `FORK_RPC_URL` | Fork RPC endpoint |
| `DEPLOYER_PRIVATE_KEY` | Deployer key, testnet only in development |
| `ETHERSCAN_API_KEY` | Etherscan API key |
| `TIMELOCK_DELAY_SECONDS` | TimelockController delay used at deploy |