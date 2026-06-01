// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAeternumVault} from "./interfaces/IAeternumVault.sol";
import {AutomationCompatibleInterface} from "./interfaces/AutomationCompatibleInterface.sol";

/**
 * @title  AeternumVault
 * @author Ndubuisi Ugwuja
 * @notice Trustless smart wallet vault with built-in automated funds recovery.
 *
 *
 * @dev    SYSTEM OVERVIEW
 *         ─────────────────────────────────────────────────────────────────────
 *         1. Users call `register()` with a backup address and an inactivity period,
 *            optionally depositing ETH into the contract's escrow at the same time.
 *         2. The contract tracks each user's `lastActivity` timestamp. Any on-chain
 *            interaction with this contract (ping, deposit, withdraw, config update)
 *            resets the timer.
 *         3. Chainlink Automation periodically calls `checkUpkeep()`. When a wallet's
 *            inactivity period has elapsed and its balance is non-zero, the Automation
 *            node calls `performUpkeep()` to transfer the escrowed ETH to the backup
 *            address.
 *         4. Users may cancel at any time via `cancelRecovery()`, which refunds their
 *            entire balance and removes them from monitoring.
 *
 *         TRUST MODEL
 *         ─────────────────────────────────────────────────────────────────────
 *         • No admin or owner to pause recovery, redirect funds, or change user configs.
 *         • Recovery execution is fully autonomous and permissionless via Chainlink Automation.
 *         • All state changes follow the Checks-Effects-Interactions (CEI) pattern.
 *         • ReentrancyGuard provides a secondary reentrancy defence layer.
 *
 *         SECURITY CONSIDERATIONS
 *         ─────────────────────────────────────────────────────────────────────
 *         • Reentrancy: guarded by ReentrancyGuard + CEI on all ETH-transferring paths.
 *         • Integer overflow: Solidity ≥0.8 reverts on overflow by default.
 *         • Batch safety: `performUpkeep` re-validates every wallet before acting;
 *           stale `performData` is silently skipped rather than reverted.
 *         • Array manipulation: swap-and-pop O(1) removal keeps indices consistent
 *           across batch recovery iterations.
 *         • Direct ETH transfers: a `receive()` function explicitly reverts with a
 *           clear error, preventing accidental ETH loss.
 */
