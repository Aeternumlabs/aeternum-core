// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

/**
 * @title  HelperConfig
 * @notice Resolves network-specific deployment parameters.
 *         Automatically selects the right config based on block.chainid.
 *
 * Usage:
 *   HelperConfig config = new HelperConfig();
 *   address treasury = config.getTreasuryAddress();
 */
contract HelperConfig is Script {
    /*//////////////////////////////////////////////////////////////
                             TYPES
    //////////////////////////////////////////////////////////////*/

    struct NetworkConfig {
        address treasury; // Address that will receive subscription fees
    }

    /*//////////////////////////////////////////////////////////////
                          CHAIN IDs
    //////////////////////////////////////////////////////////////*/

    uint256 public constant BASE_MAINNET_CHAIN_ID = 8453;
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant ANVIL_CHAIN_ID = 31337;

    /*//////////////////////////////////////////////////////////////
                           STATE
    //////////////////////////////////////////////////////////////*/

    NetworkConfig public activeConfig;

    /*//////////////////////////////////////////////////////////////
                         CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        if (block.chainid == BASE_MAINNET_CHAIN_ID) {
            activeConfig = _getMainnetConfig();
        } else if (block.chainid == SEPOLIA_CHAIN_ID) {
            activeConfig = _getSepoliaConfig();
        } else {
            activeConfig = _getAnvilConfig();
        }

        console2.log("=== HelperConfig ===");
        console2.log("Chain ID:  ", block.chainid);
        console2.log("Treasury:  ", activeConfig.treasury);
    }

    /*//////////////////////////////////////////////////////////////
                       NETWORK CONFIGS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Mainnet config. Treasury should be a Gnosis Safe multisig.
     *      REPLACE 0x000...000 with your production multisig address before deploying.
     */
    function _getMainnetConfig() internal pure returns (NetworkConfig memory) {
        return
            NetworkConfig({
                treasury: 0x0000000000000000000000000000000000000001 // TODO: replace with mainnet multisig
            });
    }

    /**
     * @dev Sepolia testnet config for QA and integration testing.
     *      REPLACE with your Sepolia treasury/EOA address.
     */
    function _getSepoliaConfig() internal pure returns (NetworkConfig memory) {
        return
            NetworkConfig({
                treasury: 0x0000000000000000000000000000000000000002 // TODO: replace with Sepolia treasury
            });
    }

    /**
     * @dev Local Anvil config. Creates a deterministic test treasury account
     *      using forge-std's makeAddr for consistent addresses across test runs.
     */
    function _getAnvilConfig() internal returns (NetworkConfig memory) {
        address localTreasury = makeAddr("treasury");
        return NetworkConfig({treasury: localTreasury});
    }

    /*//////////////////////////////////////////////////////////////
                          GETTERS
    //////////////////////////////////////////////////////////////*/

    function getTreasuryAddress() external view returns (address) {
        return activeConfig.treasury;
    }

    function getActiveConfig() external view returns (NetworkConfig memory) {
        return activeConfig;
    }
}
