// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAeternumVault} from "./interfaces/IAeternumVault.sol";
import {AutomationCompatibleInterface} from "./interfaces/AutomationCompatibleInterface.sol";

/**
 * @title  AeternumVault
 * @author Ndubuisi Ugwuja
 * @notice Trustless, non-custodial smart wallet vault with built-in automated funds recovery.
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
 *         • No admin can pause recovery, redirect funds, or change user configs.
 *         • Treasury address can ONLY withdraw subscription fees — never user funds.
 *         • Recovery execution is permissionless via Chainlink Automation.
 *         • All state changes follow the Checks-Effects-Interactions (CEI) pattern.
 *         • ReentrancyGuard provides a secondary reentrancy defence layer.
 *
 *         SUBSCRIPTION TIERS
 *         ─────────────────────────────────────────────────────────────────────
 *         • Free    – minimum inactivity period of 365 days.
 *         • Premium – minimum inactivity period of 180 days; requires PREMIUM_MONTHLY_FEE
 *                     per 30-day subscription period.
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
    /*//////////////////////////////////////////////////////////////
                            IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Minimum inactivity period allowed for Free tier users.
    uint256 public immutable MIN_INACTIVITY_PERIOD_FREE;

    /// @notice Minimum inactivity period allowed for Premium tier users.
    uint256 public immutable MIN_INACTIVITY_PERIOD_PREMIUM;

    /// @notice Hard ceiling on any inactivity period (prevents permanent lock-up).
    uint256 public immutable MAX_INACTIVITY_PERIOD;

    /// @notice Duration of a Premium subscription.
    uint256 public immutable SUBSCRIPTION_DURATION;

    /// @notice Fee (in wei) for a full annual Premium subscription (discounted vs monthly).
    uint256 public immutable PREMIUM_ANNUAL_FEE;

    /**
     * @notice Monthly fee (in wei) required to register or renew a Premium subscription.
     * @dev    Intentionally kept low for accessibility. Can be adjusted in a future
     *         version via governance or an upgradeable proxy pattern.
     */
    uint256 public immutable PREMIUM_MONTHLY_FEE;

    /// @notice Maximum wallets processed in a single `performUpkeep` call.
    /// @dev    Keeps on-chain gas consumption predictable and within Chainlink limits.
    uint256 public immutable MAX_BATCH_SIZE;

    /// @notice Maximum consecutive failed recovery attempts before a wallet is
    ///         permanently deregistered and its balance becomes self-claimable.
    uint8 public immutable MAX_RECOVERY_ATTEMPTS;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

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

    /// @dev Running total of subscription fees not yet withdrawn by treasury.
    uint256 private s_accumulatedFees;

    /**
     * @dev Address authorised to withdraw `s_accumulatedFees`.
     *      Has NO ability to access or redirect user recovery balances.
     */
    address private s_treasury;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts if the caller does not have an active recovery config.
    modifier onlyRegistered() {
        if (!s_configs[msg.sender].isActive && !s_configs[msg.sender].isAbandoned) {
            revert AeternumVault__NotRegistered();
        }
        _;
    }

    /// @dev Reverts if the caller is not the current treasury address.
    modifier onlyTreasury() {
        if (msg.sender != s_treasury) revert AeternumVault__NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialises the contract and sets the treasury address.
     * @param treasury_ Address that may withdraw accumulated subscription fees.
     *                  Recommended to be a multi-sig (e.g. Gnosis Safe) in production.
     */
    constructor(
        address treasury_,
        uint256 minInactivityFree_,
        uint256 minInactivityPremium_,
        uint256 maxInactivityPeriod_,
        uint256 subscriptionDuration_,
        uint256 premiumMonthlyFee_,
        uint256 premiumAnnualFee_,
        uint256 maxBatchSize_,
        uint8 maxRecoveryAttempts_
    ) {
        if (treasury_ == address(0)) revert AeternumVault__ZeroAddress();
        if (minInactivityPremium_ == 0) revert AeternumVault__InvalidInactivityPeriod();
        if (minInactivityFree_ < minInactivityPremium_) revert AeternumVault__InvalidInactivityPeriod();
        if (maxInactivityPeriod_ < minInactivityFree_) revert AeternumVault__InvalidInactivityPeriod();
        if (subscriptionDuration_ == 0) revert AeternumVault__InvalidSubscriptionDuration();
        if (premiumAnnualFee_ < premiumMonthlyFee_) revert AeternumVault__InvalidConstructorParam();
        if (maxBatchSize_ == 0) revert AeternumVault__MaxBatchSizeExceeded();
        if (maxRecoveryAttempts_ == 0) revert AeternumVault__MaxRecoveryAttemptsExceeded();

        s_treasury = treasury_;
        MIN_INACTIVITY_PERIOD_FREE = minInactivityFree_;
        MIN_INACTIVITY_PERIOD_PREMIUM = minInactivityPremium_;
        MAX_INACTIVITY_PERIOD = maxInactivityPeriod_;
        SUBSCRIPTION_DURATION = subscriptionDuration_;
        PREMIUM_MONTHLY_FEE = premiumMonthlyFee_;
        PREMIUM_ANNUAL_FEE = premiumAnnualFee_;
        MAX_BATCH_SIZE = maxBatchSize_;
        MAX_RECOVERY_ATTEMPTS = maxRecoveryAttempts_;
    }

    /*//////////////////////////////////////////////////////////////
                         USER-FACING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register a wallet for recovery.
     *
     * @dev    The caller's address is treated as the "primary wallet" being protected.
     *         Any ETH sent above the subscription fee (if Premium) is deposited into
     *         the recovery vault. Registration with 0 balance is valid; the user can
     *         `deposit()` later.
     *
     *         Emits {RecoveryRegistered} and, if ETH is deposited, {Deposited}.
     *
     * @param backupAddress    Address that will receive funds if recovery is triggered.
     *                         Must not be zero or the caller's own address.
     * @param inactivityPeriod Seconds without activity before recovery executes.
     *                         Free: [MIN_INACTIVITY_PERIOD_FREE, MAX_INACTIVITY_PERIOD]
     *                         Premium: [MIN_INACTIVITY_PERIOD_PREMIUM, MAX_INACTIVITY_PERIOD]
     * @param tier             Desired subscription tier. Premium requires msg.value ≥ PREMIUM_MONTHLY_FEE.
     */
    function register(address backupAddress, uint256 inactivityPeriod, SubscriptionTier tier)
        external
        payable
        nonReentrant
    {
        // Checks
        if (s_configs[msg.sender].isActive) revert AeternumVault__AlreadyRegistered();
        if (s_abandonedBackupAddresses[backupAddress]) revert AeternumVault__WalletAbandoned();
        if (backupAddress == address(0) || backupAddress == msg.sender) {
            revert AeternumVault__InvalidBackupAddress();
        }
        if (inactivityPeriod > MAX_INACTIVITY_PERIOD) {
            revert AeternumVault__InvalidInactivityPeriod();
        }

        uint256 subscriptionPayment = 0;
        uint256 subscriptionExpiry = 0;

        if (tier == SubscriptionTier.Premium) {
            if (msg.value < PREMIUM_MONTHLY_FEE) revert AeternumVault__InsufficientSubscriptionFee();
            if (inactivityPeriod < MIN_INACTIVITY_PERIOD_PREMIUM) {
                revert AeternumVault__InvalidInactivityPeriod();
            }
            subscriptionPayment = PREMIUM_MONTHLY_FEE;
            subscriptionExpiry = block.timestamp + SUBSCRIPTION_DURATION;
        } else {
            // Free tier
            if (inactivityPeriod < MIN_INACTIVITY_PERIOD_FREE) {
                revert AeternumVault__InvalidInactivityPeriod();
            }
        }

        uint256 depositAmount = msg.value - subscriptionPayment;

        // Effects

        s_configs[msg.sender] = RecoveryConfig({
            backupAddress: backupAddress,
            inactivityPeriod: inactivityPeriod,
            lastActivity: block.timestamp,
            balance: depositAmount,
            tier: tier,
            subscriptionExpiry: subscriptionExpiry,
            isActive: true,
            failedRecoveryAttempts: 0,
            isAbandoned: false
        });

        s_registeredWallets.push(msg.sender);
        s_walletIndexPlusOne[msg.sender] = s_registeredWallets.length; // 1-indexed

        s_accumulatedFees += subscriptionPayment;

        // Emit
        emit RecoveryRegistered(msg.sender, backupAddress, inactivityPeriod, tier);
        if (depositAmount > 0) {
            emit Deposited(msg.sender, depositAmount);
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
        if (msg.value == 0) revert AeternumVault__InsufficientBalance();

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
        if (amount == 0) revert AeternumVault__NothingToWithdraw();

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
     * @param to     Recipient address. Must not be zero or the caller's own vault.
     * @param amount Amount to send in wei. Must be ≤ caller's vault balance.
     */
    function send(address to, uint256 amount) external onlyRegistered nonReentrant {
        // Checks
        if (to == address(0)) revert AeternumVault__InvalidBackupAddress();
        if (amount == 0) revert AeternumVault__NothingToWithdraw();

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
     * @dev    The minimum period enforced depends on whether the caller has an active
     *         Premium subscription at the time of the call. If the subscription has
     *         expired, the Free minimum (365 days) applies.
     *         Resets the inactivity timer.
     *         Emits {InactivityPeriodUpdated} and {ActivityPinged}.
     *
     * @param newPeriod New inactivity period in seconds.
     */
    function updateInactivityPeriod(uint256 newPeriod) external onlyRegistered {
        RecoveryConfig storage config = s_configs[msg.sender];

        bool premiumActive = config.tier == SubscriptionTier.Premium && block.timestamp <= config.subscriptionExpiry;

        uint256 minPeriod = premiumActive ? MIN_INACTIVITY_PERIOD_PREMIUM : MIN_INACTIVITY_PERIOD_FREE;

        if (newPeriod < minPeriod || newPeriod > MAX_INACTIVITY_PERIOD) {
            revert AeternumVault__InvalidInactivityPeriod();
        }

        config.inactivityPeriod = newPeriod;
        config.lastActivity = block.timestamp;

        emit InactivityPeriodUpdated(msg.sender, newPeriod);
        emit ActivityPinged(msg.sender, block.timestamp);
    }

    /**
     * @notice Purchase or renew a Premium subscription.
     * @dev    If the caller is already on Premium with a future expiry, the new period
     *         is appended to the existing expiry (stacking). Otherwise, a new 30-day
     *         window starts from `block.timestamp`.
     *         Any ETH above PREMIUM_MONTHLY_FEE is accepted and accumulated as fees
     *         (useful for pre-paying multiple months — caller bears responsibility for
     *         amount sent).
     *         Emits {SubscriptionRenewed} and {ActivityPinged}.
     */
    function renewSubscription() external payable onlyRegistered nonReentrant {
        // Check
        if (msg.value < PREMIUM_MONTHLY_FEE) revert AeternumVault__InsufficientSubscriptionFee();

        RecoveryConfig storage config = s_configs[msg.sender];

        // Stack onto existing expiry or start fresh from now
        uint256 base = (config.subscriptionExpiry > block.timestamp) ? config.subscriptionExpiry : block.timestamp;
        uint256 newExpiry = base + SUBSCRIPTION_DURATION;

        // Effects
        config.tier = SubscriptionTier.Premium;
        config.subscriptionExpiry = newExpiry;
        config.lastActivity = block.timestamp;
        s_accumulatedFees += msg.value;

        emit SubscriptionRenewed(msg.sender, SubscriptionTier.Premium, newExpiry);
        emit ActivityPinged(msg.sender, block.timestamp);
    }

    /**
     * @notice Cancel recovery and withdraw all escrowed ETH in one transaction.
     * @dev    Permanently removes the caller from monitoring. Subscription fees are
     *         non-refundable. A re-registration after cancellation is allowed.
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

    /*//////////////////////////////////////////////////////////////
                    CHAINLINK AUTOMATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Determines which wallets (if any) are ready for recovery.
     *
     * @dev    Called off-chain by Chainlink Automation nodes. Gas cost is not a
     *         concern here; the function iterates a paginated window of wallets.
     *
     *         Pagination via `checkData`:
     *           `checkData = abi.encode(uint256 startIndex, uint256 batchSize)`
     *         If `checkData` is empty, defaults to startIndex=0, batchSize=MAX_BATCH_SIZE.
     *         Callers should paginate across the full registry in separate upkeep
     *         registrations when the wallet count is large.
     *
     * @param  checkData ABI-encoded (startIndex, batchSize) for pagination.
     * @return upkeepNeeded True if at least one wallet is due for recovery.
     * @return performData  ABI-encoded address[] of wallets ready for recovery.
     */
    function checkUpkeep(bytes calldata checkData)
        external
        view
        override(IAeternumVault, AutomationCompatibleInterface)
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256 startIndex;
        uint256 batchSize;

        if (checkData.length > 0) {
            (startIndex, batchSize) = abi.decode(checkData, (uint256, uint256));
        } else {
            startIndex = 0;
            batchSize = MAX_BATCH_SIZE;
        }

        // Cap batchSize to MAX_BATCH_SIZE to mirror performUpkeep limits
        if (batchSize > MAX_BATCH_SIZE) {
            batchSize = MAX_BATCH_SIZE;
        }

        uint256 totalWallets = s_registeredWallets.length;

        // Early exit: nothing to check
        if (totalWallets == 0 || startIndex >= totalWallets) {
            return (false, bytes(""));
        }

        uint256 endIndex = startIndex + batchSize;
        if (endIndex > totalWallets) endIndex = totalWallets;

        // Allocate maximum possible size; trim with assembly after filling
        address[] memory candidates = new address[](endIndex - startIndex);
        uint256 count = 0;

        for (uint256 i = startIndex; i < endIndex;) {
            address wallet = s_registeredWallets[i];
            RecoveryConfig storage config = s_configs[wallet];

            if (
                config.isActive && config.balance > 0
                    && block.timestamp >= config.lastActivity + _effectiveInactivityPeriod(config)
            ) {
                candidates[count] = wallet;
                unchecked {
                    ++count;
                }
            }

            unchecked {
                ++i;
            }
        }

        if (count > 0) {
            // Trim the array to the actual number of candidates found
            assembly {
                mstore(candidates, count)
            }
            upkeepNeeded = true;
            performData = abi.encode(candidates);
        }
    }

    /**
     * @notice Executes pending recoveries supplied by `checkUpkeep`.
     *
     * @dev    Called on-chain by the registered Chainlink Automation upkeep.
     *         Every wallet is re-validated before acting to guard against:
     *           • Stale `performData` (user pinged between check and perform).
     *           • Race conditions across multiple Automation nodes.
     *           • Duplicate entries within a single `performData` batch.
     *         Invalid entries are silently skipped to prevent one bad address from
     *         blocking the rest of the batch.
     *
     *         Security: guarded by `nonReentrant`. CEI is enforced inside
     *         `_executeRecovery` — all state changes precede the ETH transfer.
     *
     *         Slither: calls-loop is acknowledged. External ETH transfers to distinct
     *         backup addresses inherently require a loop. Mitigated by nonReentrant,
     *         CEI pattern, re-validation per iteration, and MAX_BATCH_SIZE cap.
     *
     * @param performData ABI-encoded address[] returned by `checkUpkeep`.
     */
    function performUpkeep(bytes calldata performData)
        external
        override(IAeternumVault, AutomationCompatibleInterface)
        nonReentrant
    {
        address[] memory walletsToRecover = abi.decode(performData, (address[]));

        uint256 length = walletsToRecover.length;
        if (length > MAX_BATCH_SIZE) revert AeternumVault__MaxBatchSizeExceeded();

        for (uint256 i = 0; i < length;) {
            _executeRecovery(walletsToRecover[i]);
            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                         TREASURY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdraw all accumulated subscription fees to the treasury address.
     * @dev    Only the treasury address may call this. It has NO access to user
     *         recovery balances — those are tracked separately in `s_configs[].balance`.
     *         Uses CEI: s_accumulatedFees zeroed before the ETH transfer.
     *         Emits {SubscriptionFeesWithdrawn}.
     */
    function withdrawSubscriptionFees() external onlyTreasury nonReentrant {
        uint256 amount = s_accumulatedFees;

        // Check
        if (amount == 0) revert AeternumVault__NothingToWithdraw();

        // Effects
        s_accumulatedFees = 0;

        emit SubscriptionFeesWithdrawn(s_treasury, amount);

        // Interaction
        (bool success,) = s_treasury.call{value: amount}("");
        if (!success) revert AeternumVault__TransferFailed();
    }

    /**
     * @notice Transfer treasury authority to a new address.
     * @dev    Only the current treasury may call this. For production deployments,
     *         consider a two-step transfer pattern (nominee confirms) to prevent
     *         accidental loss of access.
     *         Emits {TreasuryUpdated}.
     *
     * @param newTreasury New treasury address. Must not be the zero address.
     */
    function updateTreasury(address newTreasury) external onlyTreasury {
        if (newTreasury == address(0)) revert AeternumVault__ZeroAddress();

        address oldTreasury = s_treasury;
        s_treasury = newTreasury;

        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
        return config.isActive && config.balance > 0
            && block.timestamp >= config.lastActivity + _effectiveInactivityPeriod(config);
    }

    /**
     * @notice Returns the number of seconds remaining before recovery can be triggered.
     * @dev    Returns 0 if recovery is already due or the wallet is not registered.
     * @param  wallet The wallet address to query.
     */
    function getTimeUntilRecovery(address wallet) external view returns (uint256) {
        RecoveryConfig storage config = s_configs[wallet];
        if (!config.isActive || config.balance == 0) return 0;

        uint256 deadline = config.lastActivity + _effectiveInactivityPeriod(config);
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    /// @notice Returns true if a backup address has been permanently blocked
    ///         due to rejecting ETH across MAX_RECOVERY_ATTEMPTS recoveries.
    function isBackupAbandoned(address backup) external view returns (bool) {
        return s_abandonedBackupAddresses[backup];
    }

    /// @notice Returns the total subscription fees not yet withdrawn.
    function getAccumulatedFees() external view returns (uint256) {
        return s_accumulatedFees;
    }

    /// @notice Returns the current treasury address.
    function getTreasury() external view returns (address) {
        return s_treasury;
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

    /*//////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the effective inactivity period for a wallet at the current timestamp.
     * @dev    If the wallet's Premium subscription has expired and the stored inactivity
     *         period is below the Free minimum, the Free minimum is enforced.
     *         This prevents expired Premium users from retaining sub-Free-tier periods
     *         indefinitely without renewing.
     * @param config The wallet's recovery config storage pointer.
     */
    function _effectiveInactivityPeriod(RecoveryConfig storage config) internal view returns (uint256) {
        bool premiumActive = config.tier == SubscriptionTier.Premium && block.timestamp <= config.subscriptionExpiry;

        if (!premiumActive && config.inactivityPeriod < MIN_INACTIVITY_PERIOD_FREE) {
            return MIN_INACTIVITY_PERIOD_FREE;
        }
        return config.inactivityPeriod;
    }

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
        if (block.timestamp < config.lastActivity + _effectiveInactivityPeriod(config)) return;

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

    /*//////////////////////////////////////////////////////////////
                             FALLBACK / RECEIVE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Rejects plain ETH transfers to prevent accidental fund loss
     * @dev Users must interact through `register()` or `deposit()`.
     */
    receive() external payable {
        revert AeternumVault__DirectTransferNotAllowed();
    }
}
