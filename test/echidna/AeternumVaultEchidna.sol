// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AeternumVault} from "../../src/AeternumVault.sol";
import {IAeternumVault} from "../../src/interfaces/IAeternumVault.sol";

/**
 * @title  AeternumVaultEchidna
 * @author Ndubuisi Ugwuja
 * @notice Echidna property-based fuzz test suite for AeternumVault v1.
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
 *
 *         ACTORS
 *         ─────────────────────────────────────────────────────────────────────
 *         ACTOR1, ACTOR2, ACTOR3 — regular users (register, deposit, send, etc.)
 *         Addresses are fixed to match echidna.config.yml senders.
 */
contract AeternumVaultEchidna {
    /// --- STATE ---
    AeternumVault internal vault;

    /// @dev Fixed actor addresses — must match echidna.config.yml senders
    address internal constant ACTOR1 = address(0x1000000000000000000000000000000000000000);
    address internal constant ACTOR2 = address(0x2000000000000000000000000000000000000000);
    address internal constant ACTOR3 = address(0x3000000000000000000000000000000000000000);

    /// @dev Backup addresses — distinct from all actor addresses
    address internal constant BACKUP1 = address(0xB0000000000000000000000000000000000000B1);
    address internal constant BACKUP2 = address(0xB0000000000000000000000000000000000000B2);
    address internal constant BACKUP3 = address(0xB0000000000000000000000000000000000000b3);

    /// @dev Base inactivity period used for registration actions
    uint256 internal constant MIN_PERIOD = 180 days;

    /// --- CONSTRUCTOR ---
    constructor() payable {
        vault = new AeternumVault(
            180 days, // MIN_INACTIVITY_PERIOD
            3650 days, // MAX_INACTIVITY_PERIOD
            5000, // MAX_CHECK_UPKEEP_SIZE
            50, // MAX_PERFORM_UPKEEP_SIZE
            3, // MAX_RECOVERY_ATTEMPTS
            1 hours // CURSOR_ADVANCE_INTERVAL
        );
    }

    /// --- ACTOR HELPERS ---
    /// @dev Maps a fuzzed uint8 seed to one of three actor/backup pairs.
    function _toActor(uint8 seed) internal pure returns (address actor, address backup) {
        if (seed % 3 == 0) return (ACTOR1, BACKUP1);
        if (seed % 3 == 1) return (ACTOR2, BACKUP2);
        return (ACTOR3, BACKUP3);
    }

    /// @dev Returns true if actor is currently registered in the vault.
    function _isRegistered(address actor) internal view returns (bool) {
        return vault.isRegistered(actor);
    }

    /// --- FUZZED ACTIONS ---
    /**
     * @notice Register a vault for a fuzzed actor.
     * @dev    Sends 1 ETH as initial deposit. Echidna will call this with
     *         random `actorSeed` values to register different actors.
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
     * @param  amount Fuzzed send amount bounded to actor's vault balance.
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
     * @notice Ping a fuzzed actor's vault to reset inactivity timer.
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
     * @notice Cancel recovery for a fuzzed actor, withdrawing all escrowed ETH.
     */
    function action_cancelRecovery(uint8 actorSeed) external {
        (address actor,) = _toActor(actorSeed);
        if (!_isRegistered(actor)) return;

        try vault.cancelRecovery() {} catch {}
    }

    /**
     * @notice Trigger performUpkeep with a single fuzzed wallet candidate.
     * @dev    Uses the 3-tuple encoding (address[], uint256, bool) expected
     *         by performUpkeep. isIdleAdvance=false since we're simulating a
     *         recovery pass, not a cursor idle advance.
     */
    function action_performUpkeep(uint8 actorSeed) external {
        (address actor,) = _toActor(actorSeed);

        address[] memory wallets = new address[](1);
        wallets[0] = actor;

        try vault.performUpkeep(abi.encode(wallets, uint256(0), false)) {} catch {}
    }

    /// --- ECHIDNA PROPERTIES ---
    /**
     * @notice PROPERTY 1: Contract ETH balance must always be >= sum of all user vault balances.
     * @dev    With no fee model in v1, contract balance should equal the exact sum
     *         of user balances. >= is used to tolerate any ETH sent via selfdestruct.
     *         A violation means user funds have been lost or stolen.
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
     * @dev    A violation means a recovered or cancelled wallet was not removed from the registry.
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
     * @dev    Abandoned wallets must be permanently removed from the registry
     *         via _removeFromRegistry. isAbandoned and isActive being true
     *         simultaneously is impossible by design.
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
     */
    function echidna_registryLengthIsConsistent() external view returns (bool) {
        uint256 reported = vault.getTotalRegistered();
        address[] memory wallets = vault.getRegisteredWallets(0, reported);
        return wallets.length == reported;
    }

    /**
     * @notice PROPERTY 5: A wallet cannot be both active and abandoned simultaneously.
     * @dev    isActive and isAbandoned are mutually exclusive states.
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
     * @dev    The register() function enforces this. A violation means validation was bypassed.
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
     * @dev    v1 has a single minimum period for all users — no tier distinction.
     *         A violation means the minimum period validation was bypassed.
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
     * @dev    Both checkUpkeep and isRecoveryDue require balance > 0.
     *         A violation means zero-balance recovery could be triggered.
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
     * @dev    A violation means the ceiling validation was bypassed in register()
     *         or updateInactivityPeriod().
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
     * @dev    Once failedRecoveryAttempts reaches MAX, the wallet is abandoned and removed
     *         from the monitoring queue. A count above the max means abandonment logic failed.
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
     * @dev    On abandonment, _removeFromRegistry is called. Any abandoned wallet still present
     *         in s_registeredWallets indicates a registry corruption bug.
     */
    function echidna_abandonedWalletsNotInRegistry() external view returns (bool) {
        uint256 total = vault.getTotalRegistered();
        address[] memory wallets = vault.getRegisteredWallets(0, total);

        for (uint256 i = 0; i < wallets.length; i++) {
            if (vault.getRecoveryConfig(wallets[i]).isAbandoned) return false;
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
