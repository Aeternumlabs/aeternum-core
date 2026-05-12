// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AeternumVault} from "../../src/AeternumVault.sol";
import {IAeternumVault} from "../../src/interfaces/IAeternumVault.sol";
import {ReentrantAttacker} from "../mocks/ReentrantAttacker.sol";
import {RejectingReceiver} from "../mocks/RejectingReceiver.sol";
import {RejectingCallerMock} from "../mocks/RejectingCallerMock.sol";

/**
 * @title  AeternumVaultTest
 * @notice Comprehensive test suite for AeternumVault.
 *
 *         Coverage areas:
 *           • Deployment / constructor
 *           • Registration (success paths, revert paths)
 *           • Deposit / send / withdrawAll
 *           • Ping (activity reset)
 *           • Config updates (backup address, inactivity period)
 *           • Recovery cancellation
 *           • Chainlink Automation (checkUpkeep + performUpkeep)
 *           • Cursor behaviour (hold, advance, wrap)
 *           • Recovery failure & abandonment
 *           • Registry integrity (swap-and-pop)
 *           • Security (reentrancy, access control)
 *           • Fuzz tests
 *           • Invariant tests
 */
contract AeternumVaultTest is StdInvariant, Test {
    /// --- TEST SETUP ---
    AeternumVault public rm;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public aliceBackup = makeAddr("aliceBackup");
    address public bobBackup = makeAddr("bobBackup");
    address public carolBackup = makeAddr("carolBackup");

    uint256 public constant STARTING_BALANCE = 100 ether;
    uint256 public constant DEPOSIT_1_ETH = 1 ether;

    uint256 public INACTIVITY_PERIOD;

    /// --- EVENTS ---
    event RecoveryRegistered(address indexed wallet, address indexed backupAddress, uint256 inactivityPeriod);
    event ActivityPinged(address indexed wallet, uint256 timestamp);
    event RecoveryExecuted(address indexed wallet, address indexed backupAddress, uint256 amount);
    event RecoveryFailed(address indexed wallet, address indexed backupAddress, uint256 amount);
    event RecoveryAbandoned(address indexed wallet, address indexed backupAddress, uint256 balance);
    event RecoveryCancelled(address indexed wallet, uint256 refundAmount);
    event Deposited(address indexed wallet, uint256 amount);
    event Sent(address indexed wallet, address indexed to, uint256 amount);
    event Withdrawn(address indexed wallet, uint256 amount);
    event BackupAddressUpdated(address indexed wallet, address indexed newBackupAddress);
    event InactivityPeriodUpdated(address indexed wallet, uint256 newPeriod);

    /// --- SETUP ---
    function setUp() public {
        rm = new AeternumVault(
            180 days, // MIN_INACTIVITY_PERIOD
            3650 days, // MAX_INACTIVITY_PERIOD
            5000, // MAX_CHECK_UPKEEP_SIZE
            50, // MAX_PERFORM_UPKEEP_SIZE
            3, // MAX_RECOVERY_ATTEMPTS
            1 hours // CURSOR_ADVANCE_INTERVAL
        );

        INACTIVITY_PERIOD = rm.MIN_INACTIVITY_PERIOD();

        deal(alice, STARTING_BALANCE);
        deal(bob, STARTING_BALANCE);
        deal(carol, STARTING_BALANCE);

        targetContract(address(rm));
    }

    /// --- HELPERS ---
    AeternumVault cv; // cursor vault for boundary tests

    /// @dev Deploys a vault with configurable scan/perform sizes for cursor boundary testing.
    function _deployCursorVault(uint256 checkSize, uint256 performSize, uint256 interval)
        internal
        returns (AeternumVault)
    {
        return new AeternumVault(180 days, 3650 days, checkSize, performSize, 3, interval);
    }

    /// @dev Registers `count` deterministic wallets into `vault` with 1 ETH each.
    function _registerWallets(AeternumVault vault, uint256 count, uint256 seed)
        internal
        returns (address[] memory users, address[] memory backups)
    {
        users = new address[](count);
        backups = new address[](count);
        uint256 period = vault.MIN_INACTIVITY_PERIOD();

        for (uint256 i = 0; i < count; i++) {
            address user = address(uint160(0xA000 + seed + i));
            address backup = address(uint160(0xB000 + seed + i));
            deal(user, 10 ether);
            vm.prank(user);
            vault.register{value: 1 ether}(backup, period);
            users[i] = user;
            backups[i] = backup;
        }
    }

    /// @dev Warps time past a specific wallet's inactivity period.
    function _warpPastInactivity(address wallet) internal {
        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(wallet);
        vm.warp(cfg.lastActivity + cfg.inactivityPeriod + 1);
    }

    function _registerAlice() internal {
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(aliceBackup, INACTIVITY_PERIOD);
    }

    /// SECTION 1. --- CONSTRUCTOR / DEPLOYMENT ---
    function test_constructor_initialState() public view {
        assertEq(rm.getTotalRegistered(), 0);
        assertEq(rm.getCheckCursor(), 0);
        assertEq(rm.getLastCursorAdvance(), 0);
    }

    function test_constructor_revertsIfMinInactivityIsZero() public {
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        new AeternumVault(0, 3650 days, 5000, 50, 3, 1 hours);
    }

    function test_constructor_revertsIfMaxLessThanMin() public {
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        new AeternumVault(180 days, 300 days, 5000, 50, 3, 1 hours);
    }

    function test_constructor_revertsIfMaxPerformUpkeepSizeIsZero() public {
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidConstructorParam.selector);
        new AeternumVault(180 days, 3650 days, 5000, 0, 3, 1 hours);
    }

    function test_constructor_revertsIfMaxRecoveryAttemptsIsZero() public {
        vm.expectRevert(IAeternumVault.AeternumVault__MaxRecoveryAttemptsExceeded.selector);
        new AeternumVault(180 days, 3650 days, 5000, 50, 0, 1 hours);
    }

    /// SECTION 2. --- REGISTER — SUCCESS PATHS ---
    function test_register_storesConfig() public {
        _registerAlice();

        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertEq(cfg.backupAddress, aliceBackup);
        assertEq(cfg.inactivityPeriod, INACTIVITY_PERIOD);
        assertEq(cfg.balance, DEPOSIT_1_ETH);
        assertEq(cfg.lastActivity, block.timestamp);
        assertTrue(cfg.isActive);
        assertFalse(cfg.isAbandoned);
        assertEq(cfg.failedRecoveryAttempts, 0);
    }

    function test_register_incrementsRegistry() public {
        _registerAlice();
        assertEq(rm.getTotalRegistered(), 1);
    }

    function test_register_emitsEvents() public {
        vm.expectEmit(true, true, false, true);
        emit RecoveryRegistered(alice, aliceBackup, INACTIVITY_PERIOD);

        vm.expectEmit(true, false, false, true);
        emit Deposited(alice, DEPOSIT_1_ETH);

        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(aliceBackup, INACTIVITY_PERIOD);
    }

    function test_register_withZeroDeposit_isValid() public {
        vm.prank(alice);
        rm.register{value: 0}(aliceBackup, INACTIVITY_PERIOD);

        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertEq(cfg.balance, 0);
        assertTrue(cfg.isActive);
    }

    function test_register_withZeroDeposit_doesNotEmitDeposited() public {
        vm.recordLogs();
        vm.prank(alice);
        rm.register{value: 0}(aliceBackup, INACTIVITY_PERIOD);

        // Verify Deposited was NOT emitted (zero-value deposit)
        bool depositedFound = false;
        bytes32 depositedSig = keccak256("Deposited(address,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == depositedSig) depositedFound = true;
        }
        assertFalse(depositedFound);
    }

    function test_register_multipleUsers() public {
        _registerAlice();

        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(bobBackup, INACTIVITY_PERIOD);

        assertEq(rm.getTotalRegistered(), 2);
    }

    /// SECTION 3. --- REGISTER — REVERT PATHS ---
    function test_register_revertsIfAlreadyRegistered() public {
        _registerAlice();

        vm.expectRevert(IAeternumVault.AeternumVault__AlreadyRegistered.selector);
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(aliceBackup, INACTIVITY_PERIOD);
    }

    function test_register_revertsIfBackupIsZeroAddress() public {
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidBackupAddress.selector);
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(0), INACTIVITY_PERIOD);
    }

    function test_register_revertsIfBackupIsSelf() public {
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidBackupAddress.selector);
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(alice, INACTIVITY_PERIOD);
    }

    function test_register_revertsIfPeriodTooShort() public {
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(aliceBackup, INACTIVITY_PERIOD - 1);
    }

    function test_register_revertsIfPeriodTooLong() public {
        uint256 tooLong = rm.MAX_INACTIVITY_PERIOD() + 1;
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        vm.prank(alice);
        rm.register{value: 0}(aliceBackup, tooLong);
    }

    function test_register_revertsOnDirectTransfer() public {
        vm.expectRevert(IAeternumVault.AeternumVault__DirectTransferNotAllowed.selector);
        vm.prank(alice);
        (bool sent,) = address(rm).call{value: 1 ether}("");
        (sent);
    }

    function test_register_revertsIfBackupIsAbandoned() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(alice);
            (, bytes memory pd) = rm.checkUpkeep(bytes(""));
            rm.performUpkeep(pd);
        }

        assertTrue(rm.isBackupAbandoned(address(badBackup)));

        // Bob tries the same bad backup — blocked
        vm.expectRevert(IAeternumVault.AeternumVault__WalletAbandoned.selector);
        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);
    }

    /// SECTION 4. --- DEPOSIT ---
    function test_deposit_increasesBalance() public {
        _registerAlice();
        uint256 balanceBefore = rm.getRecoveryConfig(alice).balance;

        vm.prank(alice);
        rm.deposit{value: 0.5 ether}();

        assertEq(rm.getRecoveryConfig(alice).balance, balanceBefore + 0.5 ether);
    }

    function test_deposit_resetsActivityTimer() public {
        _registerAlice();
        uint256 warpTo = block.timestamp + 50 days;
        vm.warp(warpTo);

        vm.prank(alice);
        rm.deposit{value: 0.5 ether}();

        assertEq(rm.getRecoveryConfig(alice).lastActivity, warpTo);
    }

    function test_deposit_emitsEvents() public {
        _registerAlice();

        vm.expectEmit(true, false, false, true);
        emit Deposited(alice, 0.5 ether);

        vm.expectEmit(true, false, false, true);
        emit ActivityPinged(alice, block.timestamp);

        vm.prank(alice);
        rm.deposit{value: 0.5 ether}();
    }

    function test_deposit_revertsIfNotRegistered() public {
        vm.expectRevert(IAeternumVault.AeternumVault__NotRegistered.selector);
        vm.prank(alice);
        rm.deposit{value: 0.5 ether}();
    }

    function test_deposit_revertsIfZeroValue() public {
        _registerAlice();

        vm.expectRevert(IAeternumVault.AeternumVault__InvalidAmount.selector);
        vm.prank(alice);
        rm.deposit{value: 0}();
    }

    /// SECTION 5. --- WITHDRAWALL ---
    function test_withdrawAll_emptiesBalance() public {
        _registerAlice();

        vm.prank(alice);
        rm.withdrawAll();

        assertEq(rm.getRecoveryConfig(alice).balance, 0);
    }

    function test_withdrawAll_keepsConfigActive() public {
        _registerAlice();

        vm.prank(alice);
        rm.withdrawAll();

        assertTrue(rm.getRecoveryConfig(alice).isActive);
        assertEq(rm.getTotalRegistered(), 1);
    }

    function test_withdrawAll_revertsIfZeroBalance() public {
        vm.prank(alice);
        rm.register{value: 0}(aliceBackup, INACTIVITY_PERIOD);

        vm.expectRevert(IAeternumVault.AeternumVault__InvalidAmount.selector);
        vm.prank(alice);
        rm.withdrawAll();
    }

    function test_withdrawAll_revertsIfTransferFails() public {
        RejectingCallerMock rejecter = new RejectingCallerMock(address(rm));
        deal(address(rejecter), 2 ether);

        rejecter.doRegister{value: DEPOSIT_1_ETH}(aliceBackup, INACTIVITY_PERIOD);

        vm.expectRevert(IAeternumVault.AeternumVault__TransferFailed.selector);
        rejecter.doWithdrawAll();
    }

    /// SECTION 5b. --- SEND ---
    function test_send_transfersETHtoRecipient() public {
        _registerAlice();
        address recipient = makeAddr("recipient");

        vm.prank(alice);
        rm.send(recipient, 0.4 ether);

        assertEq(recipient.balance, 0.4 ether);
    }

    function test_send_reducesVaultBalance() public {
        _registerAlice();

        vm.prank(alice);
        rm.send(makeAddr("recipient"), 0.4 ether);

        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH - 0.4 ether);
    }

    function test_send_resetsActivityTimer() public {
        _registerAlice();
        vm.warp(block.timestamp + 50 days);

        vm.prank(alice);
        rm.send(makeAddr("recipient"), 0.1 ether);

        assertEq(rm.getRecoveryConfig(alice).lastActivity, block.timestamp);
    }

    function test_send_emitsEvents() public {
        _registerAlice();
        address recipient = makeAddr("recipient");

        vm.expectEmit(true, true, false, true);
        emit Sent(alice, recipient, 0.3 ether);

        vm.expectEmit(true, false, false, true);
        emit ActivityPinged(alice, block.timestamp);

        vm.prank(alice);
        rm.send(recipient, 0.3 ether);
    }

    function test_send_revertsOnZeroAddress() public {
        _registerAlice();
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidAddress.selector);
        vm.prank(alice);
        rm.send(address(0), 0.1 ether);
    }

    function test_send_revertsOnZeroAmount() public {
        _registerAlice();
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidAmount.selector);
        vm.prank(alice);
        rm.send(makeAddr("recipient"), 0);
    }

    function test_send_revertsOnInsufficientBalance() public {
        _registerAlice();
        vm.expectRevert(IAeternumVault.AeternumVault__InsufficientBalance.selector);
        vm.prank(alice);
        rm.send(makeAddr("recipient"), DEPOSIT_1_ETH + 1);
    }

    function test_send_revertsIfNotRegistered() public {
        vm.expectRevert(IAeternumVault.AeternumVault__NotRegistered.selector);
        vm.prank(alice);
        rm.send(makeAddr("recipient"), 0.1 ether);
    }

    function test_send_revertsIfTransferFails() public {
        _registerAlice();
        RejectingReceiver rejecter = new RejectingReceiver();

        vm.expectRevert(IAeternumVault.AeternumVault__TransferFailed.selector);
        vm.prank(alice);
        rm.send(address(rejecter), 0.1 ether);
    }

    function testFuzz_send_amount(uint128 amount) public {
        vm.assume(amount > 0 && amount <= DEPOSIT_1_ETH);
        _registerAlice();
        address recipient = makeAddr("recipient");

        vm.prank(alice);
        rm.send(recipient, amount);

        assertEq(recipient.balance, amount);
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH - amount);
    }

    /// SECTION 6. --- PING ---
    function test_ping_resetsLastActivity() public {
        _registerAlice();
        uint256 laterTs = block.timestamp + 100 days;
        vm.warp(laterTs);

        vm.prank(alice);
        rm.ping();

        assertEq(rm.getRecoveryConfig(alice).lastActivity, laterTs);
    }

    function test_ping_preventsRecovery() public {
        _registerAlice();
        // Warp to 3/4 of inactivity period and ping
        vm.warp(block.timestamp + (INACTIVITY_PERIOD * 3 / 4));
        vm.prank(alice);
        rm.ping(); // Reset timer

        // Warp another 3/4 — still under one full period from last ping
        vm.warp(block.timestamp + (INACTIVITY_PERIOD * 3 / 4));
        assertFalse(rm.isRecoveryDue(alice));
    }

    function test_ping_revertsIfNotRegistered() public {
        vm.expectRevert(IAeternumVault.AeternumVault__NotRegistered.selector);
        vm.prank(alice);
        rm.ping();
    }

    function test_ping_emitsActivityPinged() public {
        _registerAlice();

        vm.expectEmit(true, false, false, true);
        emit ActivityPinged(alice, block.timestamp);

        vm.prank(alice);
        rm.ping();
    }

    /// SECTION 7. --- CONFIG UPDATES ---
    function test_updateBackupAddress_success() public {
        _registerAlice();
        address newBackup = makeAddr("newBackup");

        vm.prank(alice);
        rm.updateBackupAddress(newBackup);

        assertEq(rm.getRecoveryConfig(alice).backupAddress, newBackup);
    }

    function test_updateBackupAddress_resetsTimer() public {
        _registerAlice();
        vm.warp(block.timestamp + 50 days);

        vm.prank(alice);
        rm.updateBackupAddress(makeAddr("newBackup"));

        assertEq(rm.getRecoveryConfig(alice).lastActivity, block.timestamp);
    }

    function test_updateBackupAddress_revertsOnZero() public {
        _registerAlice();
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidBackupAddress.selector);
        vm.prank(alice);
        rm.updateBackupAddress(address(0));
    }

    function test_updateBackupAddress_revertsOnSelf() public {
        _registerAlice();
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidBackupAddress.selector);
        vm.prank(alice);
        rm.updateBackupAddress(alice);
    }

    function test_updateBackupAddress_revertsIfBackupIsAbandoned() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(alice);
            (, bytes memory pd) = rm.checkUpkeep(bytes(""));
            rm.performUpkeep(pd);
        }

        // Re-register with a good backup
        vm.prank(alice);
        rm.register{value: 0.5 ether}(aliceBackup, INACTIVITY_PERIOD);

        // Trying to update back to the abandoned address is blocked
        vm.expectRevert(IAeternumVault.AeternumVault__WalletAbandoned.selector);
        vm.prank(alice);
        rm.updateBackupAddress(address(badBackup));
    }

    function test_updateInactivityPeriod_success() public {
        _registerAlice();

        vm.prank(alice);
        rm.updateInactivityPeriod(400 days);

        assertEq(rm.getRecoveryConfig(alice).inactivityPeriod, 400 days);
    }

    function test_updateInactivityPeriod_revertsIfBelowMin() public {
        _registerAlice();
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        vm.prank(alice);
        rm.updateInactivityPeriod(INACTIVITY_PERIOD - 1);
    }

    function test_updateInactivityPeriod_revertsIfPeriodTooLong() public {
        _registerAlice();
        uint256 tooLong = rm.MAX_INACTIVITY_PERIOD() + 1;
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        vm.prank(alice);
        rm.updateInactivityPeriod(tooLong);
    }

    function test_updateInactivityPeriod_resetsTimer() public {
        _registerAlice();
        vm.warp(block.timestamp + 50 days);

        vm.prank(alice);
        rm.updateInactivityPeriod(400 days);

        assertEq(rm.getRecoveryConfig(alice).lastActivity, block.timestamp);
    }

    /// SECTION 8. --- CANCEL RECOVERY ---
    function test_cancelRecovery_refundsBalance() public {
        _registerAlice();
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        rm.cancelRecovery();

        assertEq(alice.balance, ethBefore + DEPOSIT_1_ETH);
    }

    function test_cancelRecovery_removesFromRegistry() public {
        _registerAlice();

        vm.prank(alice);
        rm.cancelRecovery();

        assertEq(rm.getTotalRegistered(), 0);
        assertFalse(rm.getRecoveryConfig(alice).isActive);
    }

    function test_cancelRecovery_emitsEvent() public {
        _registerAlice();

        vm.expectEmit(true, false, false, true);
        emit RecoveryCancelled(alice, DEPOSIT_1_ETH);

        vm.prank(alice);
        rm.cancelRecovery();
    }

    function test_cancelRecovery_allowsReRegistration() public {
        _registerAlice();
        vm.prank(alice);
        rm.cancelRecovery();

        vm.prank(alice);
        rm.register{value: 0.5 ether}(aliceBackup, INACTIVITY_PERIOD);
        assertTrue(rm.getRecoveryConfig(alice).isActive);
    }

    function test_cancelRecovery_revertsIfNotRegistered() public {
        vm.expectRevert(IAeternumVault.AeternumVault__NotRegistered.selector);
        vm.prank(alice);
        rm.cancelRecovery();
    }

    function test_cancelRecovery_withZeroBalance_noTransfer() public {
        vm.prank(alice);
        rm.register{value: 0}(aliceBackup, INACTIVITY_PERIOD);
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        rm.cancelRecovery();

        assertEq(alice.balance, ethBefore);
    }

    function test_cancelRecovery_whenWalletIsLastInRegistry() public {
        _registerAlice();
        vm.prank(alice);
        rm.cancelRecovery();

        assertEq(rm.getTotalRegistered(), 0);
        assertFalse(rm.isRegistered(alice));
    }

    function test_cancelRecovery_revertsIfTransferFails() public {
        RejectingCallerMock rejecter = new RejectingCallerMock(address(rm));
        deal(address(rejecter), 2 ether);

        rejecter.doRegister{value: DEPOSIT_1_ETH}(aliceBackup, INACTIVITY_PERIOD);

        vm.expectRevert(IAeternumVault.AeternumVault__TransferFailed.selector);
        rejecter.doCancelRecovery();
    }

    /// SECTION 9. --- CHECK UPKEEP ---
    function test_checkUpkeep_returnsFalseIfRegistryEmpty() public view {
        (bool needed,) = rm.checkUpkeep(bytes(""));
        assertFalse(needed);
    }

    function test_checkUpkeep_returnsFalseIfNoWalletsDueAndIntervalNotElapsed() public {
        _registerAlice();
        (bool needed,) = rm.checkUpkeep(bytes(""));
        assertFalse(needed);
    }

    function test_checkUpkeep_returnsTrueWithCandidatesWhenWalletIsDue() public {
        _registerAlice();
        _warpPastInactivity(alice);

        (bool needed, bytes memory performData) = rm.checkUpkeep(bytes(""));

        assertTrue(needed);
        (address[] memory candidates,,) = abi.decode(performData, (address[], uint256, bool));
        assertEq(candidates.length, 1);
        assertEq(candidates[0], alice);
    }

    function test_checkUpkeep_doesNotIncludeZeroBalanceWallet_inCandidates() public {
        vm.prank(alice);
        rm.register{value: 0}(aliceBackup, INACTIVITY_PERIOD);
        _warpPastInactivity(alice);

        (bool needed, bytes memory performData) = rm.checkUpkeep(bytes(""));

        if (needed) {
            (address[] memory candidates,,) = abi.decode(performData, (address[], uint256, bool));
            for (uint256 i = 0; i < candidates.length; i++) {
                assertTrue(candidates[i] != alice, "Zero-balance wallet must not appear as candidate");
            }
        }
    }

    function test_checkUpkeep_returnsMaxPerformSize_whenMoreWalletsDueThanPerformCap() public {
        cv = _deployCursorVault(20, 3, 30 seconds);
        _registerWallets(cv, 10, 0);
        vm.warp(block.timestamp + cv.MIN_INACTIVITY_PERIOD() + 1);

        (bool needed, bytes memory performData) = cv.checkUpkeep(bytes(""));

        assertTrue(needed);
        (address[] memory candidates,,) = abi.decode(performData, (address[], uint256, bool));
        assertEq(candidates.length, cv.MAX_PERFORM_UPKEEP_SIZE());
    }

    function test_checkUpkeep_ignoresCheckData_parameter() public {
        _registerAlice();
        _warpPastInactivity(alice);

        bytes memory arbitraryCheckData = abi.encode(uint256(999), uint256(999));
        (bool needed, bytes memory performData) = rm.checkUpkeep(arbitraryCheckData);

        assertTrue(needed);
        (address[] memory candidates,,) = abi.decode(performData, (address[], uint256, bool));
        assertEq(candidates[0], alice);
    }

    /// SECTION 9b. --- CURSOR BEHAVIOUR ---
    function test_cursor_holdsPosition_whenDueWalletsExistInWindow() public {
        cv = _deployCursorVault(10, 3, 30 seconds);
        _registerWallets(cv, 5, 0);
        vm.warp(block.timestamp + cv.MIN_INACTIVITY_PERIOD() + 1);

        uint256 cursorBefore = cv.getCheckCursor();

        (, bytes memory performData) = cv.checkUpkeep(bytes(""));
        (, uint256 nextCursor,) = abi.decode(performData, (address[], uint256, bool));

        assertEq(nextCursor, cursorBefore, "Cursor should HOLD when due wallets exist");
    }

    function test_cursor_doesNotUpdateAdvanceTimestamp_duringRecoveryPass() public {
        cv = _deployCursorVault(10, 3, 30 seconds);
        _registerWallets(cv, 3, 0);
        vm.warp(block.timestamp + cv.MIN_INACTIVITY_PERIOD() + 1);

        uint256 timestampBefore = cv.getLastCursorAdvance();

        (, bytes memory performData) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(performData);

        assertEq(cv.getLastCursorAdvance(), timestampBefore, "Advance timestamp must not update when cursor holds");
    }

    function test_cursor_remainsAtZero_afterPartialWindowRecovery() public {
        cv = _deployCursorVault(10, 3, 30 seconds);
        _registerWallets(cv, 7, 0);
        vm.warp(block.timestamp + cv.MIN_INACTIVITY_PERIOD() + 1);

        (, bytes memory pd1) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd1);
        assertEq(cv.getCheckCursor(), 0, "Cursor should still be 0 after first batch");

        (, bytes memory pd2) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd2);
        assertEq(cv.getCheckCursor(), 0, "Cursor should still be 0 after second batch");

        (, bytes memory pd3) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd3);
        assertEq(cv.getCheckCursor(), 0, "Cursor should still be 0 after final batch");

        assertEq(cv.getTotalRegistered(), 0);
    }

    function test_cursor_returnsFalse_whenWindowClear_andIntervalNotElapsed() public {
        cv = _deployCursorVault(10, 3, 30 seconds);
        _registerWallets(cv, 3, 0);

        (bool needed,) = cv.checkUpkeep(bytes(""));
        assertFalse(needed, "Should return false before interval elapses");
    }

    function test_cursor_advancesWithEmptyCandidates_whenWindowClear_andIntervalElapsed() public {
        cv = _deployCursorVault(10, 3, 30 seconds);
        _registerWallets(cv, 3, 0);

        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);

        (bool needed, bytes memory performData) = cv.checkUpkeep(bytes(""));
        assertTrue(needed, "Should advance cursor after interval");

        (address[] memory candidates,, bool isIdleAdvance) = abi.decode(performData, (address[], uint256, bool));

        assertEq(candidates.length, 0, "No due wallets - candidates should be empty");
        assertTrue(isIdleAdvance, "Should be flagged as an idle advance");
    }

    function test_cursor_advancesToNextWindow_afterIdleAdvance() public {
        cv = _deployCursorVault(4, 2, 30 seconds);
        _registerWallets(cv, 8, 0);
        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);

        uint256 cursorBefore = cv.getCheckCursor();

        (, bytes memory pd) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd);

        assertEq(cv.getCheckCursor(), cursorBefore + 4);
    }

    function test_cursor_updatesAdvanceTimestamp_onIdleAdvance() public {
        cv = _deployCursorVault(10, 3, 30 seconds);
        _registerWallets(cv, 3, 0);
        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);

        (, bytes memory pd) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd);

        assertEq(cv.getLastCursorAdvance(), block.timestamp, "Advance timestamp must update on idle advance");
    }

    function test_cursor_wrapsToZero_whenEndOfRegistryReached() public {
        cv = _deployCursorVault(4, 2, 30 seconds);
        _registerWallets(cv, 6, 0);

        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);
        (, bytes memory pd1) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd1);
        assertEq(cv.getCheckCursor(), 4);

        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);
        (, bytes memory pd2) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd2);
        assertEq(cv.getCheckCursor(), 0, "Cursor should wrap to 0 at end of registry");
    }

    function test_cursor_resetsToZero_whenRegistryShrunkBelowCursor() public {
        cv = _deployCursorVault(10, 3, 30 seconds);
        (address[] memory users,) = _registerWallets(cv, 10, 0);

        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);
        (, bytes memory pd) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd);

        for (uint256 i = 0; i < 7; i++) {
            vm.prank(users[i]);
            cv.cancelRecovery();
        }

        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);
        // Should not revert — cursor >= total resets gracefully to 0
        cv.checkUpkeep(bytes(""));
        assertTrue(true, "No revert when cursor exceeds total");
    }

    function test_cursor_advancesAfterWindowFullyCleared() public {
        cv = _deployCursorVault(6, 3, 30 seconds);
        _registerWallets(cv, 6, 0);
        vm.warp(block.timestamp + cv.MIN_INACTIVITY_PERIOD() + 1);

        (, bytes memory pd1) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd1);
        assertEq(cv.getCheckCursor(), 0);

        (, bytes memory pd2) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd2);
        assertEq(cv.getCheckCursor(), 0);
        assertEq(cv.getTotalRegistered(), 0);

        // Add non-due wallets so registry is not empty for interval gating
        _registerWallets(cv, 3, 100);
        assertEq(cv.getTotalRegistered(), 3);

        // Idle advance fires immediately (s_lastCursorAdvance=0, timestamp=180 days)
        (bool immediateAdvance, bytes memory immPd) = cv.checkUpkeep(bytes(""));
        assertTrue(immediateAdvance, "Idle advance immediately eligible");
        cv.performUpkeep(immPd);
        assertEq(cv.getLastCursorAdvance(), block.timestamp, "Timer reset after first idle advance");

        // Before interval: no upkeep needed
        (bool tooSoon,) = cv.checkUpkeep(bytes(""));
        assertFalse(tooSoon, "Should return false before interval elapses again");

        // After interval: idle advance triggers again
        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);
        (bool neededAfter, bytes memory pd3) = cv.checkUpkeep(bytes(""));
        assertTrue(neededAfter, "Should trigger idle advance after interval");

        (address[] memory candidates,, bool isIdleAdvance) = abi.decode(pd3, (address[], uint256, bool));
        assertEq(candidates.length, 0, "No due wallets");
        assertTrue(isIdleAdvance, "Should be idle advance");

        cv.performUpkeep(pd3);
        assertEq(cv.getLastCursorAdvance(), block.timestamp, "Timestamp updated after second idle advance");
    }

    /// SECTION 10. --- PERFORM UPKEEP ---
    function test_performUpkeep_executesRecovery_andZeroesBalance() public {
        _registerAlice();
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(pd);

        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertFalse(cfg.isActive);
        assertEq(cfg.balance, 0);
    }

    function test_performUpkeep_transfersETHToBackup() public {
        _registerAlice();
        _warpPastInactivity(alice);
        uint256 backupBefore = aliceBackup.balance;

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(pd);

        assertEq(aliceBackup.balance, backupBefore + DEPOSIT_1_ETH);
    }

    function test_performUpkeep_removesWalletFromRegistry() public {
        _registerAlice();
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(pd);

        assertEq(rm.getTotalRegistered(), 0);
    }

    function test_performUpkeep_emitsRecoveryExecuted() public {
        _registerAlice();
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));

        vm.expectEmit(true, true, false, true);
        emit RecoveryExecuted(alice, aliceBackup, DEPOSIT_1_ETH);

        rm.performUpkeep(pd);
    }

    function test_performUpkeep_revertsIfCandidatesExceedMaxPerformSize() public {
        uint256 overSize = rm.MAX_PERFORM_UPKEEP_SIZE() + 1;
        address[] memory tooMany = new address[](overSize);
        bytes memory pd = abi.encode(tooMany, uint256(0), false);

        vm.expectRevert(IAeternumVault.AeternumVault__MaxPerformUpkeepSizeExceeded.selector);
        rm.performUpkeep(pd);
    }

    function test_performUpkeep_processesMultipleWallets() public {
        address[3] memory users = [alice, bob, carol];
        address[3] memory backups = [aliceBackup, bobBackup, carolBackup];

        for (uint256 i = 0; i < 3; i++) {
            deal(users[i], 2 ether);
            vm.prank(users[i]);
            rm.register{value: DEPOSIT_1_ETH}(backups[i], INACTIVITY_PERIOD);
        }

        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);
        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(pd);

        assertEq(rm.getTotalRegistered(), 0);
        for (uint256 i = 0; i < 3; i++) {
            assertFalse(rm.getRecoveryConfig(users[i]).isActive);
            assertEq(backups[i].balance, DEPOSIT_1_ETH);
        }
    }

    function test_performUpkeep_setsCheckCursor_toNextCursor() public {
        cv = _deployCursorVault(4, 2, 30 seconds);
        _registerWallets(cv, 4, 0);

        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);
        (, bytes memory pd) = cv.checkUpkeep(bytes(""));
        (, uint256 nextCursor,) = abi.decode(pd, (address[], uint256, bool));

        cv.performUpkeep(pd);

        assertEq(cv.getCheckCursor(), nextCursor);
    }

    function test_performUpkeep_holdsCheckCursor_duringRecoveryPass() public {
        cv = _deployCursorVault(10, 3, 30 seconds);
        _registerWallets(cv, 5, 0);
        vm.warp(block.timestamp + cv.MIN_INACTIVITY_PERIOD() + 1);

        uint256 cursorBefore = cv.getCheckCursor();
        (, bytes memory pd) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd);

        assertEq(cv.getCheckCursor(), cursorBefore, "Cursor must remain at same position during recovery pass");
    }

    /// STALE DATA SAFETY
    function test_staleData_skipsWallet_afterUserPings() public {
        _registerAlice();
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        vm.prank(alice);
        rm.ping();
        rm.performUpkeep(pd);

        assertTrue(rm.getRecoveryConfig(alice).isActive);
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH);
    }

    function test_staleData_skipsWallet_afterUserDeposits() public {
        _registerAlice();
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        vm.prank(alice);
        rm.deposit{value: 0.1 ether}();
        rm.performUpkeep(pd);

        assertTrue(rm.getRecoveryConfig(alice).isActive);
    }

    function test_staleData_skipsWallet_afterUserCancelsRecovery() public {
        _registerAlice();
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        vm.prank(alice);
        rm.cancelRecovery();
        rm.performUpkeep(pd); // must not revert

        assertFalse(rm.getRecoveryConfig(alice).isActive);
        assertEq(rm.getTotalRegistered(), 0);
    }

    function test_staleData_skipsAlreadyRecoveredWallet() public {
        _registerAlice();
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(pd);
        rm.performUpkeep(pd); // second call with stale data — must not revert
        assertEq(rm.getRecoveryConfig(alice).balance, 0);
    }

    function test_staleData_continuesBatch_whenOneWalletStale() public {
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(aliceBackup, INACTIVITY_PERIOD);
        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(bobBackup, INACTIVITY_PERIOD);

        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);
        (, bytes memory pd) = rm.checkUpkeep(bytes(""));

        vm.prank(alice);
        rm.ping(); // alice goes stale

        rm.performUpkeep(pd);

        assertTrue(rm.getRecoveryConfig(alice).isActive);
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH);
        assertFalse(rm.getRecoveryConfig(bob).isActive);
        assertEq(bobBackup.balance, DEPOSIT_1_ETH);
    }

    /// SECTION 10b. --- RECOVERY FAILURE & ABANDONMENT ---
    function test_performUpkeep_emitsRecoveryFailed_onBadBackupAddress() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));

        vm.expectEmit(true, true, false, true);
        emit RecoveryFailed(alice, address(badBackup), DEPOSIT_1_ETH);

        rm.performUpkeep(pd);
    }

    function test_performUpkeep_restoresState_onFailedTransfer() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(pd);

        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertTrue(cfg.isActive);
        assertEq(cfg.balance, DEPOSIT_1_ETH);
        assertEq(rm.getTotalRegistered(), 1);
    }

    function test_performUpkeep_continuesBatch_afterOneFails() public {
        RejectingReceiver badBackup = new RejectingReceiver();

        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);
        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(bobBackup, INACTIVITY_PERIOD);

        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);
        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(pd);

        assertTrue(rm.getRecoveryConfig(alice).isActive);
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH);
        assertFalse(rm.getRecoveryConfig(bob).isActive);
        assertEq(bobBackup.balance, DEPOSIT_1_ETH);
    }

    function test_executeRecovery_incrementsFailedAttempts() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(pd);

        assertEq(rm.getRecoveryConfig(alice).failedRecoveryAttempts, 1);
    }

    function test_executeRecovery_abandonedAfterMaxAttempts() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(alice);
            (, bytes memory pd) = rm.checkUpkeep(bytes(""));
            rm.performUpkeep(pd);
        }

        assertFalse(rm.getRecoveryConfig(alice).isActive);
        assertTrue(rm.getRecoveryConfig(alice).isAbandoned);
        assertEq(rm.getTotalRegistered(), 0);
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH);
        assertTrue(rm.isBackupAbandoned(address(badBackup)));
    }

    function test_executeRecovery_emitsRecoveryAbandoned_atMaxAttempts() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS() - 1; i++) {
            _warpPastInactivity(alice);
            (, bytes memory pd) = rm.checkUpkeep(bytes(""));
            rm.performUpkeep(pd);
        }

        _warpPastInactivity(alice);
        (, bytes memory finalPd) = rm.checkUpkeep(bytes(""));

        vm.expectEmit(true, true, false, true);
        emit RecoveryAbandoned(alice, address(badBackup), DEPOSIT_1_ETH);

        rm.performUpkeep(finalPd);
    }

    function test_abandonedWallet_checkUpkeepSkipsIt() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(alice);
            (, bytes memory pd) = rm.checkUpkeep(bytes(""));
            rm.performUpkeep(pd);
        }

        vm.warp(block.timestamp + rm.CURSOR_ADVANCE_INTERVAL() + 1);
        (bool advanceNeeded, bytes memory advancePd) = rm.checkUpkeep(bytes(""));

        if (advanceNeeded) {
            rm.performUpkeep(advancePd);
            (address[] memory candidates,,) = abi.decode(advancePd, (address[], uint256, bool));
            for (uint256 i = 0; i < candidates.length; i++) {
                assertTrue(candidates[i] != alice, "Abandoned wallet must never appear as candidate");
            }
        }

        assertEq(rm.getTotalRegistered(), 0);
        assertTrue(rm.getRecoveryConfig(alice).isAbandoned);
    }

    function test_reregister_carriesOverAbandonedBalance_whenSkippingWithdrawal() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(alice);
            (, bytes memory pd) = rm.checkUpkeep(bytes(""));
            rm.performUpkeep(pd);
        }

        assertTrue(rm.getRecoveryConfig(alice).isAbandoned);
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH);

        uint256 newDeposit = 0.5 ether;
        vm.prank(alice);
        rm.register{value: newDeposit}(aliceBackup, INACTIVITY_PERIOD);

        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertEq(cfg.balance, DEPOSIT_1_ETH + newDeposit, "Carried + new deposit must sum correctly");
        assertTrue(cfg.isActive);
        assertFalse(cfg.isAbandoned);
        assertEq(cfg.backupAddress, aliceBackup);
    }

    function test_reregister_carriedBalance_isFullyRecoverableByNewBackup() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(alice);
            (, bytes memory pd) = rm.checkUpkeep(bytes(""));
            rm.performUpkeep(pd);
        }

        uint256 newDeposit = 0.5 ether;
        vm.prank(alice);
        rm.register{value: newDeposit}(aliceBackup, INACTIVITY_PERIOD);

        _warpPastInactivity(alice);
        uint256 backupBefore = aliceBackup.balance;
        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(pd);

        assertEq(
            aliceBackup.balance,
            backupBefore + DEPOSIT_1_ETH + newDeposit,
            "New backup must receive carried + new deposit"
        );
        assertEq(rm.getRecoveryConfig(alice).balance, 0);
        assertFalse(rm.getRecoveryConfig(alice).isActive);
    }

    function test_reregister_withZeroAbandonedBalance_worksNormally() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(alice);
            (, bytes memory pd) = rm.checkUpkeep(bytes(""));
            rm.performUpkeep(pd);
        }

        vm.prank(alice);
        rm.withdrawAll(); // clear balance before re-registering
        assertEq(rm.getRecoveryConfig(alice).balance, 0);

        uint256 newDeposit = 0.5 ether;
        vm.prank(alice);
        rm.register{value: newDeposit}(aliceBackup, INACTIVITY_PERIOD);

        assertEq(
            rm.getRecoveryConfig(alice).balance,
            newDeposit,
            "No carry-over when balance was withdrawn before re-registration"
        );
    }

    function test_reregister_carriedBalance_contractHoldsCorrectETH() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(alice);
            (, bytes memory pd) = rm.checkUpkeep(bytes(""));
            rm.performUpkeep(pd);
        }

        uint256 contractBalanceBefore = address(rm).balance;

        uint256 newDeposit = 0.5 ether;
        vm.prank(alice);
        rm.register{value: newDeposit}(aliceBackup, INACTIVITY_PERIOD);

        assertEq(
            address(rm).balance,
            contractBalanceBefore + newDeposit,
            "Contract balance must grow by exactly the new deposit"
        );
        assertEq(
            rm.getRecoveryConfig(alice).balance,
            address(rm).balance,
            "Config balance must equal contract ETH when alice is the only depositor"
        );
    }

    /// SECTION 11. --- VIEW HELPERS ---
    function test_isRecoveryDue_falseBeforePeriod() public {
        _registerAlice();
        vm.warp(block.timestamp + INACTIVITY_PERIOD - 1);
        assertFalse(rm.isRecoveryDue(alice));
    }

    function test_isRecoveryDue_trueAfterPeriod() public {
        _registerAlice();
        _warpPastInactivity(alice);
        assertTrue(rm.isRecoveryDue(alice));
    }

    function test_getTimeUntilRecovery_returnsCorrectValue() public {
        _registerAlice();
        uint256 elapsed = 30 days;
        vm.warp(block.timestamp + elapsed);

        uint256 remaining = rm.getTimeUntilRecovery(alice);
        assertEq(remaining, INACTIVITY_PERIOD - elapsed);
    }

    function test_getTimeUntilRecovery_returnsZeroWhenDue() public {
        _registerAlice();
        _warpPastInactivity(alice);
        assertEq(rm.getTimeUntilRecovery(alice), 0);
    }

    function test_getRegisteredWallets_pagination() public {
        _registerAlice();
        vm.prank(bob);
        rm.register{value: 0}(bobBackup, INACTIVITY_PERIOD);

        address[] memory page = rm.getRegisteredWallets(0, 2);
        assertEq(page.length, 2);

        address[] memory emptyPage = rm.getRegisteredWallets(5, 10);
        assertEq(emptyPage.length, 0);
    }

    /// SECTION 12. --- SECURITY — REENTRANCY ---
    function test_reentrancy_performUpkeep_blocked() public {
        ReentrantAttacker attacker = new ReentrantAttacker(address(rm));
        deal(address(attacker), 2 ether);

        address attackerBackup = makeAddr("attackerBackup");
        attacker.registerAsWallet{value: 1 ether}(INACTIVITY_PERIOD, attackerBackup);
        attacker.enableAttack(true);

        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);

        address[] memory victims = new address[](1);
        victims[0] = address(attacker);
        bytes memory performData = abi.encode(victims, uint256(0), false);

        rm.performUpkeep(performData);

        assertEq(rm.getRecoveryConfig(address(attacker)).balance, 0);
    }

    /// SECTION 13. --- SECURITY — REGISTRY INTEGRITY ---
    function test_registry_swapAndPop_maintainsIntegrity() public {
        _registerAlice();

        vm.prank(bob);
        rm.register{value: 1 ether}(bobBackup, INACTIVITY_PERIOD);

        vm.prank(carol);
        rm.register{value: 1 ether}(carolBackup, INACTIVITY_PERIOD);

        vm.prank(alice);
        rm.cancelRecovery();

        assertEq(rm.getTotalRegistered(), 2);
        assertTrue(rm.getRecoveryConfig(bob).isActive);
        assertTrue(rm.getRecoveryConfig(carol).isActive);
    }

    function test_registry_batchRemoval_swapSafety() public {
        address[3] memory users = [alice, bob, carol];
        address[3] memory backups = [aliceBackup, bobBackup, carolBackup];

        for (uint256 i = 0; i < 3; i++) {
            deal(users[i], 2 ether);
            vm.prank(users[i]);
            rm.register{value: 1 ether}(backups[i], INACTIVITY_PERIOD);
        }

        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);
        (, bytes memory performData) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(performData);

        assertEq(rm.getTotalRegistered(), 0);
    }

    /// SECTION 14. --- FUZZ TESTS ---
    function testFuzz_register_validInactivityPeriod(uint256 period) public {
        period = bound(period, INACTIVITY_PERIOD, rm.MAX_INACTIVITY_PERIOD());

        vm.prank(alice);
        rm.register{value: 1 ether}(aliceBackup, period);

        assertEq(rm.getRecoveryConfig(alice).inactivityPeriod, period);
    }

    function testFuzz_deposit_amount(uint128 amount) public {
        vm.assume(amount > 0 && amount <= 50 ether);
        deal(alice, uint256(amount) + 2 ether);
        _registerAlice();

        uint256 balanceBefore = rm.getRecoveryConfig(alice).balance;
        vm.prank(alice);
        rm.deposit{value: amount}();

        assertEq(rm.getRecoveryConfig(alice).balance, balanceBefore + amount);
    }

    function testFuzz_isRecoveryDue_timing(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, INACTIVITY_PERIOD * 2);
        _registerAlice();

        uint256 startTs = block.timestamp;
        vm.warp(startTs + elapsed);

        bool due = rm.isRecoveryDue(alice);
        if (elapsed >= INACTIVITY_PERIOD) {
            assertTrue(due);
        } else {
            assertFalse(due);
        }
    }

    /// SECTION 15. --- INVARIANT TESTS ---
    /**
     * @notice Contract ETH balance must always be ≥ sum of all user vault balances.
     * @dev    With no fee model, contract balance should equal the exact sum.
     *         A violation means user funds have been lost or stolen.
     */
    function invariant_contractBalanceCoverAllUserFunds() public view {
        uint256 total = rm.getTotalRegistered();
        address[] memory wallets = rm.getRegisteredWallets(0, total);

        uint256 sumOfUserBalances = 0;
        for (uint256 i = 0; i < wallets.length; i++) {
            sumOfUserBalances += rm.getRecoveryConfig(wallets[i]).balance;
        }

        assertGe(address(rm).balance, sumOfUserBalances, "Contract ETH insufficient to cover user balances");
    }

    /**
     * @notice Every wallet in the registry must have isActive == true.
     * @dev    Recovered or cancelled wallets must be removed via _removeFromRegistry.
     */
    function invariant_registeredWalletsAreAlwaysActive() public view {
        uint256 total = rm.getTotalRegistered();
        address[] memory wallets = rm.getRegisteredWallets(0, total);

        for (uint256 i = 0; i < wallets.length; i++) {
            assertTrue(rm.getRecoveryConfig(wallets[i]).isActive, "Inactive wallet found in registry");
        }
    }
}
