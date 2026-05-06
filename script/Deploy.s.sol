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
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 *
 *   # Mainnet (ALWAYS dry-run first, then add --broadcast)
 *   forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL -vvvv
 */
contract Deploy is Script {
    /*//////////////////////////////////////////////////////////////
                          ENTRY POINT
    //////////////////////////////////////////////////////////////*/

    function run() external returns (AeternumVault aeternumVault, HelperConfig helperConfig) {
        helperConfig = new HelperConfig();
        HelperConfig.VaultConfig memory cfg = helperConfig.getConfig();

        // Sanity check before spending gas
        require(cfg.treasury != address(0), "Deploy: treasury is zero address");

        // Log pre-deployment info
        console2.log("\n=== AeternumVault Deployment ===");
        console2.log("Deployer:             ", msg.sender);
        console2.log("Treasury:             ", cfg.treasury);
        console2.log("Chain ID:             ", block.chainid);
        console2.log("Block:                ", block.number);
        console2.log("Timestamp:            ", block.timestamp);
        console2.log("MIN_FREE (seconds):   ", cfg.minInactivityFree);
        console2.log("MIN_PREMIUM (seconds):", cfg.minInactivityPremium);
        console2.log("MAX_PERIOD (seconds): ", cfg.maxInactivityPeriod);
        console2.log("SUB_DURATION (secs):  ", cfg.subscriptionDuration);
        console2.log("PREMIUM_FEE (wei):    ", cfg.premiumMonthlyFee);
        console2.log("MAX_BATCH_SIZE:       ", cfg.maxBatchSize);
        console2.log("MAX_RECOVERY_ATTEMPTS:", cfg.maxRecoveryAttempts);

        // ── Deploy ──────────────────────────────────────────────────────────
        vm.startBroadcast();
        aeternumVault = new AeternumVault(
            cfg.treasury,
            cfg.minInactivityFree,
            cfg.minInactivityPremium,
            cfg.maxInactivityPeriod,
            cfg.subscriptionDuration,
            cfg.premiumMonthlyFee,
            cfg.maxBatchSize,
            cfg.maxRecoveryAttempts
        );
        vm.stopBroadcast();

        // ── Post-deploy verification ─────────────────────────────────────────
        _verifyDeployment(aeternumVault, cfg);
    }

    /*//////////////////////////////////////////////////////////////
                      POST-DEPLOY CHECKS
    //////////////////////////////////////////////////////////////*/

    function _verifyDeployment(AeternumVault rm, HelperConfig.VaultConfig memory cfg) internal view {
        console2.log("\n=== Post-Deploy Verification ===");
        console2.log("Contract address:     ", address(rm));
        console2.log("Treasury:             ", rm.getTreasury());
        console2.log("Total registered:     ", rm.getTotalRegistered());
        console2.log("Accumulated fees:     ", rm.getAccumulatedFees());
        console2.log("MAX_BATCH_SIZE:       ", rm.MAX_BATCH_SIZE());
        console2.log("MAX_RECOVERY_ATTEMPTS:", rm.MAX_RECOVERY_ATTEMPTS());
        console2.log("PREMIUM_FEE (wei):    ", rm.PREMIUM_MONTHLY_FEE());
        console2.log("MIN_FREE (seconds):   ", rm.MIN_INACTIVITY_PERIOD_FREE());
        console2.log("MIN_PREMIUM (seconds):", rm.MIN_INACTIVITY_PERIOD_PREMIUM());
        console2.log("MAX_PERIOD (seconds):    ", rm.MAX_INACTIVITY_PERIOD());
        console2.log("SUB_DURATION (secs):  ", rm.SUBSCRIPTION_DURATION());

        // Assertions — revert the script if anything looks wrong
        require(rm.getTreasury() == cfg.treasury, "Deploy: treasury mismatch");
        require(rm.MIN_INACTIVITY_PERIOD_FREE() == cfg.minInactivityFree, "Deploy: minInactivityFree mismatch");
        require(rm.MIN_INACTIVITY_PERIOD_PREMIUM() == cfg.minInactivityPremium, "Deploy: minInactivityPremium mismatch");
        require(rm.MAX_INACTIVITY_PERIOD() == cfg.maxInactivityPeriod, "Deploy: maxInactivityPeriod mismatch");
        require(rm.SUBSCRIPTION_DURATION() == cfg.subscriptionDuration, "Deploy: subscriptionDuration mismatch");
        require(rm.PREMIUM_MONTHLY_FEE() == cfg.premiumMonthlyFee, "Deploy: premiumMonthlyFee mismatch");
        require(rm.MAX_BATCH_SIZE() == cfg.maxBatchSize, "Deploy: maxBatchSize mismatch");
        require(rm.MAX_RECOVERY_ATTEMPTS() == cfg.maxRecoveryAttempts, "Deploy: maxRecoveryAttempts mismatch");
        require(rm.getTotalRegistered() == 0, "Deploy: unexpected registrations");
        require(rm.getAccumulatedFees() == 0, "Deploy: unexpected fees");

        console2.log("\nAll assertions passed. AeternumVault deployed successfully.");
    }
}
