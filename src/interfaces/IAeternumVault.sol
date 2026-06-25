// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * @title  IAeternumVault
 * @author Ndubuisi Ugwuja
 * @notice Complete interface for the AeternumVault contract.
 *         Defines all public/external types, events, errors, and function signatures.
 */
interface IAeternumVault {
    /// --- STRUCTS ---
    /**
     * @notice All configuration and state for a single registered wallet.
     * @param backupAddress          Destination address for recovered funds.
     * @param inactivityPeriod       Seconds of inactivity before recovery is triggered.
     * @param lastActivity           Unix timestamp of the user's most recent on-chain interaction.
     * @param balance                ETH (in wei) held in escrow for this wallet.
     * @param isActive               Whether this configuration is live and being monitored.
     * @param failedRecoveryAttempts Number of consecutive failed ETH transfer attempts.
     * @param isAbandoned            Whether the wallet has been permanently deregistered
     *                               after exhausting MAX_RECOVERY_ATTEMPTS.
     */
    struct RecoveryConfig {
        address backupAddress;
        uint256 inactivityPeriod;
        uint256 lastActivity;
        uint256 balance;
        bool isActive;
        uint8 failedRecoveryAttempts;
        bool isAbandoned;
    }

    /// --- EVENTS ---
    /// @notice Emitted when a wallet is successfully registered for recovery.
    event RecoveryRegistered(address indexed wallet, address indexed backupAddress, uint256 inactivityPeriod);

    /// @notice Emitted whenever the inactivity timer is reset (ping, deposit, withdraw, config update).
    event ActivityPinged(address indexed wallet, uint256 timestamp);

    /// @notice Emitted when a recovery transfer executes successfully.
    event RecoveryExecuted(address indexed wallet, address indexed backupAddress, uint256 amount);

    /// @notice Emitted when a recovery transfer fails — wallet state is restored for retry.
    event RecoveryFailed(address indexed wallet, address indexed backupAddress, uint256 amount);

    /// @notice Emitted when a wallet is permanently deregistered after exhausting
    ///         MAX_RECOVERY_ATTEMPTS. Balance remains accessible via withdrawAll()
    ///         or send(). Re-registration with the same backup address is blocked.
    event RecoveryAbandoned(address indexed wallet, address indexed backupAddress, uint256 balance);

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

    /// --- CUSTOM ERRORS ---
    error AeternumVault__AlreadyRegistered();
    error AeternumVault__NotRegistered();
    error AeternumVault__InvalidBackupAddress();
    error AeternumVault__InvalidAddress();
    error AeternumVault__InvalidInactivityPeriod();
    error AeternumVault__MaxRecoveryAttemptsExceeded();
    error AeternumVault__TransferFailed();
    error AeternumVault__InvalidAmount();
    error AeternumVault__InsufficientBalance();
    error AeternumVault__DirectTransferNotAllowed();
    error AeternumVault__WalletAbandoned();

    /// --- FUNCTION SIGNATURES ---

    // Immutables
    function MIN_INACTIVITY_PERIOD() external view returns (uint256);
    function MAX_INACTIVITY_PERIOD() external view returns (uint256);
    function MAX_RECOVERY_ATTEMPTS() external view returns (uint8);

    // User-facing
    function register(address backupAddress, uint256 inactivityPeriod) external payable;
    function deposit() external payable;
    function withdrawAll() external;
    function send(address to, uint256 amount) external;
    function ping() external;
    function updateBackupAddress(address newBackupAddress) external;
    function updateInactivityPeriod(uint256 newPeriod) external;
    function cancelRecovery() external;

    // Keeper interface
    function triggerRecovery(address wallet) external;
    function checkVaultsBatch(uint256 startIndex, uint256 batchSize)
        external
        view
        returns (address[] memory triggerable);

    // View
    function isRegistered(address wallet) external view returns (bool);
    function getRecoveryConfig(address wallet) external view returns (RecoveryConfig memory);
    function isRecoveryDue(address wallet) external view returns (bool);
    function getTimeUntilRecovery(address wallet) external view returns (uint256);
    function isBackupAbandoned(address backup) external view returns (bool);
    function getTotalRegistered() external view returns (uint256);
    function getRegisteredWallets(uint256 start, uint256 end) external view returns (address[] memory);
}
