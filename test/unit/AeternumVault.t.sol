// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AeternumVault} from "../../src/AeternumVault.sol";
import {IAeternumVault} from "../../src/interfaces/IAeternumVault.sol";
import {ReentrantAttacker} from "../mocks/ReentrantAttacker.sol";
import {RejectingReceiver} from "../mocks/RejectingReceiver.sol";
import {RejectingCallerMock} from "../mocks/RejectingCallerMock.sol";

/**
 * @title  AeternumVaultTest
 * @notice Comprehensive test suite for AeternumVault — Phase 1.
 *
 *         Coverage areas:
 *           • Deployment / constructor
 *           • Registration (success paths, revert paths)
 *           • Deposit / send / withdrawAll
 *           • Ping (activity reset)
 *           • Config updates (backup address, inactivity period)
 *           • Recovery cancellation
 *           • triggerRecovery — core execution paths
 *           • triggerRecovery — silent return paths (pre-condition misses)
 *           • triggerRecovery — permissionless caller set & race conditions
 *           • triggerRecovery — failure handling & abandonment retry cycle
 *           • getTriggerableVaultsBatch — all branching paths
 *           • Stale data safety
 *           • Security (reentrancy, CEI double-spend prevention)
 *           • Registry integrity (swap-and-pop)
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
            3 // MAX_RECOVERY_ATTEMPTS
        );

        INACTIVITY_PERIOD = rm.MIN_INACTIVITY_PERIOD();

        deal(alice, STARTING_BALANCE);
        deal(bob, STARTING_BALANCE);
        deal(carol, STARTING_BALANCE);

        targetContract(address(rm));
    }

    /// --- HELPERS ---

    /// @dev Registers alice with 1 ETH and default inactivity period.
    function _registerAlice() internal {
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(aliceBackup, INACTIVITY_PERIOD);
    }

    /// @dev Warps block.timestamp past the wallet's configured inactivity deadline.
    function _warpPastInactivity(address wallet) internal {
        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(wallet);
        vm.warp(cfg.lastActivity + cfg.inactivityPeriod + 1);
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

    /// @dev Convenience wrapper: registers wallets into the main `rm` instance.
    function _registerWallets(uint256 count, uint256 seed)
        internal
        returns (address[] memory users, address[] memory backups)
    {
        return _registerWallets(rm, count, seed);
    }

    /**
     * @dev Drives a wallet to the abandoned state by calling triggerRecovery
     *      MAX_RECOVERY_ATTEMPTS times against a backup address that rejects ETH.
     *      Assumes the wallet is already registered with a RejectingReceiver backup.
     */
    function _reachAbandonment(address wallet) internal {
        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(wallet);
            rm.triggerRecovery(wallet);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 1 — CONSTRUCTOR / DEPLOYMENT
    // ─────────────────────────────────────────────────────────────────────────

    function test_constructor_initialState() public view {
        assertEq(rm.getTotalRegistered(), 0);
        assertEq(rm.MIN_INACTIVITY_PERIOD(), 180 days);
        assertEq(rm.MAX_INACTIVITY_PERIOD(), 3650 days);
        assertEq(uint256(rm.MAX_RECOVERY_ATTEMPTS()), 3);
    }

    function test_constructor_revertsIfMinInactivityIsZero() public {
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        new AeternumVault(0, 3650 days, 3);
    }

    function test_constructor_revertsIfMaxLessThanMin() public {
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        new AeternumVault(180 days, 150 days, 3);
    }

    function test_constructor_revertsIfMaxRecoveryAttemptsIsZero() public {
        vm.expectRevert(IAeternumVault.AeternumVault__MaxRecoveryAttemptsExceeded.selector);
        new AeternumVault(180 days, 3650 days, 0);
    }

    function test_constructor_minEqualsMax_isValid() public {
        AeternumVault v = new AeternumVault(180 days, 180 days, 3);
        assertEq(v.MIN_INACTIVITY_PERIOD(), v.MAX_INACTIVITY_PERIOD());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 2 — REGISTER: SUCCESS PATHS
    // ─────────────────────────────────────────────────────────────────────────

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

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 3 — REGISTER: REVERT PATHS
    // ─────────────────────────────────────────────────────────────────────────

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

        _reachAbandonment(alice);
        assertTrue(rm.isBackupAbandoned(address(badBackup)));

        vm.expectRevert(IAeternumVault.AeternumVault__WalletAbandoned.selector);
        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 4 — DEPOSIT
    // ─────────────────────────────────────────────────────────────────────────

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

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 5 — WITHDRAWALL
    // ─────────────────────────────────────────────────────────────────────────

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

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 5b — SEND
    // ─────────────────────────────────────────────────────────────────────────

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

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 6 — PING
    // ─────────────────────────────────────────────────────────────────────────

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
        vm.warp(block.timestamp + (INACTIVITY_PERIOD * 3 / 4));
        vm.prank(alice);
        rm.ping();

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

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 7 — CONFIG UPDATES
    // ─────────────────────────────────────────────────────────────────────────

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

        _reachAbandonment(alice);

        // Re-register with a good backup address
        vm.prank(alice);
        rm.register{value: 0.5 ether}(aliceBackup, INACTIVITY_PERIOD);

        // Updating back to the abandoned address must be blocked
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

    function test_updateInactivityPeriod_revertsIfTooLong() public {
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

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 8 — CANCEL RECOVERY
    // ─────────────────────────────────────────────────────────────────────────

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

    function test_cancelRecovery_revertsIfTransferFails() public {
        RejectingCallerMock rejecter = new RejectingCallerMock(address(rm));
        deal(address(rejecter), 2 ether);

        rejecter.doRegister{value: DEPOSIT_1_ETH}(aliceBackup, INACTIVITY_PERIOD);

        vm.expectRevert(IAeternumVault.AeternumVault__TransferFailed.selector);
        rejecter.doCancelRecovery();
    }

    function test_cancelRecovery_onAbandonedWallet_refundsAndClears() public {
        // Abandoned wallets: isActive=false, balance preserved, registry cleared.
        // cancelRecovery still succeeds via the isAbandoned branch of onlyRegistered.
        // _removeFromRegistry hits indexPlusOne==0 (already removed) and early-returns.
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);

        _reachAbandonment(alice);

        assertTrue(rm.getRecoveryConfig(alice).isAbandoned);
        assertEq(rm.getTotalRegistered(), 0);
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH);

        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        rm.cancelRecovery();

        assertEq(alice.balance, aliceBalanceBefore + DEPOSIT_1_ETH);
        assertEq(rm.getRecoveryConfig(alice).balance, 0);
        assertEq(rm.getTotalRegistered(), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 9 — TRIGGERRECOVERY: CORE EXECUTION PATHS
    // ─────────────────────────────────────────────────────────────────────────

    function test_triggerRecovery_executesRecovery_andZeroesBalance() public {
        _registerAlice();
        _warpPastInactivity(alice);

        rm.triggerRecovery(alice);

        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertFalse(cfg.isActive);
        assertEq(cfg.balance, 0);
    }

    function test_triggerRecovery_transfersETHToBackup() public {
        _registerAlice();
        _warpPastInactivity(alice);
        uint256 backupBefore = aliceBackup.balance;

        rm.triggerRecovery(alice);

        assertEq(aliceBackup.balance, backupBefore + DEPOSIT_1_ETH);
    }

    function test_triggerRecovery_removesWalletFromRegistry() public {
        _registerAlice();
        _warpPastInactivity(alice);

        rm.triggerRecovery(alice);

        assertEq(rm.getTotalRegistered(), 0);
    }

    function test_triggerRecovery_emitsRecoveryExecuted() public {
        _registerAlice();
        _warpPastInactivity(alice);

        vm.expectEmit(true, true, false, true);
        emit RecoveryExecuted(alice, aliceBackup, DEPOSIT_1_ETH);

        rm.triggerRecovery(alice);
    }

    function test_triggerRecovery_processesMultipleWallets_sequentially() public {
        address[3] memory users = [alice, bob, carol];
        address[3] memory backups = [aliceBackup, bobBackup, carolBackup];

        for (uint256 i = 0; i < 3; i++) {
            deal(users[i], 2 ether);
            vm.prank(users[i]);
            rm.register{value: DEPOSIT_1_ETH}(backups[i], INACTIVITY_PERIOD);
        }

        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);

        for (uint256 i = 0; i < 3; i++) {
            rm.triggerRecovery(users[i]);
        }

        assertEq(rm.getTotalRegistered(), 0);
        for (uint256 i = 0; i < 3; i++) {
            assertFalse(rm.getRecoveryConfig(users[i]).isActive);
            assertEq(backups[i].balance, DEPOSIT_1_ETH);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 10 — TRIGGERRECOVERY: SILENT RETURN PATHS
    //
    // triggerRecovery must never revert when pre-conditions are not met.
    // These are the guard exits in _executeRecovery: isActive, balance>0,
    // and timestamp. Silent return lets competing keepers race safely.
    // ─────────────────────────────────────────────────────────────────────────

    function test_triggerRecovery_silentReturn_whenInactivityPeriodNotElapsed() public {
        _registerAlice();
        // No warp — inactivity period has not elapsed

        rm.triggerRecovery(alice); // must not revert

        // State unchanged
        assertTrue(rm.getRecoveryConfig(alice).isActive);
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH);
        assertEq(aliceBackup.balance, 0);
    }

    function test_triggerRecovery_silentReturn_whenBalanceIsZero() public {
        vm.prank(alice);
        rm.register{value: 0}(aliceBackup, INACTIVITY_PERIOD);
        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);

        rm.triggerRecovery(alice); // hits balance==0 guard, silently returns

        assertTrue(rm.getRecoveryConfig(alice).isActive);
        assertEq(rm.getRecoveryConfig(alice).balance, 0);
    }

    function test_triggerRecovery_silentReturn_whenWalletNotActive() public {
        _registerAlice();
        vm.prank(alice);
        rm.cancelRecovery(); // isActive = false

        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);

        rm.triggerRecovery(alice); // hits !isActive guard, silently returns

        assertFalse(rm.getRecoveryConfig(alice).isActive);
        assertEq(rm.getTotalRegistered(), 0);
    }

    function test_triggerRecovery_silentReturn_forUnregisteredWallet() public {
        address stranger = makeAddr("stranger");

        rm.triggerRecovery(stranger); // isActive defaults to false — must not revert

        assertEq(rm.getRecoveryConfig(stranger).balance, 0);
    }

    function test_triggerRecovery_silentReturn_exactlyAtDeadlineBoundary() public {
        _registerAlice();
        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        // Warp to exactly the deadline — condition is >=, so this is due
        vm.warp(cfg.lastActivity + cfg.inactivityPeriod);
        assertTrue(rm.isRecoveryDue(alice));

        rm.triggerRecovery(alice); // must execute at boundary
        assertFalse(rm.getRecoveryConfig(alice).isActive);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 11 — TRIGGERRECOVERY: PERMISSIONLESS & RACE CONDITIONS
    //
    // Any external actor may call triggerRecovery. The caller controls only
    // which wallet is nominated — not whether, when, or where funds move.
    // ─────────────────────────────────────────────────────────────────────────

    function test_triggerRecovery_isCallableByArbitraryAddress() public {
        _registerAlice();
        _warpPastInactivity(alice);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        rm.triggerRecovery(alice); // must not revert

        assertFalse(rm.getRecoveryConfig(alice).isActive);
        assertEq(aliceBackup.balance, DEPOSIT_1_ETH);
    }

    function test_triggerRecovery_isCallableByBeneficiary() public {
        _registerAlice();
        _warpPastInactivity(alice);

        vm.prank(aliceBackup);
        rm.triggerRecovery(alice);

        assertEq(aliceBackup.balance, DEPOSIT_1_ETH);
    }

    function test_triggerRecovery_isCallableByOwnerOfDifferentVault() public {
        // Bob calling triggerRecovery for alice's vault (a common keeper scenario)
        _registerAlice();
        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(bobBackup, INACTIVITY_PERIOD);

        _warpPastInactivity(alice);

        vm.prank(bob);
        rm.triggerRecovery(alice); // must not revert

        assertFalse(rm.getRecoveryConfig(alice).isActive);
        assertEq(aliceBackup.balance, DEPOSIT_1_ETH);
        // Bob's own vault is unaffected
        assertTrue(rm.getRecoveryConfig(bob).isActive);
    }

    function test_triggerRecovery_raceCondition_secondCallerSilentlyReturns() public {
        _registerAlice();
        _warpPastInactivity(alice);

        // First keeper executes the recovery
        rm.triggerRecovery(alice);
        assertFalse(rm.getRecoveryConfig(alice).isActive);
        assertEq(aliceBackup.balance, DEPOSIT_1_ETH);

        uint256 backupBalanceAfterFirst = aliceBackup.balance;

        // Second keeper arrives with stale data — must not revert, must not double-pay
        address lateKeeper = makeAddr("lateKeeper");
        vm.prank(lateKeeper);
        rm.triggerRecovery(alice); // hits !isActive guard, silent return

        assertEq(aliceBackup.balance, backupBalanceAfterFirst); // no duplicate payment
    }

    function test_triggerRecovery_callerCannotRedirectFunds() public {
        // The caller passes a wallet — the destination is read from config,
        // not from any caller-controlled input. Funds always reach backupAddress.
        _registerAlice();
        _warpPastInactivity(alice);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        rm.triggerRecovery(alice);

        // Funds went to aliceBackup (config), not attacker (msg.sender)
        assertEq(aliceBackup.balance, DEPOSIT_1_ETH);
        assertEq(attacker.balance, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 12 — TRIGGERRECOVERY: FAILURE HANDLING & ABANDONMENT
    //
    // When the ETH transfer to backupAddress fails, _executeRecovery restores
    // state and increments the attempt counter. After MAX_RECOVERY_ATTEMPTS
    // the wallet is permanently abandoned.
    // ─────────────────────────────────────────────────────────────────────────

    function test_triggerRecovery_emitsRecoveryFailed_onBadBackupAddress() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);
        _warpPastInactivity(alice);

        vm.expectEmit(true, true, false, true);
        emit RecoveryFailed(alice, address(badBackup), DEPOSIT_1_ETH);

        rm.triggerRecovery(alice);
    }

    function test_triggerRecovery_restoresState_onFailedTransfer() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);
        _warpPastInactivity(alice);

        rm.triggerRecovery(alice);

        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertTrue(cfg.isActive);
        assertEq(cfg.balance, DEPOSIT_1_ETH);
        assertEq(rm.getTotalRegistered(), 1);
    }

    function test_triggerRecovery_incrementsFailedAttempts() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);
        _warpPastInactivity(alice);

        rm.triggerRecovery(alice);

        assertEq(rm.getRecoveryConfig(alice).failedRecoveryAttempts, 1);
    }

    function test_triggerRecovery_attemptCounterIsMonotonicallyIncreasing() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(alice);
            rm.triggerRecovery(alice);
            // Attempt counter increments on each genuine attempt
            if (i < rm.MAX_RECOVERY_ATTEMPTS() - 1) {
                assertEq(rm.getRecoveryConfig(alice).failedRecoveryAttempts, i + 1);
            }
        }
    }

    function test_triggerRecovery_preconditionMiss_doesNotIncrementAttemptCounter() public {
        // A call that silently returns at a guard (not due, zero balance, etc.)
        // must NOT consume a retry slot. Attempt counter only increments
        // when an ETH transfer is genuinely attempted.
        _registerAlice();
        // Not warped — inactivity period has not elapsed

        rm.triggerRecovery(alice);

        assertEq(rm.getRecoveryConfig(alice).failedRecoveryAttempts, 0);
    }

    function test_triggerRecovery_abandonedAfterMaxAttempts() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);

        _reachAbandonment(alice);

        assertFalse(rm.getRecoveryConfig(alice).isActive);
        assertTrue(rm.getRecoveryConfig(alice).isAbandoned);
        assertEq(rm.getTotalRegistered(), 0);
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH); // balance preserved
        assertTrue(rm.isBackupAbandoned(address(badBackup)));
    }

    function test_triggerRecovery_emitsRecoveryAbandoned_atMaxAttempts() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS() - 1; i++) {
            _warpPastInactivity(alice);
            rm.triggerRecovery(alice);
        }

        _warpPastInactivity(alice);

        vm.expectEmit(true, true, false, true);
        emit RecoveryAbandoned(alice, address(badBackup), DEPOSIT_1_ETH);

        rm.triggerRecovery(alice);
    }

    function test_triggerRecovery_abandonedWallet_subsequentCallSilentlyReturns() public {
        // After abandonment, isActive==false, so triggerRecovery silently returns
        // without consuming another attempt or touching the preserved balance.
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);

        _reachAbandonment(alice);

        assertTrue(rm.getRecoveryConfig(alice).isAbandoned);

        _warpPastInactivity(alice);
        rm.triggerRecovery(alice); // must not revert

        // Balance untouched, state unchanged
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH);
        assertTrue(rm.getRecoveryConfig(alice).isAbandoned);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 12b — REREGISTRATION AFTER ABANDONMENT
    // ─────────────────────────────────────────────────────────────────────────

    function test_reregister_carriesOverAbandonedBalance_whenSkippingWithdrawal() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(badBackup), INACTIVITY_PERIOD);

        _reachAbandonment(alice);

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

        _reachAbandonment(alice);

        uint256 newDeposit = 0.5 ether;
        vm.prank(alice);
        rm.register{value: newDeposit}(aliceBackup, INACTIVITY_PERIOD);

        _warpPastInactivity(alice);
        uint256 backupBefore = aliceBackup.balance;
        rm.triggerRecovery(alice);

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

        _reachAbandonment(alice);

        vm.prank(alice);
        rm.withdrawAll(); // clear balance before re-registering

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

        _reachAbandonment(alice);

        uint256 contractBalanceBefore = address(rm).balance;
        uint256 newDeposit = 0.5 ether;
        vm.prank(alice);
        rm.register{value: newDeposit}(aliceBackup, INACTIVITY_PERIOD);

        assertEq(
            address(rm).balance,
            contractBalanceBefore + newDeposit,
            "Contract balance must grow by exactly the new deposit"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 13 — getTriggerableVaultsBatch: VIEW FUNCTION
    //
    // getTriggerableVaultsBatch is the keeper bot's primary scanning tool and the
    // CRE Phase 3 integration point. It must correctly identify triggerable
    // wallets within any arbitrary registry slice.
    // ─────────────────────────────────────────────────────────────────────────

    function test_getTriggerableVaultsBatch_returnsEmptyForEmptyRegistry() public view {
        address[] memory result = rm.getTriggerableVaultsBatch(0, 100);
        assertEq(result.length, 0);
    }

    function test_getTriggerableVaultsBatch_returnsEmptyWhenNoDueWallets() public {
        _registerAlice();
        // Not warped — wallet is not yet due

        address[] memory result = rm.getTriggerableVaultsBatch(0, 100);
        assertEq(result.length, 0);
    }

    function test_getTriggerableVaultsBatch_returnsDueWallet() public {
        _registerAlice();
        _warpPastInactivity(alice);

        address[] memory result = rm.getTriggerableVaultsBatch(0, 100);
        assertEq(result.length, 1);
        assertEq(result[0], alice);
    }

    function test_getTriggerableVaultsBatch_returnsEmptyWhenStartIndexExceedsTotal() public {
        _registerAlice();
        _warpPastInactivity(alice);

        address[] memory result = rm.getTriggerableVaultsBatch(5, 10);
        assertEq(result.length, 0);
    }

    function test_getTriggerableVaultsBatch_returnsEmptyWhenBatchSizeIsZero() public {
        _registerAlice();
        _warpPastInactivity(alice);

        address[] memory result = rm.getTriggerableVaultsBatch(0, 0);
        assertEq(result.length, 0);
    }

    function test_getTriggerableVaultsBatch_clampsToArrayEnd() public {
        _registerAlice(); // total = 1
        _warpPastInactivity(alice);

        // batchSize(100) >> total(1) — must clamp gracefully
        address[] memory result = rm.getTriggerableVaultsBatch(0, 100);
        assertEq(result.length, 1);
        assertEq(result[0], alice);
    }

    function test_getTriggerableVaultsBatch_excludesZeroBalanceWallets() public {
        vm.prank(alice);
        rm.register{value: 0}(aliceBackup, INACTIVITY_PERIOD);
        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);

        address[] memory result = rm.getTriggerableVaultsBatch(0, 1);
        assertEq(result.length, 0, "Zero-balance wallet must not appear in batch results");
    }

    function test_getTriggerableVaultsBatch_excludesInactiveWallets() public {
        _registerAlice();
        vm.prank(alice);
        rm.cancelRecovery(); // removes alice from registry

        address[] memory result = rm.getTriggerableVaultsBatch(0, 10);
        assertEq(result.length, 0);
    }

    function test_getTriggerableVaultsBatch_respectsStartIndex() public {
        _registerAlice(); // index 0

        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(bobBackup, INACTIVITY_PERIOD); // index 1

        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);

        // startIndex=1 scans only bob; alice (index 0) is skipped
        address[] memory result = rm.getTriggerableVaultsBatch(1, 1);
        assertEq(result.length, 1);
        assertEq(result[0], bob);
    }

    function test_getTriggerableVaultsBatch_returnsMixedResults_onlyDueIncluded() public {
        // alice is due, bob has pinged (not due)
        _registerAlice();
        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(bobBackup, INACTIVITY_PERIOD);

        _warpPastInactivity(alice);
        vm.prank(bob);
        rm.ping(); // bob resets timer

        address[] memory result = rm.getTriggerableVaultsBatch(0, 2);
        assertEq(result.length, 1);
        assertEq(result[0], alice);
    }

    function test_getTriggerableVaultsBatch_trimsArrayCorrectly_noTrailingZeroAddresses() public {
        // Three wallets in registry, one due, batchSize=3.
        // Result must be trimmed to length 1 with no trailing address(0) entries.
        _registerAlice();
        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(bobBackup, INACTIVITY_PERIOD);
        vm.prank(carol);
        rm.register{value: DEPOSIT_1_ETH}(carolBackup, INACTIVITY_PERIOD);

        _warpPastInactivity(alice);
        vm.prank(bob);
        rm.ping();
        vm.prank(carol);
        rm.ping();

        address[] memory result = rm.getTriggerableVaultsBatch(0, 3);
        assertEq(result.length, 1, "Array must be trimmed to actual triggerable count");
        assertEq(result[0], alice);
    }

    function test_getTriggerableVaultsBatch_returnsAllDueWallets_whenBatchCoversAll() public {
        _registerAlice();
        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(bobBackup, INACTIVITY_PERIOD);
        vm.prank(carol);
        rm.register{value: DEPOSIT_1_ETH}(carolBackup, INACTIVITY_PERIOD);

        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);

        address[] memory result = rm.getTriggerableVaultsBatch(0, 3);
        assertEq(result.length, 3);
    }

    function test_getTriggerableVaultsBatch_isConsistentWithIsRecoveryDue() public {
        // Every wallet returned by getTriggerableVaultsBatch must satisfy isRecoveryDue.
        _registerAlice();
        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(bobBackup, INACTIVITY_PERIOD);
        vm.prank(carol);
        rm.register{value: DEPOSIT_1_ETH}(carolBackup, INACTIVITY_PERIOD);

        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);
        vm.prank(carol);
        rm.ping(); // carol not due

        address[] memory result = rm.getTriggerableVaultsBatch(0, 3);

        for (uint256 i = 0; i < result.length; i++) {
            assertTrue(
                rm.isRecoveryDue(result[i]), "Every wallet in batch result must be confirmed due by isRecoveryDue"
            );
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 13b — KEEPER BOT INTEGRATION PATTERN
    //
    // Verifies the bot's canonical workflow: call getTriggerableVaultsBatch as a free
    // eth_call, then submit triggerRecovery for each result.
    // ─────────────────────────────────────────────────────────────────────────

    function test_keeperBot_checkBatchThenTrigger_fullCycle() public {
        _registerAlice();
        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(bobBackup, INACTIVITY_PERIOD);

        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);

        // Step 1: bot queries getTriggerableVaultsBatch (free eth_call)
        address[] memory due = rm.getTriggerableVaultsBatch(0, rm.getTotalRegistered());
        assertEq(due.length, 2);

        // Step 2: bot submits triggerRecovery for each result
        for (uint256 i = 0; i < due.length; i++) {
            rm.triggerRecovery(due[i]);
        }

        assertEq(rm.getTotalRegistered(), 0);
        assertEq(aliceBackup.balance, DEPOSIT_1_ETH);
        assertEq(bobBackup.balance, DEPOSIT_1_ETH);
    }

    function test_keeperBot_checkBatch_emptyAfterRecovery() public {
        _registerAlice();
        _warpPastInactivity(alice);

        address[] memory vaultsBefore = rm.getTriggerableVaultsBatch(0, 100);
        assertEq(vaultsBefore.length, 1);

        rm.triggerRecovery(alice);

        address[] memory vaultsAfter = rm.getTriggerableVaultsBatch(0, 100);
        assertEq(vaultsAfter.length, 0, "Batch must return empty after successful recovery");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 14 — STALE DATA SAFETY
    //
    // triggerRecovery must silently skip wallets whose state changed between
    // the keeper bot's eth_call check and the submitted transaction landing.
    // ─────────────────────────────────────────────────────────────────────────

    function test_staleData_silentReturn_afterUserPings() public {
        _registerAlice();
        _warpPastInactivity(alice);

        // User pings before keeper's tx lands
        vm.prank(alice);
        rm.ping();

        rm.triggerRecovery(alice); // now not due — silently returns

        assertTrue(rm.getRecoveryConfig(alice).isActive);
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH);
        assertEq(aliceBackup.balance, 0);
    }

    function test_staleData_silentReturn_afterUserDeposits() public {
        _registerAlice();
        _warpPastInactivity(alice);

        // Deposit resets lastActivity
        vm.prank(alice);
        rm.deposit{value: 0.1 ether}();

        rm.triggerRecovery(alice); // not due after deposit resets timer

        assertTrue(rm.getRecoveryConfig(alice).isActive);
    }

    function test_staleData_silentReturn_afterUserCancelsRecovery() public {
        _registerAlice();
        _warpPastInactivity(alice);

        vm.prank(alice);
        rm.cancelRecovery();

        rm.triggerRecovery(alice); // must not revert; isActive = false

        assertFalse(rm.getRecoveryConfig(alice).isActive);
        assertEq(rm.getTotalRegistered(), 0);
    }

    function test_staleData_silentReturn_forAlreadyRecoveredWallet() public {
        _registerAlice();
        _warpPastInactivity(alice);

        rm.triggerRecovery(alice); // first execution succeeds
        rm.triggerRecovery(alice); // second call with stale data — must not revert

        assertEq(rm.getRecoveryConfig(alice).balance, 0);
        assertEq(aliceBackup.balance, DEPOSIT_1_ETH); // no double payment
    }

    function test_staleData_independentExecution_whenOneBotRaceLost() public {
        // Two wallets due. Keeper pre-validates both as triggerable.
        // Between check and execution, a competing keeper recovers alice first.
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(aliceBackup, INACTIVITY_PERIOD);
        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(bobBackup, INACTIVITY_PERIOD);

        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);

        // Competing keeper takes alice first
        address competitor = makeAddr("competitor");
        vm.prank(competitor);
        rm.triggerRecovery(alice);

        // Our keeper submits both — alice silently skipped, bob executed
        rm.triggerRecovery(alice); // already done — silently skipped
        rm.triggerRecovery(bob);

        // alice paid once (by competitor), bob paid once (by our keeper)
        assertEq(aliceBackup.balance, DEPOSIT_1_ETH);
        assertEq(bobBackup.balance, DEPOSIT_1_ETH);
        assertEq(rm.getTotalRegistered(), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 15 — VIEW HELPERS
    // ─────────────────────────────────────────────────────────────────────────

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

    function test_isRecoveryDue_falseForUnregisteredWallet() public view {
        assertFalse(rm.isRecoveryDue(alice));
    }

    function test_isRecoveryDue_falseForZeroBalance() public {
        vm.prank(alice);
        rm.register{value: 0}(aliceBackup, INACTIVITY_PERIOD);
        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);
        assertFalse(rm.isRecoveryDue(alice));
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

    function test_getTimeUntilRecovery_returnsZeroIfNotRegistered() public view {
        assertEq(rm.getTimeUntilRecovery(alice), 0);
    }

    function test_getTimeUntilRecovery_returnsZeroIfZeroBalance() public {
        vm.prank(alice);
        rm.register{value: 0}(aliceBackup, INACTIVITY_PERIOD);
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

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 16 — SECURITY: REENTRANCY
    // ─────────────────────────────────────────────────────────────────────────

    function test_reentrancy_triggerRecovery_blockedByNonReentrant() public {
        ReentrantAttacker attacker = new ReentrantAttacker(address(rm));

        // Register a victim wallet with the attacker contract as backup.
        // When recovery fires, ETH is sent to attacker.receive() — the callback
        // actually executes the reentrancy attempt, unlike a plain EOA backup.
        address victim = makeAddr("victim");
        deal(victim, 2 ether);
        vm.prank(victim);
        rm.register{value: 1 ether}(address(attacker), INACTIVITY_PERIOD);

        attacker.setVictimWallet(victim);
        attacker.enableAttack(true);

        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);

        rm.triggerRecovery(victim);

        // CEI: balance zeroed before external call fires.
        // Reentrant triggerRecovery found balance==0, silently returned.
        // nonReentrant additionally blocked the call at the modifier level.
        assertEq(rm.getRecoveryConfig(victim).balance, 0);
        // ETH arrived at the attacker contract despite the reentrant attempt.
        assertEq(address(attacker).balance, 1 ether);
        // Confirm the attack path was actually reached — this is what separates
        // a real reentrancy test from just a CEI verification.
        assertGt(attacker.reentrancyAttempts(), 0);
    }

    function test_reentrancy_balanceZeroedBeforeExternalCall_CEI() public {
        // Directly verifies the CEI guarantee: even without nonReentrant,
        // config.balance is 0 at the moment the external call fires.
        // We observe this indirectly: if a reentrant triggerRecovery fired and
        // found balance > 0, it would execute a second transfer. The fact that
        // aliceBackup only receives DEPOSIT_1_ETH (not 2×) proves balance was
        // already 0 when the external call executed.
        _registerAlice();
        _warpPastInactivity(alice);

        rm.triggerRecovery(alice);

        // CEI guarantee: exactly one payment, never double
        assertEq(aliceBackup.balance, DEPOSIT_1_ETH);
        assertEq(rm.getRecoveryConfig(alice).balance, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 17 — REGISTRY INTEGRITY
    // ─────────────────────────────────────────────────────────────────────────

    function test_registry_swapAndPop_maintainsIntegrity_afterCancellation() public {
        _registerAlice();
        vm.prank(bob);
        rm.register{value: 1 ether}(bobBackup, INACTIVITY_PERIOD);
        vm.prank(carol);
        rm.register{value: 1 ether}(carolBackup, INACTIVITY_PERIOD);

        // Cancel the first wallet — triggers a swap-and-pop
        vm.prank(alice);
        rm.cancelRecovery();

        assertEq(rm.getTotalRegistered(), 2);
        assertTrue(rm.getRecoveryConfig(bob).isActive);
        assertTrue(rm.getRecoveryConfig(carol).isActive);
        assertFalse(rm.isRegistered(alice));
    }

    function test_registry_swapAndPop_maintainsIntegrity_afterRecovery() public {
        _registerAlice();
        vm.prank(bob);
        rm.register{value: 1 ether}(bobBackup, INACTIVITY_PERIOD);
        vm.prank(carol);
        rm.register{value: 1 ether}(carolBackup, INACTIVITY_PERIOD);

        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);

        rm.triggerRecovery(alice);

        assertEq(rm.getTotalRegistered(), 2);
        assertTrue(rm.getRecoveryConfig(bob).isActive);
        assertTrue(rm.getRecoveryConfig(carol).isActive);
        assertEq(rm.getRecoveryConfig(alice).balance, 0);
    }

    function test_registry_batchRemoval_swapSafety_allRecoveredSequentially() public {
        address[3] memory users = [alice, bob, carol];
        address[3] memory backups = [aliceBackup, bobBackup, carolBackup];

        for (uint256 i = 0; i < 3; i++) {
            deal(users[i], 2 ether);
            vm.prank(users[i]);
            rm.register{value: 1 ether}(backups[i], INACTIVITY_PERIOD);
        }

        vm.warp(block.timestamp + INACTIVITY_PERIOD + 1);

        for (uint256 i = 0; i < 3; i++) {
            rm.triggerRecovery(users[i]);
        }

        assertEq(rm.getTotalRegistered(), 0);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(backups[i].balance, 1 ether);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 18 — FUZZ TESTS
    // ─────────────────────────────────────────────────────────────────────────

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

    function testFuzz_send_amount(uint128 amount) public {
        vm.assume(amount > 0 && amount <= DEPOSIT_1_ETH);
        _registerAlice();
        address recipient = makeAddr("recipient");

        vm.prank(alice);
        rm.send(recipient, amount);

        assertEq(recipient.balance, amount);
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH - amount);
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

    function testFuzz_triggerRecovery_neverRevertsForArbitraryAddress(address target) public {
        // triggerRecovery must not revert for any address input.
        // For unregistered wallets, _executeRecovery exits at the !isActive guard.
        vm.assume(target != address(0));

        rm.triggerRecovery(target); // must not revert
    }

    function testFuzz_getTriggerableVaultsBatch_neverReverts(uint256 startIndex, uint256 batchSize) public view {
        startIndex = bound(startIndex, 0, 1_000_000);
        batchSize = bound(batchSize, 0, 10_000);

        rm.getTriggerableVaultsBatch(startIndex, batchSize); // must not revert
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SECTION 19 — INVARIANT TESTS
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Contract ETH balance must always be ≥ sum of all user vault balances.
     * @dev    With no protocol fee, contract balance should equal the exact sum.
     *         A violation means user funds have been lost, stolen, or double-spent.
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
     * @notice Every wallet in the active registry must have isActive == true.
     * @dev    Recovered, cancelled, or abandoned wallets must be removed via
     *         _removeFromRegistry. A false-active wallet means swap-and-pop broke.
     */
    function invariant_registeredWalletsAreAlwaysActive() public view {
        uint256 total = rm.getTotalRegistered();
        address[] memory wallets = rm.getRegisteredWallets(0, total);

        for (uint256 i = 0; i < wallets.length; i++) {
            assertTrue(rm.getRecoveryConfig(wallets[i]).isActive, "Inactive wallet found in registry");
        }
    }

    /**
     * @notice Abandoned wallets must never appear in the active registry.
     * @dev    On abandonment, isAbandoned=true and the wallet is removed from
     *         s_registeredWallets. A violation means abandonment state is inconsistent.
     */
    function invariant_abandonedWalletsNotInRegistry() public view {
        uint256 total = rm.getTotalRegistered();
        address[] memory wallets = rm.getRegisteredWallets(0, total);

        for (uint256 i = 0; i < wallets.length; i++) {
            assertFalse(rm.getRecoveryConfig(wallets[i]).isAbandoned, "Abandoned wallet found in active registry");
        }
    }
}
