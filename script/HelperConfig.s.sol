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
        // Treasury
        address treasury;
        // Inactivity periods
        uint256 minInactivityFree;
        uint256 minInactivityPremium;
        uint256 maxInactivityPeriod;
        // Subscription
        uint256 subscriptionDuration;
        uint256 premiumMonthlyFee;
        uint256 premiumAnnualFee;
        // Automation
        uint256 maxCheckUpkeepSize; // off-chain scan window (no gas constraint)
        uint256 maxPerformUpkeepSize; // on-chain execution cap (gas-bound, keep ≤ 50 mainnet)
        uint8 maxRecoveryAttempts;
        uint256 cursorAdvanceInterval; // idle cursor tick frequency
    }

    /*//////////////////////////////////////////////////////////////
                          CHAIN IDs
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MAINNET_CHAIN_ID = 1;
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
        if (block.chainid == ETH_MAINNET_CHAIN_ID) {
            activeConfig = _getMainnetConfig();
        } else if (block.chainid == SEPOLIA_CHAIN_ID) {
            activeConfig = _getSepoliaConfig();
        } else {
            activeConfig = _getAnvilConfig();
        }

        console2.log("=== HelperConfig ===");
        console2.log("Chain ID:                 ", block.chainid);
        console2.log("Treasury:                 ", activeConfig.treasury);
        console2.log("MIN_FREE (s):             ", activeConfig.minInactivityFree);
        console2.log("MIN_PREMIUM (s):          ", activeConfig.minInactivityPremium);
        console2.log("SUB_DURATION (s):         ", activeConfig.subscriptionDuration);
        console2.log("PREMIUM_FEE (wei):        ", activeConfig.premiumMonthlyFee);
        console2.log("ANNUAL_FEE (wei):         ", activeConfig.premiumAnnualFee);
        console2.log("MAX_CHECK_UPKEEP_SIZE:    ", activeConfig.maxCheckUpkeepSize);
        console2.log("MAX_PERFORM_UPKEEP_SIZE:  ", activeConfig.maxPerformUpkeepSize);
        console2.log("MAX_RECOVERY_ATTEMPTS:    ", activeConfig.maxRecoveryAttempts);
        console2.log("CURSOR_ADVANCE_INTERVAL:  ", activeConfig.cursorAdvanceInterval);
    }

    /*//////////////////////////////////////////////////////////////
                       NETWORK CONFIGS
    //////////////////////////////////////////////////////////////*/

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
     *            (~4.2 days) — well within 180-day Premium minimum inactivity period.
     *
     *      TREASURY: Replace placeholder with your production Gnosis Safe address.
     */
    function _getMainnetConfig() internal pure returns (VaultConfig memory) {
        return VaultConfig({
            treasury: 0x0000000000000000000000000000000000000001, // Replace with Gnosis Safe address
            minInactivityFree: 365 days,
            minInactivityPremium: 180 days,
            maxInactivityPeriod: 3650 days,
            subscriptionDuration: 30 days,
            premiumMonthlyFee: 0.002 ether,
            premiumAnnualFee: 0.02 ether, // Discounted
            maxCheckUpkeepSize: 5000,
            maxPerformUpkeepSize: 50,
            maxRecoveryAttempts: 3,
            cursorAdvanceInterval: 1 hours
        });
    }

    /**
     * @dev Sepolia testnet.
     *
     *      Short inactivity periods for rapid testnet iteration.
     *      MAX_CHECK_UPKEEP_SIZE kept small (100) so test wallets are found quickly.
     *      MAX_PERFORM_UPKEEP_SIZE = 10 to make batching behaviour testable with
     *      a small number of registered wallets.
     *      CURSOR_ADVANCE_INTERVAL = 30 seconds for fast cursor cycling during QA.
     *
     *      Treasury sourced from SEPOLIA_TREASURY env variable.
     */
    function _getSepoliaConfig() internal view returns (VaultConfig memory) {
        return VaultConfig({
            treasury: vm.envAddress("SEPOLIA_TREASURY"),
            minInactivityFree: 10 minutes,
            minInactivityPremium: 5 minutes,
            maxInactivityPeriod: 365 days,
            subscriptionDuration: 2.5 minutes,
            premiumMonthlyFee: 0.002 ether,
            premiumAnnualFee: 0.02 ether,
            maxCheckUpkeepSize: 100,
            maxPerformUpkeepSize: 10,
            maxRecoveryAttempts: 3,
            cursorAdvanceInterval: 30 seconds
        });
    }

    /**
     * @dev Local Anvil.
     *      Mirrors Sepolia for consistent local testing behaviour.
     *      Uses forge-std makeAddr for a deterministic treasury.
     */
    function _getAnvilConfig() internal returns (VaultConfig memory) {
        return VaultConfig({
            treasury: makeAddr("treasury"),
            minInactivityFree: 10 minutes,
            minInactivityPremium: 5 minutes,
            maxInactivityPeriod: 365 days,
            subscriptionDuration: 2.5 minutes,
            premiumMonthlyFee: 0.002 ether,
            premiumAnnualFee: 0.02 ether,
            maxCheckUpkeepSize: 100,
            maxPerformUpkeepSize: 10,
            maxRecoveryAttempts: 3,
            cursorAdvanceInterval: 30 seconds
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
