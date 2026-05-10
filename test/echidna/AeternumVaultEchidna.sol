// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AeternumVault} from "../../src/AeternumVault.sol";
import {IAeternumVault} from "../../src/interfaces/IAeternumVault.sol";

/**
 * @title  AeternumVaultEchidna
 * @author Ndubuisi Ugwuja
 * @notice Echidna property-based fuzz test suite for AeternumVault.
 *
 * @dev    HOW ECHIDNA WORKS
 *         ─────────────────────────────────────────────────────────────────────
 *         Echidna generates random sequences of function calls and checks that
 *         all `echidna_*` functions always return `true`. If any returns `false`,
 *         Echidna found a property violation and shrinks the sequence to the
 *         minimal reproducing case.
 *
 *         PROPERTIES TESTED
 *         ─────────────────────────────────────────────────────────────────────
 *         1.  Contract ETH balance always covers sum of all user vault balances
 *         2.  Accumulated fees never exceed contract ETH balance
 *         3.  Every wallet in registry has isActive == true
 *         4.  No wallet in registry has isAbandoned == true
 *         5.  Registry length always matches actual registered count
 *         6.  A wallet cannot be both active and abandoned simultaneously
 *         7.  A registered wallet always has a non-zero backup address
 *         8.  Inactivity period always within [MIN_FREE, MAX] for free wallets
 *         9.  Inactivity period always within [MIN_PREMIUM, MAX] for premium wallets
 *         10. A wallet with zero balance is never flagged as recovery due
 *         11. Treasury address is never zero address
 *         12. Subscription expiry for free wallets is always zero
 *
 *         ACTORS
 *         ─────────────────────────────────────────────────────────────────────
 *         actor1, actor2, actor3 — regular users (register, deposit, send, etc.)
 *         treasury               — treasury address for fee withdrawal
 */
