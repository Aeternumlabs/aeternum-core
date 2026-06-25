// SPDX-License-Identifier: BUSL-1.1
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
    /// --- TYPES ---
    struct VaultConfig {
        uint256 minInactivityPeriod;
        uint256 maxInactivityPeriod;
        uint8 maxRecoveryAttempts;
    }

    /// --- CHAIN IDs ---
    uint256 public constant MAINNET_CHAIN_ID = 1;
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant ANVIL_CHAIN_ID = 31337;

    /// --- STATE ---
    VaultConfig public activeConfig;

    /// --- CONSTRUCTOR ---
    constructor() {
        if (block.chainid == MAINNET_CHAIN_ID) {
            activeConfig = _getMainnetConfig();
        } else if (block.chainid == SEPOLIA_CHAIN_ID) {
            activeConfig = _getSepoliaConfig();
        } else {
            activeConfig = _getAnvilConfig();
        }

        console2.log("=== HelperConfig ===");
        console2.log("Chain ID:               ", block.chainid);
        console2.log("MIN_INACTIVITY_PERIOD:  ", activeConfig.minInactivityPeriod);
        console2.log("MAX_INACTIVITY_PERIOD:  ", activeConfig.maxInactivityPeriod);
        console2.log("MAX_RECOVERY_ATTEMPTS:  ", activeConfig.maxRecoveryAttempts);
    }

    /// --- NETWORK CONFIGS ---

    /**
     * @dev Ethereum mainnet — Phase 1.
     *
     *      KEEPER ARCHITECTURE:
     *        Recovery is triggered via the permissionless `triggerRecovery(wallet)`
     *        function. The Aeternum keeper bot monitors all registered wallets
     *        via the Ponder indexer and submits transactions when conditions are met.
     *        Gas costs (~91k gas per recovery, measured) are absorbed as a protocol
     *        operating expense. Any external actor may also call `triggerRecovery`
     *        as a liveness guarantee.
     *
     *      PARAMETER RATIONALE:
     *        MIN_INACTIVITY_PERIOD = 180 days (~6 months)
     *          → Covers extended period of inactivity, device loss, and prolonged
     *            travel without triggering accidental recovery. Users can set
     *            longer periods.
     *
     *        MAX_INACTIVITY_PERIOD = 3650 days (10 years)
     *          → Ceiling prevents vaults from being configured with periods so long
     *            they make monitoring impractical across protocol upgrades.
     *
     *        MAX_RECOVERY_ATTEMPTS = 3
     *          → Three attempts before permanent abandonment. Gives backup addresses
     *            that temporarily reject ETH (e.g. a smart wallet mid-upgrade) time
     *            to recover, while bounding keeper gas costs and retry loop exposure.
     */
    function _getMainnetConfig() internal pure returns (VaultConfig memory) {
        return VaultConfig({minInactivityPeriod: 180 days, maxInactivityPeriod: 3650 days, maxRecoveryAttempts: 3});
    }

    /**
     * @dev Sepolia testnet.
     *
     *      Mirrors mainnet `maxInactivityPeriod` and `maxRecoveryAttempts` exactly
     *      so that failure-path tests and retry behaviour observed on Sepolia are a
     *      faithful preview of mainnet execution.
     *
     *      MIN_INACTIVITY_PERIOD is shortened to 5 minutes so the full registration
     *      → inactivity → keeper trigger → recovery lifecycle can be validated
     *      within a single QA session without waiting for production-scale windows.
     *
     */
    function _getSepoliaConfig() internal pure returns (VaultConfig memory) {
        return VaultConfig({minInactivityPeriod: 5 minutes, maxInactivityPeriod: 3650 days, maxRecoveryAttempts: 3});
    }

    /**
     * @dev Local Anvil.
     *      Mirrors Sepolia for consistent local testing behaviour.
     *      The keeper bot polls on a configurable interval (default 30s in .env)
     *      so recovery flows can be observed within a single terminal session.
     */
    function _getAnvilConfig() internal pure returns (VaultConfig memory) {
        return VaultConfig({minInactivityPeriod: 5 minutes, maxInactivityPeriod: 3650 days, maxRecoveryAttempts: 3});
    }

    /// --- GETTERS ---
    function getConfig() external view returns (VaultConfig memory) {
        return activeConfig;
    }
}
