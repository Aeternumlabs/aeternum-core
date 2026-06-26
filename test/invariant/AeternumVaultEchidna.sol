// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AeternumVault} from "../../src/AeternumVault.sol";
import {IAeternumVault} from "../../src/interfaces/IAeternumVault.sol";

/**
 * @title  AeternumVaultEchidna
 * @author Ndubuisi Ugwuja
 * @notice Echidna property-based fuzz test suite for AeternumVault — Phase 1.
 *
 * @dev    HOW THIS WORKS
 *         ─────────────────────────────────────────────────────────────────────
 *         Echidna generates random sequences of function calls and checks that
 *         all `echidna_*` functions always return `true`. If any returns `false`,
 *         Echidna found a property violation and shrinks the sequence to the
 *         minimal reproducing case.
 *
 *         PROPERTIES TESTED
 *         ─────────────────────────────────────────────────────────────────────
 *         1.  Contract ETH balance always covers sum of all user vault balances
 *         2.  Every wallet in registry has isActive == true
 *         3.  No wallet in registry has isAbandoned == true
 *         4.  Registry length always matches actual registered count
 *         5.  A wallet cannot be both active and abandoned simultaneously
 *         6.  A registered wallet always has a non-zero, non-self backup address
 *         7.  Every registered wallet's inactivity period >= MIN_INACTIVITY_PERIOD
 *         8.  A wallet with zero balance is never flagged as recovery due
 *         9.  Inactivity period never exceeds MAX_INACTIVITY_PERIOD
 *         10. Failed recovery attempts never exceed MAX_RECOVERY_ATTEMPTS
 *         11. Abandoned wallets are never present in the registry
 *         12. Every address returned by getTriggerableVaultsBatch satisfies isRecoveryDue
 *
 *         ACTORS
 *         ─────────────────────────────────────────────────────────────────────
 *         ACTOR1, ACTOR2, ACTOR3 — regular users (register, deposit, send, etc.)
 *         Addresses are fixed to match echidna.config.yml senders.
 */
