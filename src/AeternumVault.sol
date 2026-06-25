// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAeternumVault} from "./interfaces/IAeternumVault.sol";

/**
 * @title  AeternumVault
 * @author Ndubuisi Ugwuja
 * @notice A non-custodial, automated inheritance protocol for Ethereum assets.
 *
 *
 * @dev    SYSTEM OVERVIEW
 *         ─────────────────────────────────────────────────────────────────────
 *         1. Users call `register()` with a backup address and an inactivity period,
 *            optionally depositing ETH into the contract's escrow at the same time.
 *         2. The contract tracks each user's `lastActivity` timestamp. Any on-chain
 *            interaction with this contract (ping, deposit, withdraw, config update)
 *            resets the timer.
 *         3. When a wallet's inactivity period elapses and its balance is non-zero,
 *            any external actor may call `triggerRecovery(wallet)` to transfer the
 *            escrowed ETH to the registered backup address. The Aeternum keeper
 *            bot monitors all registered wallets via the Ponder indexer and calls
 *            this function automatically, ensuring fully automated recovery without
 *            any action required from users or beneficiaries. The function is
 *            permissionless as a liveness guarantee: if the primary keeper is
 *            unavailable, any party — including the beneficiary — may call it.
 *         4. Users may cancel at any time via `cancelRecovery()`, which refunds their
 *            entire balance and removes them from monitoring.
 *
 *         KEEPER ARCHITECTURE
 *         ─────────────────────────────────────────────────────────────────────
 *         Phase 1: Aeternum Labs operates a keeper bot as a public good. The bot
 *           monitors all registered wallets via the Ponder indexer and calls
 *           `triggerRecovery(wallet)` when conditions are met. Gas costs are
 *           absorbed as a protocol operating expense. No third-party dependency.
 *
 *         Phase 2: Gelato Network added as a decentralised backup keeper alongside
 *           the Aeternum Labs bot. Independent failure modes guarantee liveness.
 *           `triggerRecovery` interface is unchanged.
 *
 *         Phase 3: CRE (Chainlink Runtime Environment) added for cross-chain vault
 *           coordination. `triggerRecovery(wallet)` remains the single entry point
 *           on all chains — CRE is simply another permissionless caller.
 *
 *         TRUST MODEL
 *         ─────────────────────────────────────────────────────────────────────
 *         • No admin or owner to pause recovery, redirect funds, or change user configs.
 *         • Recovery is automated by the Aeternum keeper bot and permissionless
 *           at the contract level — any actor may call `triggerRecovery(wallet)`.
 *         • The caller of `triggerRecovery` cannot redirect funds, force early
 *           recovery, or cause double-spend. All safety decisions are made exclusively
 *           from storage written by the vault owner. The caller is a trigger,
 *           not an authority.
 *         • All state changes follow the Checks-Effects-Interactions (CEI) pattern.
 *         • ReentrancyGuard provides a secondary reentrancy defence layer.
 *
 *         SECURITY CONSIDERATIONS
 *         ─────────────────────────────────────────────────────────────────────
 *         • Reentrancy: guarded by ReentrancyGuard + CEI on all ETH-transferring paths.
 *         • Integer overflow: Solidity ≥0.8 reverts on overflow by default.
 *         • Permissionless safety: `triggerRecovery` delegates entirely to
 *           `_executeRecovery`, which re-validates all conditions before acting.
 *           The caller supplies only a wallet address — they control nothing about
 *           whether, when, how much, or where funds move.
 *         • Silent return: `triggerRecovery` does not revert when conditions are
 *           unmet, so competing keepers do not waste gas on already-executed
 *           recoveries or ineligible wallets.
 *         • Array manipulation: swap-and-pop O(1) removal keeps indices consistent
 *           across concurrent recovery executions.
 *         • Direct ETH transfers: a `receive()` function explicitly reverts with a
 *           clear error, preventing accidental fund loss.
 */