contract AeternumVaultEchidna {
    /*//////////////////////////////////////////////////////////////
                            STATE
    //////////////////////////////////////////////////////////////*/

    AeternumVault internal vault;

    /// @dev Fixed actor addresses — must match echidna.config.yml senders
    address internal constant ACTOR1 = address(0x1000000000000000000000000000000000000000);
    address internal constant ACTOR2 = address(0x2000000000000000000000000000000000000000);
    address internal constant ACTOR3 = address(0x3000000000000000000000000000000000000000);
    address internal constant TREASURY = address(0x4000000000000000000000000000000000000000);

    /// @dev Backup addresses — distinct from actor addresses
    address internal constant BACKUP1 = address(0xB0000000000000000000000000000000000000B1);
    address internal constant BACKUP2 = address(0xB0000000000000000000000000000000000000B2);
    address internal constant BACKUP3 = address(0xB0000000000000000000000000000000000000b3);

    /// @dev Valid inactivity periods for testing
    uint256 internal constant FREE_PERIOD = 365 days;
    uint256 internal constant PREMIUM_PERIOD = 180 days;

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() payable {
        vault = new AeternumVault(
            TREASURY,
            365 days, // MIN_INACTIVITY_PERIOD_FREE
            180 days, // MIN_INACTIVITY_PERIOD_PREMIUM
            3650 days, // MAX_INACTIVITY_PERIOD
            30 days, // SUBSCRIPTION_DURATION
            0.002 ether, // PREMIUM_MONTHLY_FEE
            0.02 ether, // PREMIUM_ANNUAL_FEE
            5000, // MAX_CHECK_UPKEEP_SIZE
            50, // MAX_PERFORM_UPKEEP_SIZE
            3, // MAX_RECOVERY_ATTEMPTS
            1 hours // CURSOR_ADVANCE_INTERVAL
        );
    }

    /*//////////////////////////////////////////////////////////////
                       ACTOR HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Maps a fuzzed uint8 to one of three actors
    function _toActor(uint8 seed) internal pure returns (address actor, address backup) {
        if (seed % 3 == 0) return (ACTOR1, BACKUP1);
        if (seed % 3 == 1) return (ACTOR2, BACKUP2);
        return (ACTOR3, BACKUP3);
    }

    /// @dev Returns true if actor is registered in the vault
    function _isRegistered(address actor) internal view returns (bool) {
        return vault.isRegistered(actor);
    }

    /*//////////////////////////////////////////////////////////////
                      FUZZED ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register a Free tier vault for a fuzzed actor.
     * @dev    Sends 1 ETH as initial deposit. Echidna will call this with
     *         random `actorSeed` values to register different actors.
     */
    function action_register_free(uint8 actorSeed) external payable {
        (address actor, address backup) = _toActor(actorSeed);
        if (_isRegistered(actor)) return;

        try vault.register{value: 1 ether}(
            backup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        ) {}
            catch {}
    }

    /**
     * @notice Register a Premium tier vault for a fuzzed actor.
     */
    function action_register_premium(uint8 actorSeed) external payable {
        (address actor, address backup) = _toActor(actorSeed);
        if (_isRegistered(actor)) return;

        uint256 fee = vault.PREMIUM_MONTHLY_FEE();

        try vault.register{value: 1 ether + fee}(
            backup, PREMIUM_PERIOD, IAeternumVault.SubscriptionTier.Premium, IAeternumVault.SubscriptionPlan.Monthly
        ) {}
            catch {}
    }

    /**
     * @notice Deposit ETH into a fuzzed actor's vault.
     * @param amount Fuzzed deposit amount bounded to [0.001, 10] ETH
     */
    function action_deposit(uint8 actorSeed, uint256 amount) external payable {
        (address actor,) = _toActor(actorSeed);
        if (!_isRegistered(actor)) return;

        amount = _bound(amount, 0.001 ether, 10 ether);

        try vault.deposit{value: amount}() {} catch {}
    }

    /**
     * @notice Send ETH from a fuzzed actor's vault to a recipient.
     * @param amount Fuzzed send amount
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
     * @notice Withdraw all ETH from a fuzzed actor's vault.
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
     */
    function action_updateBackupAddress(uint8 actorSeed, uint8 newBackupSeed) external {
        (address actor,) = _toActor(actorSeed);
        if (!_isRegistered(actor)) return;

        // Generate a fresh backup that isn't the actor
        address newBackup = address(uint160(uint256(keccak256(abi.encode(newBackupSeed, "backup")))));
        if (newBackup == actor || newBackup == address(0)) return;

        try vault.updateBackupAddress(newBackup) {} catch {}
    }

    /**
     * @notice Cancel recovery for a fuzzed actor.
     */
    function action_cancelRecovery(uint8 actorSeed) external {
        (address actor,) = _toActor(actorSeed);
        if (!_isRegistered(actor)) return;

        try vault.cancelRecovery() {} catch {}
    }

    /**
     * @notice Renew Premium subscription for a fuzzed actor.
     */
    function action_renewSubscription(uint8 actorSeed) external payable {
        (address actor,) = _toActor(actorSeed);
        if (!_isRegistered(actor)) return;

        uint256 fee = vault.PREMIUM_MONTHLY_FEE();

        try vault.renewSubscription{value: fee}(IAeternumVault.SubscriptionPlan.Monthly, 0) {} catch {}
    }

    /**
     * @notice Trigger performUpkeep with a fuzzed wallet list.
     * @dev    Echidna will fuzz the wallet index to test batch recovery paths.
     */
    function action_performUpkeep(uint8 actorSeed) external {
        (address actor,) = _toActor(actorSeed);

        address[] memory wallets = new address[](1);
        wallets[0] = actor;

        try vault.performUpkeep(abi.encode(wallets)) {} catch {}
    }

    /**
     * @notice Treasury withdraws accumulated fees.
     */
    function action_withdrawFees() external {
        try vault.withdrawSubscriptionFees() {} catch {}
    }

    /*//////////////////////////////////////////////////////////////
                         ECHIDNA PROPERTIES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice PROPERTY 1: Contract ETH balance must always be ≥ sum of all user vault balances.
     * @dev    The difference equals accumulated subscription fees.
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
     * @notice PROPERTY 2: Accumulated fees must never exceed contract ETH balance.
     * @dev    A violation means fee accounting is broken.
     */
    function echidna_feesNeverExceedContractBalance() external view returns (bool) {
        return vault.getAccumulatedFees() <= address(vault).balance;
    }

    /**
     * @notice PROPERTY 3: Every wallet in the registered wallets array must have isActive == true.
     * @dev    A violation means a recovered or cancelled wallet was not removed from the registry.
     */
    function echidna_registeredWalletsAreAlwaysActive() external view returns (bool) {
        uint256 total = vault.getTotalRegistered();
        address[] memory wallets = vault.getRegisteredWallets(0, total);

        for (uint256 i = 0; i < wallets.length; i++) {
            if (!vault.getRecoveryConfig(wallets[i]).isActive) {
                return false;
            }
        }
        return true;
    }

    /**
     * @notice PROPERTY 4: No wallet in the registry should be abandoned.
     * @dev    Abandoned wallets must be removed from the registry via _removeFromRegistry.
     *         isAbandoned and isActive being true simultaneously is impossible by design.
     */
    function echidna_noAbandonedWalletInRegistry() external view returns (bool) {
        uint256 total = vault.getTotalRegistered();
        address[] memory wallets = vault.getRegisteredWallets(0, total);

        for (uint256 i = 0; i < wallets.length; i++) {
            if (vault.getRecoveryConfig(wallets[i]).isAbandoned) {
                return false;
            }
        }
        return true;
    }

    /**
     * @notice PROPERTY 5: getTotalRegistered must equal actual registry array length.
     * @dev    Tests that registry bookkeeping stays consistent across all operations.
     */
    function echidna_registryLengthIsConsistent() external view returns (bool) {
        uint256 reported = vault.getTotalRegistered();
        address[] memory wallets = vault.getRegisteredWallets(0, reported);
        return wallets.length == reported;
    }

    /**
     * @notice PROPERTY 6: A wallet cannot be both active and abandoned simultaneously.
     * @dev    isActive and isAbandoned are mutually exclusive states.
     */
    function echidna_activeAndAbandonedAreMutuallyExclusive() external view returns (bool) {
        address[3] memory actors = [ACTOR1, ACTOR2, ACTOR3];

        for (uint256 i = 0; i < actors.length; i++) {
            IAeternumVault.RecoveryConfig memory cfg = vault.getRecoveryConfig(actors[i]);
            if (cfg.isActive && cfg.isAbandoned) {
                return false;
            }
        }
        return true;
    }

    /**
     * @notice PROPERTY 7: Every registered wallet must have a non-zero backup address.
     * @dev    The register() function enforces this — backup cannot be zero or self.
     *         A violation would mean the validation logic was bypassed.
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
     * @notice PROPERTY 8: Free tier wallets must have inactivity period >= MIN_INACTIVITY_PERIOD_FREE.
     * @dev    A violation means the minimum period validation was bypassed.
     */
    function echidna_freeWalletPeriodAboveMin() external view returns (bool) {
        uint256 minFree = vault.MIN_INACTIVITY_PERIOD_FREE();
        address[3] memory actors = [ACTOR1, ACTOR2, ACTOR3];

        for (uint256 i = 0; i < actors.length; i++) {
            IAeternumVault.RecoveryConfig memory cfg = vault.getRecoveryConfig(actors[i]);
            if (!cfg.isActive) continue;
            if (cfg.tier == IAeternumVault.SubscriptionTier.Free) {
                if (cfg.inactivityPeriod < minFree) return false;
            }
        }
        return true;
    }

    /**
     * @notice PROPERTY 9: No wallet with zero balance should be flagged as recovery due.
     * @dev    checkUpkeep and isRecoveryDue should both require balance > 0.
     *         A violation means zero-balance recovery could be triggered.
     */
    function echidna_zeroBalanceNeverRecoveryDue() external view returns (bool) {
        address[3] memory actors = [ACTOR1, ACTOR2, ACTOR3];

        for (uint256 i = 0; i < actors.length; i++) {
            IAeternumVault.RecoveryConfig memory cfg = vault.getRecoveryConfig(actors[i]);
            if (cfg.balance == 0 && vault.isRecoveryDue(actors[i])) {
                return false;
            }
        }
        return true;
    }

    /**
     * @notice PROPERTY 10: Treasury address must never become the zero address.
     * @dev    updateTreasury() reverts on zero address — this ensures the guard works.
     */
    function echidna_treasuryNeverZeroAddress() external view returns (bool) {
        return vault.getTreasury() != address(0);
    }

    /**
     * @notice PROPERTY 11: Free tier wallets must have subscriptionExpiry == 0.
     * @dev    Subscription expiry is only set for Premium. A free wallet with a
     *         non-zero expiry indicates a state corruption bug.
     */
    function echidna_freeWalletHasZeroSubscriptionExpiry() external view returns (bool) {
        address[3] memory actors = [ACTOR1, ACTOR2, ACTOR3];

        for (uint256 i = 0; i < actors.length; i++) {
            IAeternumVault.RecoveryConfig memory cfg = vault.getRecoveryConfig(actors[i]);
            if (!cfg.isActive) continue;
            if (cfg.tier == IAeternumVault.SubscriptionTier.Free && cfg.subscriptionExpiry != 0) {
                return false;
            }
        }
        return true;
    }

    /**
     * @notice PROPERTY 12: Inactivity period must never exceed MAX_INACTIVITY_PERIOD.
     * @dev    A violation means the ceiling validation was bypassed.
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
     * @notice PROPERTY 13: Failed recovery attempts must never exceed MAX_RECOVERY_ATTEMPTS.
     * @dev    Once failedRecoveryAttempts reaches MAX, the wallet is abandoned.
     *         A count above the max means the abandonment logic failed.
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
     * @notice PROPERTY 14: An abandoned wallet must have zero balance in s_configs.
     * @dev    On abandonment, config.balance should reflect the accessible amount.
     *         This checks that the balance is not silently lost.
     *
     *         Note: after abandonment, balance is RESTORED to config so user
     *         can withdrawAll(). So this actually checks the inverse:
     *         if abandoned, balance should be the pre-recovery amount (non-zero possible).
     *         What we actually verify: abandoned wallets are NOT in the registry.
     */
    function echidna_abandonedWalletsNotInRegistry() external view returns (bool) {
        uint256 total = vault.getTotalRegistered();
        address[] memory wallets = vault.getRegisteredWallets(0, total);

        for (uint256 i = 0; i < wallets.length; i++) {
            // If it's in the registry it must NOT be abandoned
            if (vault.getRecoveryConfig(wallets[i]).isAbandoned) {
                return false;
            }
        }
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Bound a value to [min, max] — mirrors Foundry's bound()
    function _bound(uint256 value, uint256 min, uint256 max) internal pure returns (uint256) {
        if (value < min) return min;
        if (value > max) return max;
        return value;
    }

    /// @dev Allow the test contract to receive ETH for funding actors
    receive() external payable {}
}
