import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { configVariable, defineConfig } from "hardhat/config";

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin],
  solidity: {
    version: "0.8.34",
    settings: {
      evmVersion: "osaka",
      optimizer: {
        enabled: true,
        runs: 200,
      },
      metadata: {
        bytecodeHash: "ipfs",
      },
    },
  },
  networks: {
    monadTestnet: {
      type: "http",
      chainType: "l1",
      url: configVariable("MONAD_TESTNET_RPC_URL"),
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY")],
      chainId: 10143,
    },
    monadMainnet: {
      type: "http",
      chainType: "l1",
      url: configVariable("MONAD_MAINNET_RPC_URL"),
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY")],
      chainId: 143,
    },
    hardhatFork: {
      type: "edr-simulated",
      chainType: "l1",
      chainId: 143,
      forking: {
        enabled: true,
        url: configVariable("FORK_RPC_URL"),
      },
    },
  },
  verify: {
    etherscan: {
      enabled: true,
      apiKey: configVariable("ETHERSCAN_API_KEY"),
    },
    sourcify: {
      enabled: true,
      apiUrl: "https://sourcify-api-monad.blockvision.org",
      browserUrl: "https://testnet.monadvision.com/"
    },
  },
  chainDescriptors: {
    10143: {
      name: "MonadTestnet",
      blockExplorers: {
        etherscan: {
          name: "Monadscan",
          url: "https://testnet.monadscan.com",
          apiUrl: "https://api.etherscan.io/v2/api",
        },
      },
    },
    143: {
      name: "MonadMainnet",
      blockExplorers: {
        etherscan: {
          name: "Monadscan",
          url: "https://monadscan.com",
          apiUrl: "https://api.etherscan.io/v2/api",
        },
      },
    },
  },
});