contract AeternumVault is IAeternumVault, ReentrancyGuard, AutomationCompatibleInterface {
    /// --- IMMUTABLES ---
    /// @notice Minimum inactivity period allowed.
    uint256 public immutable MIN_INACTIVITY_PERIOD;

    /// @notice Hard ceiling on inactivity period (prevents permanent lock-up).
    uint256 public immutable MAX_INACTIVITY_PERIOD;

    /**
     * @notice Maximum wallets scanned per `checkUpkeep` call (off-chain simulation).
     * @dev    Runs entirely off-chain in Chainlink's simulation environment.
     *         No block gas limit constraint. Set high (e.g. 5000) for wide registry
     *         coverage per tick. Chainlink's simulation gas limit (~6.5M) comfortably
     *         supports 5000 × ~800 gas (SLOAD per wallet) = ~4M gas.
     */
    uint256 public immutable MAX_CHECK_UPKEEP_SIZE;

    /**
     * @notice Maximum wallets recovered per `performUpkeep` call (on-chain execution).
     * @dev    Subject to Ethereum block gas limit. Each `_executeRecovery` worst-case
     *         consumes ~100k gas (SSTOREs + external ETH call + events + retry logic).
     *         At 50 wallets: ~5M gas — safe headroom under the 30M block gas limit.
     *         Keep this at 50 for mainnet. L2 deployments can raise it.
     */
    uint256 public immutable MAX_PERFORM_UPKEEP_SIZE;

    /// @notice Maximum consecutive failed recovery attempts before a wallet is abandoned.
    uint8 public immutable MAX_RECOVERY_ATTEMPTS;

    /**
     * @notice Minimum seconds between cursor advances when no wallets are due.
     * @dev    Controls how frequently idle windows advance to cover the full registry.
     *         Mainnet: 1 hour  → 24 on-chain calls/day (affordable).
     *         Sepolia/Anvil: 30 seconds → fast iteration for testing.
     *         Immutable by design — tune per network at deploy time.
     *         Phase 2 multichain deployments will use chain-appropriate values.
     */
    uint256 public immutable CURSOR_ADVANCE_INTERVAL;

    /// --- STATE VARIABLES ---
    /// @dev Primary configuration store. Key: registered wallet address.
    mapping(address => RecoveryConfig) private s_configs;

    /**
     * @dev Ordered list of all registered wallet addresses.
     *      Iterated by `checkUpkeep`; mutated by `_removeFromRegistry` using
     *      swap-and-pop to maintain O(1) removal.
     */
    address[] private s_registeredWallets;

    /**
     * @dev 1-indexed position of each wallet in `s_registeredWallets`.
     *      A value of 0 means the wallet is NOT in the array.
     *      Stored as 1-indexed so the zero-value naturally represents "absent".
     */
    mapping(address => uint256) private s_walletIndexPlusOne;

    /**
     * @dev Backup addresses that have been proven to reject ETH after MAX_RECOVERY_ATTEMPTS.
     *      Any registration or backup update pointing to these addresses is permanently blocked.
     */
    mapping(address => bool) private s_abandonedBackupAddresses;

    /**
     * @dev Rolling scan cursor. Tracks which registry index the next `checkUpkeep`
     *      scan window begins from. Advanced by `performUpkeep` when a window is clear.
     *      Wraps to 0 when the end of the registry is reached.
     */
    uint256 private s_checkCursor;

    /**
     * @dev Timestamp of the last cursor advancement (idle case only).
     *      Updated by `performUpkeep` when `nextCursor != currentCursor`.
     *      NOT updated during recovery passes (cursor holds position).
     *      Gates idle advancement via CURSOR_ADVANCE_INTERVAL.
     */
    uint256 private s_lastCursorAdvance;

    /**
     * @dev Chainlink Automation forwarder address for this upkeep.
     *      Set once via setForwarder() after upkeep registration.
     *      Once set, only this address may call performUpkeep().
     */
    address private s_forwarder;

    /// --- MODIFIERS ---
    /// @dev Reverts if the caller does not have an active recovery config.
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
     * @param minInactivityPeriod_    Minimum inactivity period (seconds).
     * @param maxInactivityPeriod_    Hard ceiling on inactivity period (seconds).
     * @param maxCheckUpkeepSize_     Max wallets scanned per checkUpkeep (off-chain).
     * @param maxPerformUpkeepSize_   Max wallets recovered per performUpkeep (on-chain).
     * @param maxRecoveryAttempts_    Max failed attempts before a wallet is abandoned.
     * @param cursorAdvanceInterval_  Seconds between idle cursor advances.
     */
    constructor(
        uint256 minInactivityPeriod_,
        uint256 maxInactivityPeriod_,
        uint256 maxCheckUpkeepSize_,
        uint256 maxPerformUpkeepSize_,
        uint8 maxRecoveryAttempts_,
        uint256 cursorAdvanceInterval_
    ) {
        // Validations
        if (minInactivityPeriod_ == 0) revert AeternumVault__InvalidInactivityPeriod();
        if (maxInactivityPeriod_ < minInactivityPeriod_) revert AeternumVault__InvalidInactivityPeriod();
        if (maxCheckUpkeepSize_ == 0) revert AeternumVault__InvalidConstructorParam();
        if (maxPerformUpkeepSize_ == 0) revert AeternumVault__InvalidConstructorParam();
        if (maxPerformUpkeepSize_ > maxCheckUpkeepSize_) revert AeternumVault__MaxPerformUpkeepSizeExceeded();
        if (maxRecoveryAttempts_ == 0) revert AeternumVault__MaxRecoveryAttemptsExceeded();
        if (cursorAdvanceInterval_ == 0) revert AeternumVault__InvalidConstructorParam();

        // Assignments
        MIN_INACTIVITY_PERIOD = minInactivityPeriod_;
        MAX_INACTIVITY_PERIOD = maxInactivityPeriod_;
        MAX_CHECK_UPKEEP_SIZE = maxCheckUpkeepSize_;
        MAX_PERFORM_UPKEEP_SIZE = maxPerformUpkeepSize_;
        MAX_RECOVERY_ATTEMPTS = maxRecoveryAttempts_;
        CURSOR_ADVANCE_INTERVAL = cursorAdvanceInterval_;
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
     *                         Must not be zero, the caller's own address, or abandoned backup address.
     * @param inactivityPeriod Seconds without activity before recovery executes.
     */
    function register(address backupAddress, uint256 inactivityPeriod) external payable nonReentrant {
        // Checks
        if (s_configs[msg.sender].isActive) revert AeternumVault__AlreadyRegistered();
        if (s_abandonedBackupAddresses[backupAddress]) revert AeternumVault__WalletAbandoned();
        // If wallet was abandoned and user skipped withdrawAll(), preserve the
        // existing balance so it isn't permanently locked in the contract.
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

        // Emit
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
        // Check
        if (msg.value == 0) revert AeternumVault__InvalidAmount();

        // Effects
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

        // Check
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
     * @dev    This is the core "wallet send" function — allows the vault to behave
     *         like a regular wallet where you can send funds to anyone.
     *         Resets the inactivity timer (proves liveness).
     *         Uses CEI: balance updated before the external ETH transfer.
     *         Emits {Sent} and {ActivityPinged}.
     *
     * @param to     Recipient address. Must not be zero address.
     * @param amount Amount to send in wei. Must be ≤ caller's vault balance.
     */
    function send(address to, uint256 amount) external onlyRegistered nonReentrant {
        // Checks
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
     * @dev    This is the cheapest way to signal liveness. The watcher service
     *         will remind users to call this before their inactivity period elapses.
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
     * @param newBackupAddress New destination. Must not be zero or the caller's own address.
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
     * @dev    The new period must remain within the enforced
     *         minimum and maximum inactivity bounds.
     *         Resets the inactivity timer, signalling
     *         fresh wallet activity.
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
     * @dev    Permanently removes the caller from monitoring.
     *         A re-registration after cancellation is allowed.
     *         Uses CEI: deregistration and balance zeroing occur before the ETH transfer.
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

    /// --- CHAINLINK AUTOMATION FUNCTIONS ---
    /**
     * @notice Scans the current cursor window for wallets due for recovery.
     *
     * @dev    ARCHITECTURE: Two-variable design separating scan cost from execution cost.
     *
     *         MAX_CHECK_UPKEEP_SIZE (off-chain, free):
     *           Runs in Chainlink's simulation environment — no gas cost, no block
     *           limit. Scans a window of up to MAX_CHECK_UPKEEP_SIZE wallets and
     *           collects ALL due wallets, capped at MAX_PERFORM_UPKEEP_SIZE for
     *           the returned candidates.
     *
     *         MAX_PERFORM_UPKEEP_SIZE (on-chain, gas-bound):
     *           Only the candidates returned here are passed to performUpkeep.
     *           Bounded tightly (50 on mainnet) to stay well within block gas limits
     *           given worst-case ~100k gas per _executeRecovery call.
     *
     *         CURSOR BEHAVIOUR:
     *           • Due wallets found  → cursor HOLDS at current position.
     *             Next call re-scans the same window until fully cleared.
     *           • No due wallets, total ≤ MAX_CHECK_UPKEEP_SIZE → cursor is pinned
     *             to 0; the entire registry fits in one window; no LINK is spent
     *             on idle advancement.
     *           • No due wallets, total > MAX_CHECK_UPKEEP_SIZE → cursor ADVANCES
     *             to the next window once CURSOR_ADVANCE_INTERVAL has elapsed.
     *           • Window exhausted   → cursor wraps to 0.
     *
     *         STALE DATA SAFETY:
     *           performUpkeep re-validates every candidate before acting.
     *           Stale entries (e.g. wallet pinged between check and perform)
     *           are silently skipped. No ETH is sent to an ineligible wallet.
     *
     * @return upkeepNeeded True when performUpkeep should be called.
     * @return performData  ABI-encoded (address[] candidates, uint256 nextCursor).
     */
    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override(IAeternumVault, AutomationCompatibleInterface)
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256 total = s_registeredWallets.length;
        if (total == 0) return (false, bytes(""));

        // Wrap cursor if registry has shrunk below it, or if all wallets fit in one scan window
        uint256 cursor = (s_checkCursor >= total || total <= MAX_CHECK_UPKEEP_SIZE) ? 0 : s_checkCursor;

        // Define scan window: [cursor, end)
        uint256 end = cursor + MAX_CHECK_UPKEEP_SIZE;
        if (end > total) end = total;

        // Collect due wallets up to MAX_PERFORM_UPKEEP_SIZE
        // Allocate at full perform size; trim with assembly after fill
        address[] memory candidates = new address[](MAX_PERFORM_UPKEEP_SIZE);
        uint256 count = 0;

        for (uint256 i = cursor; i < end;) {
            address wallet = s_registeredWallets[i];
            RecoveryConfig storage config = s_configs[wallet];

            if (
                config.isActive && config.balance > 0
                    && block.timestamp >= config.lastActivity + config.inactivityPeriod
            ) {
                candidates[count] = wallet;
                unchecked {
                    ++count;
                }
                // Stop scanning once we have a full perform batch.
                // Remaining due wallets in window caught on next call (cursor holds).
                if (count == MAX_PERFORM_UPKEEP_SIZE) break;
            }

            unchecked {
                ++i;
            }
        }

        if (count > 0) {
            // Recovery needed: HOLD cursor
            // nextCursor == cursor signals performUpkeep NOT to update the advance
            // timestamp. The window is re-scanned next call until fully cleared.
            assembly { mstore(candidates, count) }
            return (true, abi.encode(candidates, cursor, false));
        }

        // Window clear: attempt cursor advancement
        // Calculate where cursor would move to next
        uint256 nextCursor = (end >= total) ? 0 : end;

        if (total > MAX_CHECK_UPKEEP_SIZE && block.timestamp >= s_lastCursorAdvance + CURSOR_ADVANCE_INTERVAL) {
            // Registry spans multiple windows — advance cursor to next window
            address[] memory empty = new address[](0);
            return (true, abi.encode(empty, nextCursor, true));
        }

        // Single-window registry or interval not yet elapsed — nothing to do
        return (false, bytes(""));
    }

    /**
     * @notice Executes pending recoveries and manages the rolling cursor.
     *
     * @dev    CURSOR LOGIC:
     *           • Always writes `nextCursor` to `s_checkCursor`.
     *           • Updates `s_lastCursorAdvance` ONLY when cursor actually moves
     *             (nextCursor != currentCursor). This correctly gates idle advancement
     *             without interfering with active recovery passes where cursor holds.
     *
     *         STALE DATA SAFETY:
     *           Every wallet in `walletsToRecover` is re-validated inside
     *           `_executeRecovery` before any ETH is transferred. If a wallet
     *           is no longer eligible (user pinged, deposited, or cancelled between
     *           checkUpkeep and performUpkeep), it is silently skipped. The cursor
     *           still advances or holds correctly regardless of how many are skipped.
     *
     *         BATCH SIZE GUARD:
     *           Reverts if candidates exceed MAX_PERFORM_UPKEEP_SIZE to defend against
     *           crafted performData with an oversized array that could exhaust block gas.
     *
     * @param performData ABI-encoded (address[] candidates, uint256 nextCursor)
     *                    as produced by checkUpkeep.
     */
    function performUpkeep(bytes calldata performData)
        external
        override(IAeternumVault, AutomationCompatibleInterface)
        nonReentrant
    {
        // Once forwarder is set, reject any caller that isn't it.
        // Before setForwarder() is called (s_forwarder == address(0)),
        // the check is skipped so you can test manually on Sepolia.
        if (s_forwarder != address(0) && msg.sender != s_forwarder) {
            revert AeternumVault__NotForwarder();
        }

        (address[] memory walletsToRecover, uint256 nextCursor, bool isIdleAdvance) =
            abi.decode(performData, (address[], uint256, bool));

        uint256 length = walletsToRecover.length;
        if (length > MAX_PERFORM_UPKEEP_SIZE) revert AeternumVault__MaxPerformUpkeepSizeExceeded();

        s_checkCursor = nextCursor;

        // Update timestamp only when this is an explicit idle advance tick,
        // not during recovery passes (where cursor holds position).
        if (isIdleAdvance) {
            s_lastCursorAdvance = block.timestamp;
        }

        for (uint256 i = 0; i < length;) {
            _executeRecovery(walletsToRecover[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Set the Chainlink Automation forwarder address for this upkeep.
     * @dev    Can only be called once. After this, only the forwarder may call
     *         performUpkeep(). Get the forwarder address from the Chainlink
     *         Automation UI after registering the upkeep.
     * @param  forwarder The forwarder address assigned to this upkeep.
     */
    function setForwarder(address forwarder) external {
        if (s_forwarder != address(0)) revert AeternumVault__ForwarderAlreadySet();
        if (forwarder == address(0)) revert AeternumVault__InvalidAddress();
        s_forwarder = forwarder;
        emit ForwarderSet(forwarder);
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
    ///         due to rejecting ETH across MAX_RECOVERY_ATTEMPTS recoveries.
    function isBackupAbandoned(address backup) external view returns (bool) {
        return s_abandonedBackupAddresses[backup];
    }

    /**
     * @notice Returns a paginated slice of registered wallet addresses.
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

    /// @notice Returns the current registry scan cursor position.
    function getCheckCursor() external view returns (uint256) {
        return s_checkCursor;
    }

    /// @notice Returns the timestamp of the last idle cursor advancement.
    function getLastCursorAdvance() external view returns (uint256) {
        return s_lastCursorAdvance;
    }

    /// @notice Returns the Chainlink Automation forwarder address.
    function getForwarder() external view returns (address) {
        return s_forwarder;
    }

    /// --- INTERNAL FUNCTIONS ---
    /**
     * @notice Executes recovery for a single wallet, transferring its balance to the backup address.
     * @dev Attempts to execute recovery for a single wallet.
     *      Re-validates all conditions so stale or duplicate entries are safely skipped.
     *
     *      CEI pattern:
     *        1. Checks  — re-validate eligibility.
     *        2. Effects — zero the balance, mark inactive, remove from registry.
     *        3. Interact — transfer ETH to backupAddress.
     *
     *      Failure handling & retry logic:
     *        * If the ETH transfer to `backupAddress` fails (e.g. reverting contract),
     *          state is safely restored and a {RecoveryFailed} event is emitted.
     *        * The wallet is re-added to the monitoring queue for retry in the next upkeep cycle.
     *        * Recovery is retried up to `MAX_RECOVERY_ATTEMPTS` (currently 3).
     *        * Once the max attempts threshold is reached, the wallet is marked as abandoned,
     *          permanently removed from the monitoring queue, and {RecoveryAbandoned} is emitted.
     *        * Wallet balance remains accessible via withdrawAll() or send(),
     *          but re-registration with same backupAddress is permanently blocked.
     *
     *      This design ensures that:
     *        * A single faulty backup address cannot block batch execution.
     *        * Recovery attempts are bounded, preventing infinite retry loops.
     *
     *      Slither reentrancy-eth: acknowledged.
     *        * On a failed transfer, config.balance, config.isActive, config.isAbandoned,
     *          and s_registeredWallets are written after the external call — unavoidable
     *          in the failure-restore pattern.
     *        * Safety is guaranteed by three independent layers:
     *            1. `nonReentrant` on `performUpkeep` blocks all reentrant calls.
     *            2. `config.balance` is zeroed before the call — no double-spend possible.
     *            3. After MAX_RECOVERY_ATTEMPTS (3) consecutive failures the vault is
     *               permanently abandoned, eliminating the retry loop entirely.
     *
     * @param wallet The wallet address to attempt recovery on.
     */
    function _executeRecovery(address wallet) internal {
        RecoveryConfig storage config = s_configs[wallet];

        // Re-validate (Checks)
        if (!config.isActive) return;
        if (config.balance == 0) return;
        if (block.timestamp < config.lastActivity + config.inactivityPeriod) return;

        address backupAddress = config.backupAddress;
        uint256 amount = config.balance;

        // Pre-calculate new attempt count before external call (CEI)
        uint8 newAttempts;
        unchecked {
            newAttempts = config.failedRecoveryAttempts + 1;
        }

        // Effects — ALL moved before external call
        config.balance = 0;
        config.isActive = false;
        config.failedRecoveryAttempts = newAttempts;
        _removeFromRegistry(wallet);

        // Interaction
        // slither-disable-next-line reentrancy-eth
        (bool success,) = backupAddress.call{value: amount}("");

        if (!success) {
            // Restore balance — safe: nonReentrant on performUpkeep prevents exploitation.
            // config.balance was zeroed before the call so no double-spend is possible.
            config.balance = amount;

            if (newAttempts >= MAX_RECOVERY_ATTEMPTS) {
                config.isAbandoned = true;
                s_abandonedBackupAddresses[backupAddress] = true;
                emit RecoveryAbandoned(wallet, backupAddress, amount);
                return;
            }

            // Restore monitoring state for retry next cycle
            config.isActive = true;
            s_registeredWallets.push(wallet);
            s_walletIndexPlusOne[wallet] = s_registeredWallets.length;
            emit RecoveryFailed(wallet, backupAddress, amount);
            return;
        }

        emit RecoveryExecuted(wallet, backupAddress, amount);
    }

    /**
     * @notice Removes a wallet from the registered wallets array in O(1) using swap-and-pop.
     * @dev Removes `wallet` from `s_registeredWallets`.
     *
     *      Algorithm:
     *        1. Look up the wallet's 1-indexed position.
     *        2. Move the last element in the array into that position.
     *        3. Update the moved element's index mapping.
     *        4. Pop the (now-duplicate) last element and delete the mapping entry.
     *
     *      This preserves array integrity when multiple wallets are removed in the
     *      same `performUpkeep` call, because `s_walletIndexPlusOne` is always
     *      updated to reflect the current (possibly new) position.
     *
     * @param wallet Address to remove from the registry.
     */
    function _removeFromRegistry(address wallet) internal {
        uint256 indexPlusOne = s_walletIndexPlusOne[wallet];
        if (indexPlusOne == 0) return; // Not in registry; nothing to do.

        uint256 indexToRemove = indexPlusOne - 1;
        uint256 lastIndex = s_registeredWallets.length - 1;

        if (indexToRemove != lastIndex) {
            // Move the last element into the gap
            address lastWallet = s_registeredWallets[lastIndex];
            s_registeredWallets[indexToRemove] = lastWallet;
            s_walletIndexPlusOne[lastWallet] = indexPlusOne; // update moved element's index
        }

        s_registeredWallets.pop();
        delete s_walletIndexPlusOne[wallet];
    }

    /// --- FALLBACK / RECEIVE ---
    /**
     * @notice Rejects plain ETH transfers to prevent accidental fund loss
     * @dev Users must interact through `register()` or `deposit()`.
     */
    receive() external payable {
        revert AeternumVault__DirectTransferNotAllowed();
    }
}
