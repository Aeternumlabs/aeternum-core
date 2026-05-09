// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AeternumVault} from "../src/AeternumVault.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

/**
 * @title  Deploy
 * @notice Deploys AeternumVault with network-correct parameters sourced from HelperConfig.
 *
 * Usage:
 *   # Local Anvil
 *   forge script script/Deploy.s.sol --rpc-url localhost --broadcast
 *
 *   # Sepolia testnet (dry-run first)
 *   forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL
 *
 *   # Sepolia testnet (broadcast + verify on Etherscan)
 *   forge script script/Deploy.s.sol \
 *     --account private-key \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     --verify \
 *     --broadcast \
 *     -vvvv
 *
 *   # Mainnet (ALWAYS dry-run first, before broadcasting)
 *   forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL -vvvv
 */
contract Deploy is Script {
    function run() external returns (AeternumVault aeternumVault, HelperConfig helperConfig) {
        helperConfig = new HelperConfig();
        HelperConfig.VaultConfig memory cfg = helperConfig.getConfig();

        require(cfg.treasury != address(0), "Deploy: treasury is zero address");

        console2.log("\n=== AeternumVault Deployment ===");
        console2.log("Deployer:                 ", msg.sender);
        console2.log("Treasury:                 ", cfg.treasury);
        console2.log("Chain ID:                 ", block.chainid);
        console2.log("Block:                    ", block.number);
        console2.log("Timestamp:                ", block.timestamp);
        console2.log("MIN_FREE (s):             ", cfg.minInactivityFree);
        console2.log("MIN_PREMIUM (s):          ", cfg.minInactivityPremium);
        console2.log("MAX_PERIOD (days):        ", cfg.maxInactivityPeriod / 1 days);
        console2.log("SUB_DURATION (s):         ", cfg.subscriptionDuration);
        console2.log("PREMIUM_FEE (wei):        ", cfg.premiumMonthlyFee);
        console2.log("ANNUAL_FEE (wei):         ", cfg.premiumAnnualFee);
        console2.log("MAX_CHECK_UPKEEP_SIZE:    ", cfg.maxCheckUpkeepSize);
        console2.log("MAX_PERFORM_UPKEEP_SIZE:  ", cfg.maxPerformUpkeepSize);
        console2.log("MAX_RECOVERY_ATTEMPTS:    ", cfg.maxRecoveryAttempts);
        console2.log("CURSOR_ADVANCE_INTERVAL:  ", cfg.cursorAdvanceInterval);

        vm.startBroadcast();
        aeternumVault = new AeternumVault(
            cfg.treasury,
            cfg.minInactivityFree,
            cfg.minInactivityPremium,
            cfg.maxInactivityPeriod,
            cfg.subscriptionDuration,
            cfg.premiumMonthlyFee,
            cfg.premiumAnnualFee,
            cfg.maxCheckUpkeepSize,
            cfg.maxPerformUpkeepSize,
            cfg.maxRecoveryAttempts,
            cfg.cursorAdvanceInterval
        );
        vm.stopBroadcast();

        _verifyDeployment(aeternumVault, cfg);
    }

    function _verifyDeployment(AeternumVault rm, HelperConfig.VaultConfig memory cfg) internal view {
        console2.log("\n=== Post-Deploy Verification ===");
        console2.log("Contract address:         ", address(rm));
        console2.log("Treasury:                 ", rm.getTreasury());
        console2.log("Total registered:         ", rm.getTotalRegistered());
        console2.log("Accumulated fees:         ", rm.getAccumulatedFees());
        console2.log("MAX_CHECK_UPKEEP_SIZE:    ", rm.MAX_CHECK_UPKEEP_SIZE());
        console2.log("MAX_PERFORM_UPKEEP_SIZE:  ", rm.MAX_PERFORM_UPKEEP_SIZE());
        console2.log("MAX_RECOVERY_ATTEMPTS:    ", rm.MAX_RECOVERY_ATTEMPTS());
        console2.log("PREMIUM_FEE (wei):        ", rm.PREMIUM_MONTHLY_FEE());
        console2.log("ANNUAL_FEE (wei):         ", rm.PREMIUM_ANNUAL_FEE());
        console2.log("CURSOR_ADVANCE_INTERVAL:  ", rm.CURSOR_ADVANCE_INTERVAL());
        console2.log("MIN_FREE (s):             ", rm.MIN_INACTIVITY_PERIOD_FREE());
        console2.log("MIN_PREMIUM (s):          ", rm.MIN_INACTIVITY_PERIOD_PREMIUM());

        require(rm.getTreasury() == cfg.treasury, "Deploy: treasury mismatch");
        require(rm.MIN_INACTIVITY_PERIOD_FREE() == cfg.minInactivityFree, "Deploy: minInactivityFree mismatch");
        require(rm.MIN_INACTIVITY_PERIOD_PREMIUM() == cfg.minInactivityPremium, "Deploy: minInactivityPremium mismatch");
        require(rm.MAX_INACTIVITY_PERIOD() == cfg.maxInactivityPeriod, "Deploy: maxInactivityPeriod mismatch");
        require(rm.SUBSCRIPTION_DURATION() == cfg.subscriptionDuration, "Deploy: subscriptionDuration mismatch");
        require(rm.PREMIUM_MONTHLY_FEE() == cfg.premiumMonthlyFee, "Deploy: premiumMonthlyFee mismatch");
        require(rm.PREMIUM_ANNUAL_FEE() == cfg.premiumAnnualFee, "Deploy: premiumAnnualFee mismatch");
        require(rm.MAX_CHECK_UPKEEP_SIZE() == cfg.maxCheckUpkeepSize, "Deploy: maxCheckUpkeepSize mismatch");
        require(rm.MAX_PERFORM_UPKEEP_SIZE() == cfg.maxPerformUpkeepSize, "Deploy: maxPerformUpkeepSize mismatch");
        require(rm.MAX_RECOVERY_ATTEMPTS() == cfg.maxRecoveryAttempts, "Deploy: maxRecoveryAttempts mismatch");
        require(rm.CURSOR_ADVANCE_INTERVAL() == cfg.cursorAdvanceInterval, "Deploy: cursorAdvanceInterval mismatch");
        require(rm.getTotalRegistered() == 0, "Deploy: unexpected registrations");
        require(rm.getAccumulatedFees() == 0, "Deploy: unexpected fees");

        console2.log("\nAll assertions passed. AeternumVault deployed successfully.");
    }
}
