// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {RecoveryManager} from "../src/RecoveryManager.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

/**
 * @title  Deploy
 * @notice Deploys RecoveryManager with the correct treasury for the target network.
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

    function run() external returns (RecoveryManager recoveryManager, HelperConfig helperConfig) {
        helperConfig = new HelperConfig();
        address treasury = helperConfig.getTreasuryAddress();

        // Sanity check before spending gas
        require(treasury != address(0), "Deploy: treasury is zero address");

        // Log pre-deployment info
        console2.log("\n=== RecoveryManager Deployment ===");
        console2.log("Deployer:  ", msg.sender);
        console2.log("Treasury:  ", treasury);
        console2.log("Chain ID:  ", block.chainid);
        console2.log("Block:     ", block.number);
        console2.log("Timestamp: ", block.timestamp);

        // ── Deploy ──────────────────────────────────────────────────────────
        vm.startBroadcast();
        recoveryManager = new RecoveryManager(treasury);
        vm.stopBroadcast();

        // ── Post-deploy verification ─────────────────────────────────────────
        _verifyDeployment(recoveryManager, treasury);
    }

    /*//////////////////////////////////////////////////////////////
                      POST-DEPLOY CHECKS
    //////////////////////////////////////////////////////////////*/

    function _verifyDeployment(RecoveryManager rm, address expectedTreasury) internal view {
        console2.log("\n=== Post-Deploy Verification ===");
        console2.log("Contract address:  ", address(rm));
        console2.log("Treasury:          ", rm.getTreasury());
        console2.log("Total registered:  ", rm.getTotalRegistered());
        console2.log("Accumulated fees:  ", rm.getAccumulatedFees());
        console2.log("MAX_BATCH_SIZE:    ", rm.MAX_BATCH_SIZE());
        console2.log("PREMIUM_FEE (wei): ", rm.PREMIUM_MONTHLY_FEE());
        console2.log("MIN_FREE (days):   ", rm.MIN_INACTIVITY_PERIOD_FREE() / 1 days);
        console2.log("MIN_PREMIUM (days):", rm.MIN_INACTIVITY_PERIOD_PREMIUM() / 1 days);

        // Assertions (will revert the script if anything is wrong)
        require(rm.getTreasury() == expectedTreasury, "Deploy: treasury mismatch");
        require(rm.getTotalRegistered() == 0, "Deploy: unexpected registrations");
        require(rm.getAccumulatedFees() == 0, "Deploy: unexpected fees");

        console2.log("\nAll assertions passed. RecoveryManager deployed successfully.");
    }
}