contract AeternumVault is IAeternumVault, ReentrancyGuard {
    /// --- IMMUTABLES ---
    /// @notice Minimum inactivity period allowed.
    uint256 public immutable MIN_INACTIVITY_PERIOD;

    /// @notice Hard ceiling on inactivity period (prevents permanent lock-up).
    uint256 public immutable MAX_INACTIVITY_PERIOD;

    /// @notice Maximum consecutive failed recovery attempts before a wallet is abandoned.
    uint8 public immutable MAX_RECOVERY_ATTEMPTS;

    /// --- STATE VARIABLES ---
    /// @dev Primary configuration store. Key: registered wallet address.
    mapping(address => RecoveryConfig) private s_configs;

    /**
     * @dev Ordered list of all registered wallet addresses.
     *      Consumed by `checkVaultsBatch` for keeper scanning; mutated by
     *      `_removeFromRegistry` using swap-and-pop for O(1) removal.
     */
    address[] private s_registeredWallets;

    /**
     * @dev 1-indexed position of each wallet in `s_registeredWallets`.
     *      A value of 0 means the wallet is NOT in the array.
     *      Stored as 1-indexed so the zero-value naturally represents "absent".
     */
    mapping(address => uint256) private s_walletIndexPlusOne;

    /**
     * @dev Backup addresses proven to reject ETH after MAX_RECOVERY_ATTEMPTS.
     *      Any registration or backup update pointing to these addresses is
     *      permanently blocked.
     */
    mapping(address => bool) private s_abandonedBackupAddresses;

    /// --- MODIFIERS ---
    /// @dev Reverts if the caller does not have an active or abandoned recovery config.
    modifier onlyRegistered() {
        if (!s_configs[msg.sender].isActive && !s_configs[msg.sender].isAbandoned) {
            revert AeternumVault__NotRegistered();
        }
        _;
    }

    /// --- CONSTRUCTOR ---
    /**
     * @notice Initialises the vault with all immutable configuration.
     *
     * @param minInactivityPeriod_  Minimum inactivity period (seconds).
     * @param maxInactivityPeriod_  Hard ceiling on inactivity period (seconds).
     * @param maxRecoveryAttempts_  Max consecutive failed attempts before abandonment.
     */
    constructor(uint256 minInactivityPeriod_, uint256 maxInactivityPeriod_, uint8 maxRecoveryAttempts_) {
        if (minInactivityPeriod_ == 0) revert AeternumVault__InvalidInactivityPeriod();
        if (maxInactivityPeriod_ < minInactivityPeriod_) revert AeternumVault__InvalidInactivityPeriod();
        if (maxRecoveryAttempts_ == 0) revert AeternumVault__MaxRecoveryAttemptsExceeded();

        MIN_INACTIVITY_PERIOD = minInactivityPeriod_;
        MAX_INACTIVITY_PERIOD = maxInactivityPeriod_;
        MAX_RECOVERY_ATTEMPTS = maxRecoveryAttempts_;
    }

    /// --- USER-FACING FUNCTIONS ---
    /**
     * @notice Register a wallet for recovery.
     *
     * @dev    The caller's address is treated as the "primary wallet" being protected.
     *         Registration with 0 balance is valid; the user can `deposit()` later.
     *
     *         Emits {RecoveryRegistered} and, if ETH is deposited, {Deposited}.
     *
     * @param backupAddress    Address that will receive funds if recovery is triggered.
     *                         Must not be zero, the caller's own address, or an
     *                         abandoned backup address.
     * @param inactivityPeriod Seconds without activity before recovery executes.
     */
    function register(address backupAddress, uint256 inactivityPeriod) external payable nonReentrant {
        // Checks
        if (s_configs[msg.sender].isActive) revert AeternumVault__AlreadyRegistered();
        if (s_abandonedBackupAddresses[backupAddress]) revert AeternumVault__WalletAbandoned();
        // If wallet was previously abandoned and user skipped withdrawAll(), carry
        // the existing balance forward so it is not permanently locked in the contract.
        uint256 carriedBalance = s_configs[msg.sender].isAbandoned ? s_configs[msg.sender].balance : 0;
        if (backupAddress == address(0) || backupAddress == msg.sender) {
            revert AeternumVault__InvalidBackupAddress();
        }
        if (inactivityPeriod < MIN_INACTIVITY_PERIOD || inactivityPeriod > MAX_INACTIVITY_PERIOD) {
            revert AeternumVault__InvalidInactivityPeriod();
        }

        // Effects
        s_configs[msg.sender] = RecoveryConfig({
            backupAddress: backupAddress,
            inactivityPeriod: inactivityPeriod,
            lastActivity: block.timestamp,
            balance: msg.value + carriedBalance,
            isActive: true,
            failedRecoveryAttempts: 0,
            isAbandoned: false
        });

        s_registeredWallets.push(msg.sender);
        s_walletIndexPlusOne[msg.sender] = s_registeredWallets.length; // 1-indexed

        emit RecoveryRegistered(msg.sender, backupAddress, inactivityPeriod);
        if (msg.value > 0) {
            emit Deposited(msg.sender, msg.value);
        }

        // No external interactions.
    }

    /**
     * @notice Deposit ETH into the recovery vault.
     * @dev    Resets the inactivity timer. The caller must already be registered.
     *         Emits {Deposited} and {ActivityPinged}.
     */
    function deposit() external payable onlyRegistered nonReentrant {
        if (msg.value == 0) revert AeternumVault__InvalidAmount();

        s_configs[msg.sender].balance += msg.value;
        s_configs[msg.sender].lastActivity = block.timestamp;

        emit Deposited(msg.sender, msg.value);
        emit ActivityPinged(msg.sender, block.timestamp);
    }

    /**
     * @notice Withdraw the entire vault balance.
     * @dev    Does NOT cancel the recovery config. The user remains registered and
     *         can deposit again later. To fully deregister, use `cancelRecovery()`.
     *         Emits {Withdrawn} and {ActivityPinged}.
     */
    function withdrawAll() external onlyRegistered nonReentrant {
        RecoveryConfig storage config = s_configs[msg.sender];
        uint256 amount = config.balance;

        if (amount == 0) revert AeternumVault__InvalidAmount();

        // Effects
        config.balance = 0;
        config.lastActivity = block.timestamp;

        emit Withdrawn(msg.sender, amount);
        emit ActivityPinged(msg.sender, block.timestamp);

        // Interaction
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert AeternumVault__TransferFailed();
    }

    /**
     * @notice Send ETH from the vault to any external address.
     * @dev    Allows the vault to behave like a regular wallet — the user can send
     *         funds to any recipient directly from escrow.
     *         Resets the inactivity timer (proves liveness).
     *         Uses CEI: balance updated before the external ETH transfer.
     *         Emits {Sent} and {ActivityPinged}.
     *
     * @param to     Recipient address. Must not be zero address.
     * @param amount Amount to send in wei. Must be ≤ caller's vault balance.
     */
    function send(address to, uint256 amount) external onlyRegistered nonReentrant {
        if (to == address(0)) revert AeternumVault__InvalidAddress();
        if (amount == 0) revert AeternumVault__InvalidAmount();

        RecoveryConfig storage config = s_configs[msg.sender];
        if (amount > config.balance) revert AeternumVault__InsufficientBalance();

        // Effects (before external call — CEI)
        config.balance -= amount;
        config.lastActivity = block.timestamp;

        emit Sent(msg.sender, to, amount);
        emit ActivityPinged(msg.sender, block.timestamp);

        // Interaction
        (bool success,) = to.call{value: amount}("");
        if (!success) revert AeternumVault__TransferFailed();
    }

    /**
     * @notice Reset the inactivity timer without moving any funds.
     * @dev    The cheapest way to signal liveness. The Aeternum Labs watcher
     *         service alerts users before their inactivity period elapses.
     *         Emits {ActivityPinged}.
     */
    function ping() external onlyRegistered {
        s_configs[msg.sender].lastActivity = block.timestamp;
        emit ActivityPinged(msg.sender, block.timestamp);
    }

    /**
     * @notice Change the backup address to which funds will be recovered.
     * @dev    Resets the inactivity timer as a side-effect (proves liveness).
     *         Emits {BackupAddressUpdated} and {ActivityPinged}.
     *
     * @param newBackupAddress New destination. Must not be zero, the caller's own
     *                         address, or an abandoned backup address.
     */
    function updateBackupAddress(address newBackupAddress) external onlyRegistered {
        if (newBackupAddress == address(0) || newBackupAddress == msg.sender) {
            revert AeternumVault__InvalidBackupAddress();
        }
        if (s_abandonedBackupAddresses[newBackupAddress]) {
            revert AeternumVault__WalletAbandoned();
        }

        s_configs[msg.sender].backupAddress = newBackupAddress;
        s_configs[msg.sender].lastActivity = block.timestamp;

        emit BackupAddressUpdated(msg.sender, newBackupAddress);
        emit ActivityPinged(msg.sender, block.timestamp);
    }

    /**
     * @notice Change the inactivity period.
     * @dev    The new period must remain within MIN_INACTIVITY_PERIOD and
     *         MAX_INACTIVITY_PERIOD. Resets the inactivity timer.
     *         Emits {InactivityPeriodUpdated} and {ActivityPinged}.
     *
     * @param newPeriod New inactivity period in seconds.
     */
    function updateInactivityPeriod(uint256 newPeriod) external onlyRegistered {
        if (newPeriod < MIN_INACTIVITY_PERIOD || newPeriod > MAX_INACTIVITY_PERIOD) {
            revert AeternumVault__InvalidInactivityPeriod();
        }

        RecoveryConfig storage config = s_configs[msg.sender];
        config.inactivityPeriod = newPeriod;
        config.lastActivity = block.timestamp;

        emit InactivityPeriodUpdated(msg.sender, newPeriod);
        emit ActivityPinged(msg.sender, block.timestamp);
    }

    /**
     * @notice Cancel recovery and withdraw all escrowed ETH in one transaction.
     * @dev    Permanently removes the caller from monitoring. Re-registration
     *         after cancellation is allowed.
     *         Uses CEI: deregistration and balance zeroing occur before the ETH
     *         transfer.
     *         Emits {RecoveryCancelled}.
     */
    function cancelRecovery() external onlyRegistered nonReentrant {
        RecoveryConfig storage config = s_configs[msg.sender];
        uint256 refundAmount = config.balance;

        // Effects
        config.balance = 0;
        config.isActive = false;
        _removeFromRegistry(msg.sender);

        emit RecoveryCancelled(msg.sender, refundAmount);

        // Interaction (after all state changes)
        if (refundAmount > 0) {
            (bool success,) = msg.sender.call{value: refundAmount}("");
            if (!success) revert AeternumVault__TransferFailed();
        }
    }

    /// --- KEEPER INTERFACE ---
    /**
     * @notice Trigger recovery for a wallet whose inactivity period has elapsed.
     *
     * @dev    PERMISSIONLESS — callable by anyone: the Aeternum keeper bot,
     *         Gelato Network (Phase 2), CRE (Phase 3), the beneficiary, or any
     *         external party. No access control is applied at this entry point.
     *
     *         SAFETY: The caller supplies only a wallet address. Every subsequent
     *         decision — whether recovery executes, the amount, and the destination
     *         — is made exclusively from storage written by the vault owner.
     *         See `_executeRecovery` for full validation and CEI details.
     *
     *         SILENT RETURN: This function does not revert when conditions are not
     *         met (wallet not yet due, already recovered, zero balance, or cancelled).
     *         This allows competing keepers to submit without reverting on race losses.
     *         The Aeternum keeper bot pre-validates via `isRecoveryDue(wallet)` as a
     *         free eth_call before broadcasting any transaction.
     *
     *         ATTEMPT COUNTER: `failedRecoveryAttempts` increments only when the ETH
     *         transfer to the backup address actually fails — not on pre-condition
     *         misses. A keeper losing a race to another keeper does not consume a
     *         retry slot.
     *
     * @param  wallet The wallet address to attempt recovery on.
     */
    function triggerRecovery(address wallet) external nonReentrant {
        _executeRecovery(wallet);
    }

    /**
     * @notice Returns triggerable wallet addresses within a registry slice.
     *
     * @dev    Designed for the Aeternum keeper bot and Phase 3 CRE integration.
     *         The keeper calls this as a free eth_call to identify wallets due for
     *         recovery before submitting any `triggerRecovery` transactions. CRE
     *         can call this via a single Read Chain capability DON request per batch,
     *         avoiding per-vault round trips.
     *
     *         Returns only wallets where all three conditions are met:
     *           • `isActive == true`
     *           • `balance > 0`
     *           • `block.timestamp >= lastActivity + inactivityPeriod`
     *
     *         The returned array is trimmed to the actual triggerable count via
     *         assembly — no trailing zero addresses are included.
     *
     * @param  startIndex Inclusive start index into the registered wallets array.
     * @param  batchSize  Number of registry entries to scan from startIndex.
     *                    Clamped to the remaining length if it exceeds bounds.
     * @return triggerable Wallet addresses currently eligible for recovery.
     *                     Empty array if none are due in the requested range.
     */
    function checkVaultsBatch(uint256 startIndex, uint256 batchSize)
        external
        view
        returns (address[] memory triggerable)
    {
        uint256 total = s_registeredWallets.length;
        if (startIndex >= total || batchSize == 0) return new address[](0);

        uint256 end = startIndex + batchSize;
        if (end > total) end = total;

        uint256 rangeSize = end - startIndex;
        address[] memory results = new address[](rangeSize);
        uint256 count = 0;

        for (uint256 i = startIndex; i < end;) {
            address wallet = s_registeredWallets[i];
            RecoveryConfig storage config = s_configs[wallet];

            if (
                config.isActive && config.balance > 0
                    && block.timestamp >= config.lastActivity + config.inactivityPeriod
            ) {
                results[count] = wallet;
                unchecked {
                    ++count;
                }
            }
            unchecked {
                ++i;
            }
        }

        // Trim to actual triggerable count — no trailing zero addresses.
        assembly { mstore(results, count) }
        return results;
    }

    /// --- VIEW FUNCTIONS ---
    /// @notice Returns true if the wallet is currently registered and active.
    /// @param wallet The wallet address to query.
    function isRegistered(address wallet) external view returns (bool) {
        return s_configs[wallet].isActive;
    }

    /// @notice Returns the full recovery configuration for a given wallet.
    /// @param wallet The wallet address to query.
    function getRecoveryConfig(address wallet) external view returns (RecoveryConfig memory) {
        return s_configs[wallet];
    }

    /**
     * @notice Returns true if the wallet's recovery conditions are currently met.
     * @dev    A wallet is "due" when it is active, has a non-zero balance, and the
     *         inactivity period has fully elapsed since `lastActivity`.
     *         The keeper bot calls this as a free eth_call before submitting
     *         `triggerRecovery` to avoid wasting gas on ineligible wallets.
     * @param  wallet The wallet address to query.
     */
    function isRecoveryDue(address wallet) external view returns (bool) {
        RecoveryConfig storage config = s_configs[wallet];
        return config.isActive && config.balance > 0 && block.timestamp >= config.lastActivity + config.inactivityPeriod;
    }

    /**
     * @notice Returns the number of seconds remaining before recovery can be triggered.
     * @dev    Returns 0 if recovery is already due or the wallet is not registered.
     * @param  wallet The wallet address to query.
     */
    function getTimeUntilRecovery(address wallet) external view returns (uint256) {
        RecoveryConfig storage config = s_configs[wallet];
        if (!config.isActive || config.balance == 0) return 0;

        uint256 deadline = config.lastActivity + config.inactivityPeriod;
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    /// @notice Returns true if a backup address has been permanently blocked
    ///         due to rejecting ETH across MAX_RECOVERY_ATTEMPTS attempts.
    /// @param backup The backup address to query.
    function isBackupAbandoned(address backup) external view returns (bool) {
        return s_abandonedBackupAddresses[backup];
    }

    /**
     * @notice Returns a paginated slice of registered wallet addresses.
     * @dev    Used by the keeper bot for full registry iteration and by external
     *         tooling. Pair with `getTotalRegistered()` to paginate correctly.
     * @param start Inclusive start index.
     * @param end   Exclusive end index. Clamped to array length if out of bounds.
     */
    function getRegisteredWallets(uint256 start, uint256 end) external view returns (address[] memory) {
        uint256 total = s_registeredWallets.length;
        if (start >= total) return new address[](0);
        if (end > total) end = total;

        address[] memory result = new address[](end - start);
        for (uint256 i = start; i < end;) {
            result[i - start] = s_registeredWallets[i];
            unchecked {
                ++i;
            }
        }
        return result;
    }

    /// @notice Returns the total number of wallets currently registered.
    function getTotalRegistered() external view returns (uint256) {
        return s_registeredWallets.length;
    }

    /// --- INTERNAL FUNCTIONS ---
    /**
     * @notice Executes recovery for a single wallet, transferring its balance to
     *         the backup address.
     *
     * @dev    Re-validates all conditions so stale or duplicate calls are safely
     *         skipped. Called exclusively by `triggerRecovery`.
     *
     *         CEI PATTERN:
     *           1. Checks  — re-validate eligibility. Silent return if unmet.
     *           2. Effects — zero the balance, mark inactive, remove from registry,
     *                        increment attempt counter.
     *           3. Interact — transfer ETH to backupAddress.
     *
     *         FAILURE HANDLING AND RETRY LOGIC:
     *           • If the ETH transfer to `backupAddress` fails (e.g. a contract
     *             backup address with no receive function), state is safely restored
     *             and {RecoveryFailed} is emitted.
     *           • The wallet is re-added to the registry for retry on the next
     *             keeper cycle. The attempt counter is NOT reset between retries.
     *           • Recovery is retried up to MAX_RECOVERY_ATTEMPTS times.
     *           • Once exhausted, the wallet is permanently marked as abandoned,
     *             removed from monitoring, and {RecoveryAbandoned} is emitted.
     *           • The wallet's balance remains accessible via withdrawAll() or send(),
     *             but re-registration with the same backup address is blocked forever.
     *
     *         Slither reentrancy-eth: acknowledged.
     *           On a failed transfer, config.balance, config.isActive, config.isAbandoned,
     *           and s_registeredWallets are written after the external call — unavoidable
     *           in the failure-restore pattern.
     *           Safety is guaranteed by three independent layers:
     *             1. `nonReentrant` on `triggerRecovery` blocks all reentrant calls.
     *             2. `config.balance` is zeroed before the call — no double-spend possible.
     *             3. After MAX_RECOVERY_ATTEMPTS consecutive failures the vault is
     *                permanently abandoned, eliminating the retry loop entirely.
     *
     * @param wallet The wallet address to attempt recovery on.
     */
    function _executeRecovery(address wallet) internal {
        RecoveryConfig storage config = s_configs[wallet];

        // Re-validate (Checks) — silent return on any unmet condition.
        // These guards also make the race condition between competing keepers safe:
        // the second caller finds isActive == false and balance == 0 after a
        // successful execution, and silently returns without reverting.
        if (!config.isActive) return;
        if (config.balance == 0) return;
        if (block.timestamp < config.lastActivity + config.inactivityPeriod) return;

        address backupAddress = config.backupAddress;
        uint256 amount = config.balance;

        // Pre-calculate new attempt count before external call (CEI).
        uint8 newAttempts;
        unchecked {
            newAttempts = config.failedRecoveryAttempts + 1;
        }

        // Effects — ALL committed before external call.
        config.balance = 0;
        config.isActive = false;
        config.failedRecoveryAttempts = newAttempts;
        _removeFromRegistry(wallet);

        // Interaction
        // slither-disable-next-line reentrancy-eth
        (bool success,) = backupAddress.call{value: amount}("");

        if (!success) {
            // Restore balance — safe: nonReentrant on triggerRecovery prevents
            // exploitation. config.balance was zeroed before the call so no
            // double-spend is possible regardless.
            config.balance = amount;

            if (newAttempts >= MAX_RECOVERY_ATTEMPTS) {
                config.isAbandoned = true;
                s_abandonedBackupAddresses[backupAddress] = true;
                emit RecoveryAbandoned(wallet, backupAddress, amount);
                return;
            }

            // Restore monitoring state for retry on the next keeper cycle.
            config.isActive = true;
            s_registeredWallets.push(wallet);
            s_walletIndexPlusOne[wallet] = s_registeredWallets.length;
            emit RecoveryFailed(wallet, backupAddress, amount);
            return;
        }

        emit RecoveryExecuted(wallet, backupAddress, amount);
    }

    /**
     * @notice Removes a wallet from the registered wallets array in O(1) via swap-and-pop.
     *
     * @dev    Algorithm:
     *           1. Look up the wallet's 1-indexed position.
     *           2. Move the last element into that position.
     *           3. Update the moved element's index mapping.
     *           4. Pop the (now-duplicate) last element and delete the mapping entry.
     *
     *         This preserves array integrity when multiple wallets are removed within
     *         a single call, because s_walletIndexPlusOne is always updated to
     *         reflect the current position of any moved element.
     *
     * @param wallet Address to remove from the registry.
     */
    function _removeFromRegistry(address wallet) internal {
        uint256 indexPlusOne = s_walletIndexPlusOne[wallet];
        if (indexPlusOne == 0) return; // Not in registry; nothing to do.

        uint256 indexToRemove = indexPlusOne - 1;
        uint256 lastIndex = s_registeredWallets.length - 1;

        if (indexToRemove != lastIndex) {
            address lastWallet = s_registeredWallets[lastIndex];
            s_registeredWallets[indexToRemove] = lastWallet;
            s_walletIndexPlusOne[lastWallet] = indexPlusOne; // update moved element's index
        }

        s_registeredWallets.pop();
        delete s_walletIndexPlusOne[wallet];
    }

    /// --- FALLBACK / RECEIVE ---
    /**
     * @notice Rejects plain ETH transfers to prevent accidental fund loss.
     * @dev    Users must interact through `register()` or `deposit()`.
     */
    receive() external payable {
        revert AeternumVault__DirectTransferNotAllowed();
    }
}