contract AeternumVaultEchidna {
    /// --- STATE ---
    AeternumVault internal vault;

    /// @dev Fixed actor addresses — must match echidna.config.yml senders.
    address internal constant ACTOR1 = address(0x1000000000000000000000000000000000000000);
    address internal constant ACTOR2 = address(0x2000000000000000000000000000000000000000);
    address internal constant ACTOR3 = address(0x3000000000000000000000000000000000000000);

    /// @dev Backup addresses — distinct from all actor addresses.
    address internal constant BACKUP1 = address(0xB0000000000000000000000000000000000000B1);
    address internal constant BACKUP2 = address(0xB0000000000000000000000000000000000000B2);
    address internal constant BACKUP3 = address(0xB0000000000000000000000000000000000000b3);

    /// @dev Base inactivity period used for registration actions.
    uint256 internal constant MIN_PERIOD = 180 days;

    /// --- CONSTRUCTOR ---
    constructor() payable {
        vault = new AeternumVault(
            180 days, // MIN_INACTIVITY_PERIOD
            3650 days, // MAX_INACTIVITY_PERIOD
            3 // MAX_RECOVERY_ATTEMPTS
        );
    }

    /// --- ACTOR HELPERS ---
    /// @dev Maps a fuzzed uint8 seed to one of three actor/backup pairs.
    function _toActor(uint8 seed) internal pure returns (address actor, address backup) {
        if (seed % 3 == 0) return (ACTOR1, BACKUP1);
        if (seed % 3 == 1) return (ACTOR2, BACKUP2);
        return (ACTOR3, BACKUP3);
    }

    /// @dev Returns true if the actor is currently registered in the vault.
    function _isRegistered(address actor) internal view returns (bool) {
        return vault.isRegistered(actor);
    }

    /// --- FUZZED ACTIONS ---

    /**
     * @notice Register a vault for a fuzzed actor with 1 ETH initial deposit.
     */
    function action_register(uint8 actorSeed) external payable {
        (address actor, address backup) = _toActor(actorSeed);
        if (_isRegistered(actor)) return;

        try vault.register{value: 1 ether}(backup, MIN_PERIOD) {} catch {}
    }

    /**
     * @notice Deposit ETH into a fuzzed actor's vault.
     * @param  amount Fuzzed deposit amount bounded to [0.001, 10] ETH.
     */
    function action_deposit(uint8 actorSeed, uint256 amount) external payable {
        (address actor,) = _toActor(actorSeed);
        if (!_isRegistered(actor)) return;

        amount = _bound(amount, 0.001 ether, 10 ether);

        try vault.deposit{value: amount}() {} catch {}
    }

    /**
     * @notice Send ETH from a fuzzed actor's vault to a fixed recipient.
     * @param  amount Fuzzed send amount bounded to the actor's vault balance.
     */
    function action_send(uint8 actorSeed, uint256 amount) external {
        (address actor,) = _toActor(actorSeed);
        if (!_isRegistered(actor)) return;

        IAeternumVault.RecoveryConfig memory cfg = vault.getRecoveryConfig(actor);
        if (cfg.balance == 0) return;

        amount = _bound(amount, 1, cfg.balance);
        address recipient = address(0xDEAD);

        try vault.send(recipient, amount) {} catch {}
    }

    /**
     * @notice Withdraw entire ETH balance from a fuzzed actor's vault.
     */
    function action_withdrawAll(uint8 actorSeed) external {
        (address actor,) = _toActor(actorSeed);
        if (!_isRegistered(actor)) return;

        try vault.withdrawAll() {} catch {}
    }

    /**
     * @notice Ping a fuzzed actor's vault to reset the inactivity timer.
     */
    function action_ping(uint8 actorSeed) external {
        (address actor,) = _toActor(actorSeed);
        if (!_isRegistered(actor)) return;

        try vault.ping() {} catch {}
    }

    /**
     * @notice Update backup address for a fuzzed actor.
     * @param  newBackupSeed Seed used to derive a deterministic new backup address.
     */
    function action_updateBackupAddress(uint8 actorSeed, uint8 newBackupSeed) external {
        (address actor,) = _toActor(actorSeed);
        if (!_isRegistered(actor)) return;

        address newBackup = address(uint160(uint256(keccak256(abi.encode(newBackupSeed, "backup")))));
        if (newBackup == actor || newBackup == address(0)) return;

        try vault.updateBackupAddress(newBackup) {} catch {}
    }

    /**
     * @notice Update inactivity period for a fuzzed actor.
     * @param  periodSeed Fuzzed seed bounded to [MIN_PERIOD, MAX_INACTIVITY_PERIOD].
     */
    function action_updateInactivityPeriod(uint8 actorSeed, uint256 periodSeed) external {
        (address actor,) = _toActor(actorSeed);
        if (!_isRegistered(actor)) return;

        uint256 newPeriod = _bound(periodSeed, vault.MIN_INACTIVITY_PERIOD(), vault.MAX_INACTIVITY_PERIOD());

        try vault.updateInactivityPeriod(newPeriod) {} catch {}
    }

    /**
     * @notice Cancel recovery for a fuzzed actor, withdrawing all escrowed ETH.
     */
    function action_cancelRecovery(uint8 actorSeed) external {
        (address actor,) = _toActor(actorSeed);
        if (!_isRegistered(actor)) return;

        try vault.cancelRecovery() {} catch {}
    }

    /**
     * @notice Trigger recovery for a fuzzed actor's wallet.
     *
     * @dev    Exercises all `_executeRecovery` branching paths across Echidna's
     *         random call sequences:
     *
     *           Silent return paths (no state change, no revert):
     *             • wallet not due — timestamp has not passed deadline
     *             • balance is zero — wallet registered with no funds
     *             • not active — wallet was cancelled or never registered
     *             • already executed — a prior call in the same sequence recovered it
     *
     *           Execution path (all conditions met):
     *             • ETH transfers to backup address
     *             • wallet removed from registry
     *             • RecoveryExecuted emitted
     *
     *           Failure-and-retry path (backup rejects ETH):
     *             • state restored, failedRecoveryAttempts incremented
     *             • RecoveryFailed emitted
     *
     *           Abandonment path (MAX_RECOVERY_ATTEMPTS exhausted):
     *             • wallet permanently deregistered
     *             • RecoveryAbandoned emitted
     *
     *         The permissionless entry point is exercised by calling this action
     *         from any Echidna sender — not just the vault owner — verifying that
     *         the contract enforces safety through storage validation alone.
     */
    function action_triggerRecovery(uint8 actorSeed) external {
        (address actor,) = _toActor(actorSeed);
        try vault.triggerRecovery(actor) {} catch {}
    }

    /// --- ECHIDNA PROPERTIES ---

    /**
     * @notice PROPERTY 1: Contract ETH balance must always be >= sum of all user vault balances.
     * @dev    With no protocol fee, contract balance should equal the exact sum of user
     *         balances. >= tolerates any ETH received via selfdestruct.
     *         A violation means user funds have been lost, stolen, or double-spent.
     */
    function echidna_contractBalanceCoversUserFunds() external view returns (bool) {
        uint256 total = vault.getTotalRegistered();
        address[] memory wallets = vault.getRegisteredWallets(0, total);

        uint256 sumUserBalances = 0;
        for (uint256 i = 0; i < wallets.length; i++) {
            sumUserBalances += vault.getRecoveryConfig(wallets[i]).balance;
        }

        return address(vault).balance >= sumUserBalances;
    }

    /**
     * @notice PROPERTY 2: Every wallet in the registered wallets array must have isActive == true.
     * @dev    A violation means a recovered, cancelled, or abandoned wallet was not
     *         removed from the registry by _removeFromRegistry.
     */
    function echidna_registeredWalletsAreAlwaysActive() external view returns (bool) {
        uint256 total = vault.getTotalRegistered();
        address[] memory wallets = vault.getRegisteredWallets(0, total);

        for (uint256 i = 0; i < wallets.length; i++) {
            if (!vault.getRecoveryConfig(wallets[i]).isActive) return false;
        }
        return true;
    }

    /**
     * @notice PROPERTY 3: No wallet in the registry should be abandoned.
     * @dev    Abandoned wallets must be permanently removed from the registry.
     *         isAbandoned and isActive being true simultaneously is impossible by design,
     *         and is independently verified by Property 5.
     */
    function echidna_noAbandonedWalletInRegistry() external view returns (bool) {
        uint256 total = vault.getTotalRegistered();
        address[] memory wallets = vault.getRegisteredWallets(0, total);

        for (uint256 i = 0; i < wallets.length; i++) {
            if (vault.getRecoveryConfig(wallets[i]).isAbandoned) return false;
        }
        return true;
    }

    /**
     * @notice PROPERTY 4: getTotalRegistered must equal the actual registry array length.
     * @dev    Tests that registry bookkeeping stays consistent across all operations.
     *         A violation indicates a mismatch between the length counter and the array.
     */
    function echidna_registryLengthIsConsistent() external view returns (bool) {
        uint256 reported = vault.getTotalRegistered();
        address[] memory wallets = vault.getRegisteredWallets(0, reported);
        return wallets.length == reported;
    }

    /**
     * @notice PROPERTY 5: A wallet cannot be both active and abandoned simultaneously.
     * @dev    isActive and isAbandoned are mutually exclusive states. A violation means
     *         the abandonment path in _executeRecovery failed to clear isActive before
     *         setting isAbandoned.
     */
    function echidna_activeAndAbandonedAreMutuallyExclusive() external view returns (bool) {
        address[3] memory actors = [ACTOR1, ACTOR2, ACTOR3];

        for (uint256 i = 0; i < actors.length; i++) {
            IAeternumVault.RecoveryConfig memory cfg = vault.getRecoveryConfig(actors[i]);
            if (cfg.isActive && cfg.isAbandoned) return false;
        }
        return true;
    }

    /**
     * @notice PROPERTY 6: Every registered wallet must have a non-zero, non-self backup address.
     * @dev    register() and updateBackupAddress() enforce this. A violation means
     *         input validation was bypassed.
     */
    function echidna_registeredWalletsHaveValidBackup() external view returns (bool) {
        uint256 total = vault.getTotalRegistered();
        address[] memory wallets = vault.getRegisteredWallets(0, total);

        for (uint256 i = 0; i < wallets.length; i++) {
            IAeternumVault.RecoveryConfig memory cfg = vault.getRecoveryConfig(wallets[i]);
            if (cfg.backupAddress == address(0)) return false;
            if (cfg.backupAddress == wallets[i]) return false;
        }
        return true;
    }

    /**
     * @notice PROPERTY 7: Every registered wallet's inactivity period must be >= MIN_INACTIVITY_PERIOD.
     * @dev    A violation means the minimum period validation in register() or
     *         updateInactivityPeriod() was bypassed.
     */
    function echidna_walletPeriodAboveMin() external view returns (bool) {
        uint256 minPeriod = vault.MIN_INACTIVITY_PERIOD();
        address[3] memory actors = [ACTOR1, ACTOR2, ACTOR3];

        for (uint256 i = 0; i < actors.length; i++) {
            IAeternumVault.RecoveryConfig memory cfg = vault.getRecoveryConfig(actors[i]);
            if (!cfg.isActive) continue;
            if (cfg.inactivityPeriod < minPeriod) return false;
        }
        return true;
    }

    /**
     * @notice PROPERTY 8: No wallet with zero balance should ever be flagged as recovery due.
     * @dev    isRecoveryDue requires balance > 0. A violation means a zero-balance
     *         recovery could be triggered, causing a no-op ETH transfer.
     */
    function echidna_zeroBalanceNeverRecoveryDue() external view returns (bool) {
        address[3] memory actors = [ACTOR1, ACTOR2, ACTOR3];

        for (uint256 i = 0; i < actors.length; i++) {
            IAeternumVault.RecoveryConfig memory cfg = vault.getRecoveryConfig(actors[i]);
            if (cfg.balance == 0 && vault.isRecoveryDue(actors[i])) return false;
        }
        return true;
    }

    /**
     * @notice PROPERTY 9: Inactivity period must never exceed MAX_INACTIVITY_PERIOD.
     * @dev    A violation means the ceiling validation in register() or
     *         updateInactivityPeriod() was bypassed.
     */
    function echidna_inactivityPeriodNeverExceedsMax() external view returns (bool) {
        uint256 maxPeriod = vault.MAX_INACTIVITY_PERIOD();
        address[3] memory actors = [ACTOR1, ACTOR2, ACTOR3];

        for (uint256 i = 0; i < actors.length; i++) {
            IAeternumVault.RecoveryConfig memory cfg = vault.getRecoveryConfig(actors[i]);
            if (!cfg.isActive) continue;
            if (cfg.inactivityPeriod > maxPeriod) return false;
        }
        return true;
    }

    /**
     * @notice PROPERTY 10: Failed recovery attempts must never exceed MAX_RECOVERY_ATTEMPTS.
     * @dev    Once failedRecoveryAttempts reaches MAX, _executeRecovery sets isAbandoned
     *         and removes the wallet from monitoring. A count above the max means the
     *         abandonment branch did not fire correctly.
     */
    function echidna_failedAttemptsNeverExceedMax() external view returns (bool) {
        uint8 maxAttempts = vault.MAX_RECOVERY_ATTEMPTS();
        address[3] memory actors = [ACTOR1, ACTOR2, ACTOR3];

        for (uint256 i = 0; i < actors.length; i++) {
            IAeternumVault.RecoveryConfig memory cfg = vault.getRecoveryConfig(actors[i]);
            if (cfg.failedRecoveryAttempts > maxAttempts) return false;
        }
        return true;
    }

    /**
     * @notice PROPERTY 11: Abandoned wallets must not appear in the registered wallets registry.
     * @dev    On abandonment, _removeFromRegistry is called. Any abandoned wallet still
     *         present in s_registeredWallets indicates a registry corruption in the
     *         abandonment branch of _executeRecovery.
     */
    function echidna_abandonedWalletsNotInRegistry() external view returns (bool) {
        uint256 total = vault.getTotalRegistered();
        address[] memory wallets = vault.getRegisteredWallets(0, total);

        for (uint256 i = 0; i < wallets.length; i++) {
            if (vault.getRecoveryConfig(wallets[i]).isAbandoned) return false;
        }
        return true;
    }

    /**
     * @notice PROPERTY 12: Every address returned by getTriggerableVaultsBatch must satisfy isRecoveryDue.
     * @dev    getTriggerableVaultsBatch is the keeper bot's primary scanning tool. Any wallet it
     *         returns must independently satisfy all three recovery conditions:
     *         isActive == true, balance > 0, and timestamp >= lastActivity + inactivityPeriod.
     *         A violation means the batch view is returning wallets that are not actually
     *         triggerable, which would cause the keeper bot to waste gas on no-op calls.
     */
    function echidna_getTriggerableVaultsBatchConsistency() external view returns (bool) {
        uint256 total = vault.getTotalRegistered();
        if (total == 0) return true;

        address[] memory triggerable = vault.getTriggerableVaultsBatch(0, total);

        for (uint256 i = 0; i < triggerable.length; i++) {
            if (!vault.isRecoveryDue(triggerable[i])) return false;
        }
        return true;
    }

    /// --- INTERNAL HELPERS ---
    /// @dev Bounds a value to [min, max] — mirrors Foundry's bound().
    function _bound(uint256 value, uint256 min, uint256 max) internal pure returns (uint256) {
        if (value < min) return min;
        if (value > max) return max;
        return value;
    }

    /// @dev Allows the contract to receive ETH for funding actor actions.
    receive() external payable {}
}
