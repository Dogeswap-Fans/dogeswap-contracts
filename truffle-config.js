const { mnemonic, etherscanApiKey } = require('./secrets.json');
const HDWalletProvider = require('@truffle/hdwallet-provider');
module.exports = {
  // Uncommenting the defaults below 
  // provides for an easier quick-start with Ganache.
  // You can also follow this format for other networks;
  // see <http://truffleframework.com/docs/advanced/configuration>
  // for more details on how to specify configuration options!
  //
  //networks: {
  //  development: {
  //    host: "127.0.0.1",
  //    port: 7545,
  //    network_id: "*"
  //  },
  //  test: {
  //    host: "127.0.0.1",
  //    port: 7545,
  //    network_id: "*"
  //  }
  //}
  //
  contracts_directory: "./contracts/mining",
  networks: {
    heco: {
      provider: () => new HDWalletProvider(
        mnemonic, 'https://http-mainnet.hecochain.com'
      ),
      network_id: 128,
      gasPrice: 10e9,
      skipDryRun: true
    }
  },
  compilers: {
    solc: {
      version: '0.6.12+commit.27d51765', // A version or constraint - Ex. "^0.5.0"
      // Can also be set to "native" to use a native solc
      docker: false, // Use a version obtained through docker
      parser: "solcjs",  // Leverages solc-js purely for speedy parsing
      settings: {
        evmVersion: 'istanbul',
        libraries: {},
        metadata: {
          bytecodeHash: "ipfs"
        },
        optimizer: {
          enabled: true,
          runs: 200  // Optimize for how many times you intend to run the code
        },
        remappings: []
      }
    }
  },
  plugins: [
    'truffle-plugin-verify'
  ],
  api_keys: {
    hecoinfo: etherscanApiKey
  }
};
