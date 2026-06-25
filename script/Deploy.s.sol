// SPDX-License-Identifier: BUSL-1.1
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
 *   # Sepolia testnet (dry-run first — recommended)
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
 *   # Mainnet (ALWAYS dry-run first, never broadcast without a prior simulation)
 *   forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL -vvvv
 *
 *   # Post-deployment:
 *   1. Copy the deployed contract address into .env as CONTRACT_ADDRESS.
 *   2. Set NEXT_PUBLIC_SEPOLIA_CONTRACT_ADDRESS in the frontend .env.
 *   3. Update the Ponder indexer start block and contract address in ponder.config.ts.
 *   4. Start the keeper bot (pointing it at the new contract address and Ponder instance).
 *      The bot begins monitoring immediately — no on-chain registration required.
 *   5. Verify the contract is live and the bot is submitting by calling
 *      `getTotalRegistered()` and registering a test vault with a short inactivity
 *      period to confirm end-to-end recovery.
 */
contract Deploy is Script {
    function run() external returns (AeternumVault aeternumVault, HelperConfig helperConfig) {
        helperConfig = new HelperConfig();
        HelperConfig.VaultConfig memory cfg = helperConfig.getConfig();

        console2.log("\n=== AeternumVault Deployment ===");
        console2.log("Deployer:               ", msg.sender);
        console2.log("Chain ID:               ", block.chainid);
        console2.log("Block:                  ", block.number);
        console2.log("Timestamp:              ", block.timestamp);
        console2.log("MIN_PERIOD (s):         ", cfg.minInactivityPeriod);
        console2.log("MAX_PERIOD (s):         ", cfg.maxInactivityPeriod);
        console2.log("MAX_RECOVERY_ATTEMPTS:  ", cfg.maxRecoveryAttempts);

        vm.startBroadcast();
        aeternumVault = new AeternumVault(cfg.minInactivityPeriod, cfg.maxInactivityPeriod, cfg.maxRecoveryAttempts);
        vm.stopBroadcast();

        _verifyDeployment(aeternumVault, cfg);
    }

    function _verifyDeployment(AeternumVault rm, HelperConfig.VaultConfig memory cfg) internal view {
        console2.log("\n=== Post-Deploy Verification ===");
        console2.log("Contract address:       ", address(rm));
        console2.log("Total registered:       ", rm.getTotalRegistered());
        console2.log("MIN_INACTIVITY_PERIOD:  ", rm.MIN_INACTIVITY_PERIOD());
        console2.log("MAX_INACTIVITY_PERIOD:  ", rm.MAX_INACTIVITY_PERIOD());
        console2.log("MAX_RECOVERY_ATTEMPTS:  ", rm.MAX_RECOVERY_ATTEMPTS());

        require(rm.MIN_INACTIVITY_PERIOD() == cfg.minInactivityPeriod, "Deploy: minInactivityPeriod mismatch");
        require(rm.MAX_INACTIVITY_PERIOD() == cfg.maxInactivityPeriod, "Deploy: maxInactivityPeriod mismatch");
        require(rm.MAX_RECOVERY_ATTEMPTS() == cfg.maxRecoveryAttempts, "Deploy: maxRecoveryAttempts mismatch");
        require(rm.getTotalRegistered() == 0, "Deploy: unexpected registrations on fresh deployment");

        console2.log("\nAll assertions passed. AeternumVault deployed successfully.");
    }
}
