// SPDX-License-Identifier: MIT
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
     * @param backupAddress      Destination address for recovered funds.
     * @param inactivityPeriod   Seconds of inactivity before recovery is triggered.
     * @param lastActivity       Unix timestamp of the user's most recent on-chain interaction.
     * @param balance            ETH (in wei) held in escrow for this wallet.
     * @param isActive           Whether this configuration is live and being monitored.
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
    event RecoveryRegistered(
        address indexed wallet, address indexed backupAddress, uint256 inactivityPeriod
    );

    /// @notice Emitted whenever the inactivity timer is reset (ping, deposit, withdraw, config update).
    event ActivityPinged(address indexed wallet, uint256 timestamp);

    /// @notice Emitted when Chainlink Automation executes a recovery.
    event RecoveryExecuted(address indexed wallet, address indexed backupAddress, uint256 amount);

    /// @notice Emitted when a recovery transfer fails — wallet state is restored for retry.
    event RecoveryFailed(address indexed wallet, address indexed backupAddress, uint256 amount);

    /// @notice Emitted when a wallet is permanently deregistered after exceeding
    ///         max failed recovery attempts. Balance remains accessible via
    ///         withdrawAll() or send(). Re-registration is permanently blocked.
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
    error AeternumVault__ZeroAddress();
    error AeternumVault__InvalidInactivityPeriod();
    error AeternumVault__MaxPerformUpkeepSizeExceeded();
    error AeternumVault__MaxRecoveryAttemptsExceeded();
    error AeternumVault__TransferFailed();
    error AeternumVault__NotAuthorized();
    error AeternumVault__NothingToWithdraw();
    error AeternumVault__InsufficientBalance();
    error AeternumVault__DirectTransferNotAllowed();
    error AeternumVault__WalletAbandoned();
    error AeternumVault__InvalidConstructorParam();

    /// --- FUNCTION SIGNATURES ---
    // User-facing
    function register(address backupAddress, uint256 inactivityPeriod)
        external
        payable;

    function deposit() external payable;

    function withdrawAll() external;

    function send(address to, uint256 amount) external;

    function ping() external;

    function updateBackupAddress(address newBackupAddress) external;

    function updateInactivityPeriod(uint256 newPeriod) external;

    function cancelRecovery() external;

    // Automation
    function MAX_CHECK_UPKEEP_SIZE() external view returns (uint256);

    function MAX_PERFORM_UPKEEP_SIZE() external view returns (uint256);

    function CURSOR_ADVANCE_INTERVAL() external view returns (uint256);

    function checkUpkeep(bytes calldata checkData) external view returns (bool upkeepNeeded, bytes memory performData);

    function performUpkeep(bytes calldata performData) external;

    // View
    function isRegistered(address wallet) external view returns (bool);

    function getRecoveryConfig(address wallet) external view returns (RecoveryConfig memory);

    function isRecoveryDue(address wallet) external view returns (bool);

    function getTimeUntilRecovery(address wallet) external view returns (uint256);

    function getTotalRegistered() external view returns (uint256);

    function getRegisteredWallets(uint256 start, uint256 end) external view returns (address[] memory);

    function getCheckCursor() external view returns (uint256);

    function getLastCursorAdvance() external view returns (uint256);
}
