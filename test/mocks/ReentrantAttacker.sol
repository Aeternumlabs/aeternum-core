// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAeternumVault} from "../../src/interfaces/IAeternumVault.sol";

/**
 * @title  ReentrantAttacker
 * @notice Simulates a malicious backup address that attempts to re-enter
 *         AeternumVault during the ETH transfer in `_executeRecovery`.
 *
 *         Attack vector:
 *           1. Attacker registers with this contract as the backup address.
 *           2. Inactivity period elapses.
 *           3. Chainlink calls `performUpkeep`, which calls `backupAddress.call{value}("")`.
 *           4. This contract's `receive()` triggers and attempts to call back into
 *              AeternumVault (e.g. withdraw, performUpkeep again).
 *           5. The reentrant call must revert due to ReentrancyGuard + CEI invariants.
 */
contract ReentrantAttacker {
    IAeternumVault public immutable target;
    address public immutable owner;

    bool public attackEnabled;
    uint256 public reentrancyAttempts;

    error Attacker__Unauthorized();

    constructor(address _target) {
        target = IAeternumVault(_target);
        owner = msg.sender;
    }

    /// @notice Register the attacker as the primary wallet with a specified backup address.
    function registerAsWallet(uint256 inactivityPeriod, address backup) external payable {
        if (msg.sender != owner) revert Attacker__Unauthorized();
        target.register{value: msg.value}(
            backup, inactivityPeriod, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );
    }

    /// @notice Toggle the reentrant attack on receipt of ETH.
    function enableAttack(bool enabled) external {
        if (msg.sender != owner) revert Attacker__Unauthorized();
        attackEnabled = enabled;
    }

    /**
     * @dev Called by AeternumVault when transferring recovered ETH to this contract.
     *      Attempts to re-enter AeternumVault if the attack is enabled.
     *      The attempt should always revert due to ReentrancyGuard.
     */
    receive() external payable {
        if (attackEnabled) {
            unchecked {
                ++reentrancyAttempts;
            }
            // Attempt 1: call performUpkeep with dummy data (should revert with ReentrancyGuard)
            try target.performUpkeep(abi.encode(new address[](0))) {} catch {}

            // Attempt 2: try to register a new config mid-execution
            try target.register{value: 0}(
                owner, 180 days, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
            ) {}
                catch {}
        }
    }

    /// @notice Let the owner drain any ETH received.
    function drain() external {
        if (msg.sender != owner) revert Attacker__Unauthorized();
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok, "drain failed");
    }
}
