// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IAeternumVault} from "../../src/interfaces/IAeternumVault.sol";

/**
 * @title  ReentrantAttacker
 * @notice Simulates a malicious backup address that attempts to re-enter
 *         AeternumVault during the ETH transfer in `_executeRecovery`.
 *
 *         ATTACK MODEL
 *         ─────────────────────────────────────────────────────────────────────
 *         This contract is deployed as the BACKUP ADDRESS for a victim wallet,
 *         not as the vault owner. The attack sequence is:
 *
 *           1. A victim wallet registers with address(this) as its backup.
 *           2. The victim's inactivity period elapses.
 *           3. A keeper calls `triggerRecovery(victim)`.
 *           4. `_executeRecovery` applies CEI effects — config.balance = 0,
 *              config.isActive = false — then fires the external ETH transfer
 *              to this contract.
 *           5. This contract's `receive()` fires and attempts to re-enter
 *              `triggerRecovery(victimWallet)` for the same wallet.
 *           6. The reentrant call is defeated by two independent layers:
 *                a. `nonReentrant` on `triggerRecovery` reverts the call
 *                   (ReentrancyGuard _status == ENTERED).
 *                b. CEI — config.balance is already 0 before the external call,
 *                   so even without nonReentrant, _executeRecovery would hit
 *                   the `balance == 0` guard and silently return.
 *           7. Both failures are swallowed by try/catch so that `receive()`
 *              itself does not revert, letting the outer ETH transfer complete
 *              and exposing the full post-execution state for test assertions.
 *
 *         WHY NOT REGISTER AS VAULT OWNER?
 *         ─────────────────────────────────────────────────────────────────────
 *         If this contract registers as the vault owner with a plain EOA backup,
 *         ETH flows to that EOA — this contract's receive() is never invoked and
 *         the reentrancy path is never exercised. The attack must originate from
 *         the backup address to fire the callback.
 */
contract ReentrantAttacker {
    IAeternumVault public immutable target;
    address public immutable owner;

    bool public attackEnabled;
    uint256 public reentrancyAttempts;

    /// @dev The wallet address to re-target in the reentrant callback.
    ///      Set this to the victim wallet before triggering recovery.
    address public victimWallet;

    error Attacker__Unauthorized();

    constructor(address _target) {
        target = IAeternumVault(_target);
        owner = msg.sender;
    }

    /// @notice Set the wallet address to re-enter during the ETH callback.
    /// @param  wallet The victim vault whose recovery we attempt to re-trigger.
    function setVictimWallet(address wallet) external {
        if (msg.sender != owner) revert Attacker__Unauthorized();
        victimWallet = wallet;
    }

    /// @notice Toggle the reentrant attack on receipt of ETH.
    function enableAttack(bool enabled) external {
        if (msg.sender != owner) revert Attacker__Unauthorized();
        attackEnabled = enabled;
    }

    /**
     * @dev Fired by AeternumVault when transferring recovered ETH to this contract.
     *      Attempts two reentrant calls if the attack is armed.
     *
     *      Expected outcomes:
     *        `triggerRecovery` — reverts via ReentrancyGuard (ENTERED state).
     *                            Even if ReentrancyGuard were absent, CEI ensures
     *                            config.balance == 0 at this point, causing a
     *                            silent return through the balance guard.
     *        `register`        — reverts via ReentrancyGuard (ENTERED state).
     *
     *      Both reverts are caught so `receive()` itself succeeds, allowing the
     *      outer ETH transfer to complete and `reentrancyAttempts` to be read
     *      by the test to confirm the attack path was actually reached.
     */
    receive() external payable {
        if (attackEnabled && victimWallet != address(0)) {
            unchecked {
                ++reentrancyAttempts;
            }

            // Attempt 1: re-enter triggerRecovery for the same wallet mid-execution.
            // Both nonReentrant and CEI independently defeat this.
            try target.triggerRecovery(victimWallet) {} catch {}

            // Attempt 2: register mid-execution as a secondary reentrancy vector.
            // Blocked by nonReentrant on register().
            try target.register{value: 0}(owner, 180 days) {} catch {}
        }
    }

    /// @notice Let the owner drain any ETH this contract has received.
    function drain() external {
        if (msg.sender != owner) revert Attacker__Unauthorized();
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok, "drain failed");
    }
}
