// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

/**
 * @title  HelperConfig
 * @notice Resolves network-specific deployment parameters for AeternumVault.
 *         Automatically selects the right config based on block.chainid.
 *
 * Usage:
 *   HelperConfig config = new HelperConfig();
 *   HelperConfig.VaultConfig memory cfg = config.getConfig();
 */
contract HelperConfig is Script {
    /*//////////////////////////////////////////////////////////////
                             TYPES
    //////////////////////////////////////////////////////////////*/

    struct VaultConfig {
        address treasury;
        uint256 minInactivityFree;
        uint256 minInactivityPremium;
        uint256 maxInactivityPeriod;
        uint256 subscriptionDuration;
        uint256 premiumMonthlyFee;
        uint256 maxBatchSize;
        uint8 maxRecoveryAttempts;
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

    VaultConfig public activeConfig;

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
        console2.log("Chain ID:             ", block.chainid);
        console2.log("Treasury:             ", activeConfig.treasury);
        console2.log("MIN_FREE (seconds):   ", activeConfig.minInactivityFree);
        console2.log("MIN_PREMIUM (seconds):", activeConfig.minInactivityPremium);
        console2.log("SUB_DURATION (secs):  ", activeConfig.subscriptionDuration);
        console2.log("PREMIUM_FEE (wei):    ", activeConfig.premiumMonthlyFee);
        console2.log("MAX_BATCH_SIZE:       ", activeConfig.maxBatchSize);
        console2.log("MAX_RECOVERY_ATTEMPTS:", activeConfig.maxRecoveryAttempts);
    }

    /*//////////////////////////////////////////////////////////////
                       NETWORK CONFIGS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Base mainnet config. Treasury MUST be a Gnosis Safe multisig.
     *      REPLACE 0x000...001 with your production multisig address before deploying.
     */
    function _getMainnetConfig() internal pure returns (VaultConfig memory) {
        return VaultConfig({
            treasury: 0x0000000000000000000000000000000000000001, // TODO: replace with mainnet multisig
            minInactivityFree: 365 days,
            minInactivityPremium: 180 days,
            maxInactivityPeriod: 3650 days,
            subscriptionDuration: 30 days,
            premiumMonthlyFee: 0.002 ether,
            maxBatchSize: 50,
            maxRecoveryAttempts: 3
        });
    }

    /**
     * @dev Sepolia testnet config for QA and integration testing.
     *      Treasury is read from the SEPOLIA_TREASURY env variable.
     *      Short inactivity periods so you don't wait 180-365 days on testnet.
     */
    function _getSepoliaConfig() internal view returns (VaultConfig memory) {
        return VaultConfig({
            treasury: vm.envAddress("SEPOLIA_TREASURY"),
            minInactivityFree: 10 minutes,
            minInactivityPremium: 5 minutes,
            maxInactivityPeriod: 30 minutes,
            subscriptionDuration: 2.5 minutes,
            premiumMonthlyFee: 0.002 ether,
            maxBatchSize: 50,
            maxRecoveryAttempts: 3
        });
    }

    /**
     * @dev Local Anvil config. Uses forge-std's makeAddr for a deterministic
     *      treasury address consistent across test runs.
     *      Mirrors Sepolia short periods for fast local iteration.
     */
    function _getAnvilConfig() internal returns (VaultConfig memory) {
        address localTreasury = makeAddr("treasury");
        return VaultConfig({
            treasury: localTreasury,
            minInactivityFree: 10 minutes,
            minInactivityPremium: 5 minutes,
            maxInactivityPeriod: 30 minutes,
            subscriptionDuration: 1 minutes,
            premiumMonthlyFee: 0.002 ether,
            maxBatchSize: 50,
            maxRecoveryAttempts: 3
        });
    }

    /*//////////////////////////////////////////////////////////////
                          GETTERS
    //////////////////////////////////////////////////////////////*/

    function getConfig() external view returns (VaultConfig memory) {
        return activeConfig;
    }

    /// @notice Convenience getter kept for backward compatibility.
    function getTreasuryAddress() external view returns (address) {
        return activeConfig.treasury;
    }
}
