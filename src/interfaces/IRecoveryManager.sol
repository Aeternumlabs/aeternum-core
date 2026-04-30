// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  IRecoveryManager
 * @author Ndubuisi Ugwuja
 * @notice Complete interface for the RecoveryManager contract.
 *         Defines all public/external types, events, errors, and function signatures.
 */
interface IRecoveryManager {
    /*//////////////////////////////////////////////////////////////
                                 ENUMS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Subscription tiers that govern monitoring frequency and minimum inactivity period.
     * @param Free    180-day minimum inactivity period; standard monitoring.
     * @param Premium  30-day minimum inactivity period; priority monitoring.
     */
    enum SubscriptionTier {
        Free,
        Premium
    }

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice All configuration and state for a single registered wallet.
     * @param backupAddress      Destination address for recovered funds.
     * @param inactivityPeriod   Seconds of inactivity before recovery is triggered.
     * @param lastActivity       Unix timestamp of the user's most recent on-chain interaction.
     * @param balance            ETH (in wei) held in escrow for this wallet.
     * @param tier               Current subscription tier.
     * @param subscriptionExpiry Unix timestamp when the Premium subscription expires (0 = Free).
     * @param isActive           Whether this configuration is live and being monitored.
     */
    struct RecoveryConfig {
        address backupAddress;
        uint256 inactivityPeriod;
        uint256 lastActivity;
        uint256 balance;
        SubscriptionTier tier;
        uint256 subscriptionExpiry;
        bool isActive;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a wallet is successfully registered for recovery.
    event RecoveryRegistered(
        address indexed wallet, address indexed backupAddress, uint256 inactivityPeriod, SubscriptionTier tier
    );

    /// @notice Emitted whenever the inactivity timer is reset (ping, deposit, withdraw, config update).
    event ActivityPinged(address indexed wallet, uint256 timestamp);

    /// @notice Emitted when Chainlink Automation executes a recovery.
    event RecoveryExecuted(address indexed wallet, address indexed backupAddress, uint256 amount);

    /// @notice Emitted when a user voluntarily cancels their recovery and withdraws funds.
    event RecoveryCancelled(address indexed wallet, uint256 refundAmount);

    /// @notice Emitted when ETH is added to a recovery vault.
    event Deposited(address indexed wallet, uint256 amount);

    /// @notice Emitted when the user sends ETH from their vault to an external address.
    event Sent(address indexed wallet, address indexed to, uint256 amount);

    /// @notice Emitted when a user withdraws their entire vault balance.
    event Withdrawn(address indexed wallet, uint256 amount);

    /// @notice Emitted when the backup address is changed.
    event BackupAddressUpdated(address indexed wallet, address indexed newBackupAddress);

    /// @notice Emitted when the inactivity period is changed.
    event InactivityPeriodUpdated(address indexed wallet, uint256 newPeriod);

    /// @notice Emitted when a Premium subscription is created or renewed.
    event SubscriptionRenewed(address indexed wallet, SubscriptionTier tier, uint256 expiresAt);

    /// @notice Emitted when treasury address is updated.
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @notice Emitted when accumulated subscription fees are withdrawn to the treasury.
    event SubscriptionFeesWithdrawn(address indexed treasury, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                             CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    error RecoveryManager__AlreadyRegistered();
    error RecoveryManager__NotRegistered();
    error RecoveryManager__InvalidBackupAddress();
    error RecoveryManager__InvalidInactivityPeriod();
    error RecoveryManager__ZeroAddress();
    error RecoveryManager__TransferFailed();
    error RecoveryManager__NotAuthorized();
    error RecoveryManager__InsufficientSubscriptionFee();
    error RecoveryManager__MaxBatchSizeExceeded();
    error RecoveryManager__NothingToWithdraw();
    error RecoveryManager__InsufficientBalance();
    error RecoveryManager__DirectTransferNotAllowed();

    /*//////////////////////////////////////////////////////////////
                          FUNCTION SIGNATURES
    //////////////////////////////////////////////////////////////*/

    // --- User-facing ---
    function register(address backupAddress, uint256 inactivityPeriod, SubscriptionTier tier) external payable;

    function deposit() external payable;

    function withdrawAll() external;

    function send(address to, uint256 amount) external;

    function ping() external;

    function updateBackupAddress(address newBackupAddress) external;

    function updateInactivityPeriod(uint256 newPeriod) external;

    function renewSubscription() external payable;

    function cancelRecovery() external;

    // --- Automation ---
    function checkUpkeep(bytes calldata checkData) external view returns (bool upkeepNeeded, bytes memory performData);

    function performUpkeep(bytes calldata performData) external;

    // --- Treasury ---
    function withdrawSubscriptionFees() external;

    function updateTreasury(address newTreasury) external;

    // --- View ---
    function isRegistered(address wallet) external view returns (bool);

    function getRecoveryConfig(address wallet) external view returns (RecoveryConfig memory);

    function isRecoveryDue(address wallet) external view returns (bool);

    function getTimeUntilRecovery(address wallet) external view returns (uint256);

    function getTotalRegistered() external view returns (uint256);

    function getAccumulatedFees() external view returns (uint256);

    function getTreasury() external view returns (address);

    function getRegisteredWallets(uint256 start, uint256 end) external view returns (address[] memory);
}
