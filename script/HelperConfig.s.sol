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
        // Inactivity periods
        uint256 minInactivityPeriod;
        uint256 maxInactivityPeriod;
        // Automation
        uint256 maxCheckUpkeepSize; // off-chain scan window (no gas constraint)
        uint256 maxPerformUpkeepSize; // on-chain execution cap (gas-bound, keep ≤ 50 in mainnet)
        uint8 maxRecoveryAttempts;
        uint256 cursorAdvanceInterval; // idle cursor tick frequency
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
        console2.log("Chain ID:                 ", block.chainid);
        console2.log("MIN_INACTIVITY_PERIOD:    ", activeConfig.minInactivityPeriod);
        console2.log("MAX_CHECK_UPKEEP_SIZE:    ", activeConfig.maxCheckUpkeepSize);
        console2.log("MAX_PERFORM_UPKEEP_SIZE:  ", activeConfig.maxPerformUpkeepSize);
        console2.log("MAX_RECOVERY_ATTEMPTS:    ", activeConfig.maxRecoveryAttempts);
        console2.log("CURSOR_ADVANCE_INTERVAL:  ", activeConfig.cursorAdvanceInterval);
    }

    /// --- NETWORK CONFIGS ---
    /**
     * @dev Ethereum mainnet (Phase 1).
     *
     *      AUTOMATION RATIONALE:
     *        MAX_CHECK_UPKEEP_SIZE = 5000
     *          → Each Chainlink tick scans 5000 wallets off-chain.
     *          → At 500k users: 100 ticks for a full scan.
     *          → 5000 × ~800 gas (SLOAD) = ~4M simulation gas — within Chainlink's
     *            6.5M simulation limit.
     *
     *        MAX_PERFORM_UPKEEP_SIZE = 50
     *          → Worst-case ~100k gas per _executeRecovery (SSTOREs + ETH call + events).
     *          → 50 × 100k = 5M gas per performUpkeep — safe under 30M block limit.
     *
     *        CURSOR_ADVANCE_INTERVAL = 1 hour
     *          → 24 on-chain calls/day for idle cursor advancement.
     *          → At ~40k gas per idle call, 20 gwei: ~$1.92/call → ~$46/day.
     *          → At 500k users with MAX_CHECK_UPKEEP_SIZE=5000: full scan in 100 hours
     *            (~4.2 days) — well within 180-day minimum inactivity period.
     */
    function _getMainnetConfig() internal pure returns (VaultConfig memory) {
        return VaultConfig({
            minInactivityPeriod: 180 days,
            maxInactivityPeriod: 3650 days,
            maxCheckUpkeepSize: 5000,
            maxPerformUpkeepSize: 50,
            maxRecoveryAttempts: 3,
            cursorAdvanceInterval: 1 hours
        });
    }

    /**
     * @dev Sepolia testnet.
     *
     *      Mirrors most mainnet automation parameters exactly so that
     *      Chainlink Automation behaviour observed on Sepolia is a faithful preview
     *      of mainnet execution — same batch sizing, same recovery attempts, same gas profile.
     *
     *      Min inactivity period and cursor advance interval are intentionally shortened to 
     *      5 minutes and 30 seconds respectively 
     *      so recovery flows can be triggered and observed within a single QA session
     *      without waiting for production-scale windows.
     */
    function _getSepoliaConfig() internal pure returns (VaultConfig memory) {
        return VaultConfig({
            minInactivityPeriod: 5 minutes,
            maxInactivityPeriod: 3650 days,
            maxCheckUpkeepSize: 5000,
            maxPerformUpkeepSize: 50,
            maxRecoveryAttempts: 3,
            cursorAdvanceInterval: 30 seconds
        });
    }

    /**
     * @dev Local Anvil.
     *      Mirrors Sepolia for consistent local testing behaviour.
     */
    function _getAnvilConfig() internal pure returns (VaultConfig memory) {
        return VaultConfig({
            minInactivityPeriod: 5 minutes,
            maxInactivityPeriod: 3650 days,
            maxCheckUpkeepSize: 5000,
            maxPerformUpkeepSize: 50,
            maxRecoveryAttempts: 3,
            cursorAdvanceInterval: 30 seconds
        });
    }

    /// --- GETTERS ---
    function getConfig() external view returns (VaultConfig memory) {
        return activeConfig;
    }
}
