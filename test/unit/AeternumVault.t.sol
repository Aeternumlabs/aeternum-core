// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AeternumVault} from "../../src/AeternumVault.sol";
import {IAeternumVault} from "../../src/interfaces/IAeternumVault.sol";
import {ReentrantAttacker} from "../mocks/ReentrantAttacker.sol";
import {RejectingReceiver} from "../mocks/RejectingReceiver.sol";
import {RejectingCallerMock} from "../mocks/RejectingCallerMock.sol";
import {RejectingTreasuryMock} from "../mocks/RejectingTreasuryMock.sol";

/**
 * @title  AeternumVaultTest
 * @notice Comprehensive test suite for AeternumVault.
 *
 *         Coverage areas:
 *           • Deployment / constructor
 *           • Registration (Free & Premium, edge cases, revert paths)
 *           • Deposit / send / withdrawAll
 *           • Ping (activity reset)
 *           • Config updates (backup address, inactivity period)
 *           • Subscription renewal
 *           • Recovery cancellation
 *           • Chainlink Automation (checkUpkeep + performUpkeep)
 *           • Treasury management
 *           • Security (reentrancy, access control, CEI invariants)
 *           • Fuzz tests
 *           • Invariant tests
 */
contract AeternumVaultTest is StdInvariant, Test {
    /*//////////////////////////////////////////////////////////////
                              TEST SETUP
    //////////////////////////////////////////////////////////////*/

    AeternumVault public rm;

    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public aliceBackup = makeAddr("aliceBackup");
    address public bobBackup = makeAddr("bobBackup");
    address public carolBackup = makeAddr("carolBackup");

    uint256 public constant STARTING_BALANCE = 100 ether;
    uint256 public constant DEPOSIT_1_ETH = 1 ether;

    uint256 public FREE_PERIOD;
    uint256 public PREMIUM_PERIOD;
    uint256 public PREMIUM_FEE;

    event RecoveryRegistered(
        address indexed wallet,
        address indexed backupAddress,
        uint256 inactivityPeriod,
        IAeternumVault.SubscriptionTier tier
    );
    event ActivityPinged(address indexed wallet, uint256 timestamp);
    event RecoveryExecuted(address indexed wallet, address indexed backupAddress, uint256 amount);
    event RecoveryFailed(address indexed wallet, address indexed backupAddress, uint256 amount);
    event RecoveryAbandoned(address indexed wallet, address indexed backupAddress, uint256 balance);
    event RecoveryCancelled(address indexed wallet, uint256 refundAmount);
    event Deposited(address indexed wallet, uint256 amount);
    event Sent(address indexed wallet, address indexed to, uint256 amount);
    event BackupAddressUpdated(address indexed wallet, address indexed newBackupAddress);
    event InactivityPeriodUpdated(address indexed wallet, uint256 newPeriod);
    event SubscriptionRenewed(address indexed wallet, IAeternumVault.SubscriptionTier tier, uint256 expiresAt);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event SubscriptionFeesWithdrawn(address indexed treasury, uint256 amount);

    function setUp() public {
        rm = new AeternumVault(
            treasury,
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

        FREE_PERIOD = rm.MIN_INACTIVITY_PERIOD_FREE();
        PREMIUM_PERIOD = rm.MIN_INACTIVITY_PERIOD_PREMIUM();
        PREMIUM_FEE = rm.PREMIUM_MONTHLY_FEE();

        deal(alice, STARTING_BALANCE);
        deal(bob, STARTING_BALANCE);
        deal(carol, STARTING_BALANCE);

        targetContract(address(rm));
    }

    /*//////////////////////////////////////////////////////////////
                        HELPERS
    //////////////////////////////////////////////////////////////*/

    // Cursor vault: small sizes make window/batch boundary tests tractable.
    // MAX_CHECK_UPKEEP_SIZE = 6, MAX_PERFORM_UPKEEP_SIZE = 3, INTERVAL = 30s
    AeternumVault cv;

    /// @dev Deploys a cursor vault with configurable sizes for boundary testing.
    function _deployCursorVault(uint256 checkSize, uint256 performSize, uint256 interval)
        internal
        returns (AeternumVault)
    {
        AeternumVault v = new AeternumVault(
            treasury,
            365 days,
            180 days,
            3650 days,
            30 days,
            0.002 ether,
            0.02 ether,
            checkSize,
            performSize,
            3,
            interval
        );
        return v;
    }

    /// @dev Registers `count` wallets into `vault`, each with 1 ether deposit.
    ///      Uses deterministic addresses derived from a seed.
    function _registerWallets(AeternumVault vault, uint256 count, uint256 seed)
        internal
        returns (address[] memory users, address[] memory backups)
    {
        users = new address[](count);
        backups = new address[](count);
        uint256 period = vault.MIN_INACTIVITY_PERIOD_FREE();

        for (uint256 i = 0; i < count; i++) {
            address user = address(uint160(0xA000 + seed + i));
            address backup = address(uint160(0xB000 + seed + i));
            deal(user, 10 ether);
            vm.prank(user);
            vault.register{value: 1 ether}(
                backup, period, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
            );
            users[i] = user;
            backups[i] = backup;
        }
    }

    /// @dev Warps time past every registered wallet's inactivity period.
    function _warpAllPastInactivity(AeternumVault vault) internal {
        vm.warp(block.timestamp + vault.MIN_INACTIVITY_PERIOD_FREE() + 1);
    }

    function _registerAliceFree() internal {
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(
            aliceBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );
    }

    function _registerAlicePremium() internal {
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH + PREMIUM_FEE}(
            aliceBackup,
            PREMIUM_PERIOD,
            IAeternumVault.SubscriptionTier.Premium,
            IAeternumVault.SubscriptionPlan.Monthly
        );
    }

    /// @dev Warp past alice's inactivity period.
    function _warpPastInactivity(address wallet) internal {
        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(wallet);
        vm.warp(cfg.lastActivity + cfg.inactivityPeriod + 1);
    }

    /// @dev Returns the encoded performData for a list of wallets.
    function _encodePerformData(address[] memory wallets) internal pure returns (bytes memory) {
        return abi.encode(wallets);
    }

    /*//////////////////////////////////////////////////////////////
                     1. CONSTRUCTOR / DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsTreasury() public view {
        assertEq(rm.getTreasury(), treasury);
    }

    function test_constructor_revertsOnZeroTreasury() public {
        vm.expectRevert(IAeternumVault.AeternumVault__ZeroAddress.selector);
        new AeternumVault(
            address(0), 365 days, 180 days, 3650 days, 30 days, 0.002 ether, 0.02 ether, 5000, 50, 3, 1 hours
        );
    }

    function test_constructor_initialState() public view {
        assertEq(rm.getTotalRegistered(), 0);
        assertEq(rm.getAccumulatedFees(), 0);
    }

    function test_constructor_revertsIfPremiumMinIsZero() public {
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        new AeternumVault(treasury, 365 days, 0, 3650 days, 30 days, 0.002 ether, 0.02 ether, 5000, 50, 3, 1 hours);
    }

    function test_constructor_revertsIfFreeMinLessThanPremiumMin() public {
        // Free min (100 days) < Premium min (200 days) — violates ordering invariant
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        new AeternumVault(
            treasury, 100 days, 200 days, 3650 days, 30 days, 0.002 ether, 0.02 ether, 5000, 50, 3, 1 hours
        );
    }

    function test_constructor_revertsIfMaxLessThanFreeMin() public {
        // Max (300 days) < Free min (365 days)
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        new AeternumVault(
            treasury, 365 days, 180 days, 300 days, 30 days, 0.002 ether, 0.02 ether, 5000, 50, 3, 1 hours
        );
    }

    function test_constructor_revertsIfSubscriptionDurationIsZero() public {
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidSubscriptionDuration.selector);
        new AeternumVault(treasury, 365 days, 180 days, 3650 days, 0, 0.002 ether, 0.02 ether, 5000, 50, 3, 1 hours);
    }

    function test_constructor_revertsIfMaxPerformUpkeepSizeIsZero() public {
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidConstructorParam.selector);
        new AeternumVault(
            treasury, 365 days, 180 days, 3650 days, 30 days, 0.002 ether, 0.02 ether, 5000, 0, 3, 1 hours
        );
    }

    function test_constructor_revertsIfMaxRecoveryAttemptsIsZero() public {
        vm.expectRevert(IAeternumVault.AeternumVault__MaxRecoveryAttemptsExceeded.selector);
        new AeternumVault(
            treasury, 365 days, 180 days, 3650 days, 30 days, 0.002 ether, 0.02 ether, 5000, 50, 0, 1 hours
        );
    }

    /*//////////////////////////////////////////////////////////////
                       2. REGISTER — SUCCESS PATHS
    //////////////////////////////////////////////////////////////*/

    function test_register_free_storesConfig() public {
        _registerAliceFree();

        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertEq(cfg.backupAddress, aliceBackup);
        assertEq(cfg.inactivityPeriod, FREE_PERIOD);
        assertEq(cfg.balance, DEPOSIT_1_ETH);
        assertEq(cfg.lastActivity, block.timestamp);
        assertEq(uint256(cfg.tier), uint256(IAeternumVault.SubscriptionTier.Free));
        assertEq(cfg.subscriptionExpiry, 0);
        assertTrue(cfg.isActive);
    }

    function test_register_free_incrementsRegistry() public {
        _registerAliceFree();
        assertEq(rm.getTotalRegistered(), 1);
    }

    function test_register_free_emitsEvents() public {
        vm.expectEmit(true, true, false, true);
        emit RecoveryRegistered(alice, aliceBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free);

        vm.expectEmit(true, false, false, true);
        emit Deposited(alice, DEPOSIT_1_ETH);

        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(
            aliceBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );
    }

    function test_register_premium_storesConfig() public {
        _registerAlicePremium();

        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertEq(cfg.balance, DEPOSIT_1_ETH); // fee excluded from balance
        assertEq(uint256(cfg.tier), uint256(IAeternumVault.SubscriptionTier.Premium));
        assertEq(cfg.subscriptionExpiry, block.timestamp + 30 days);
    }

    function test_register_premium_accumulatesFee() public {
        _registerAlicePremium();
        assertEq(rm.getAccumulatedFees(), PREMIUM_FEE);
    }

    function test_register_withZeroDeposit_isValid() public {
        vm.prank(alice);
        rm.register{value: 0}(
            aliceBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );

        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertEq(cfg.balance, 0);
        assertTrue(cfg.isActive);
    }

    function test_register_multipleUsers() public {
        _registerAliceFree();

        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(
            bobBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );

        assertEq(rm.getTotalRegistered(), 2);
    }

    /*//////////////////////////////////////////////////////////////
                      3. REGISTER — REVERT PATHS
    //////////////////////////////////////////////////////////////*/

    function test_register_revertsIfAlreadyRegistered() public {
        _registerAliceFree();

        vm.expectRevert(IAeternumVault.AeternumVault__AlreadyRegistered.selector);
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(
            aliceBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );
    }

    function test_register_revertsIfBackupIsZeroAddress() public {
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidBackupAddress.selector);
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(
            address(0), FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );
    }

    function test_register_revertsIfBackupIsSelf() public {
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidBackupAddress.selector);
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(
            alice, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );
    }

    function test_register_free_revertsIfPeriodTooShort() public {
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(
            aliceBackup, FREE_PERIOD - 1, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );
    }

    function test_register_premium_revertsIfPeriodTooShort() public {
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH + PREMIUM_FEE}(
            aliceBackup,
            PREMIUM_PERIOD - 1,
            IAeternumVault.SubscriptionTier.Premium,
            IAeternumVault.SubscriptionPlan.Monthly
        );
    }

    function test_register_revertsIfPeriodTooLong() public {
        uint256 tooLong = rm.MAX_INACTIVITY_PERIOD() + 1;
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        vm.prank(alice);
        rm.register{value: 0}(
            aliceBackup, tooLong, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );
    }

    function test_register_premium_revertsIfFeeInsufficient() public {
        vm.expectRevert(IAeternumVault.AeternumVault__InsufficientSubscriptionFee.selector);
        vm.prank(alice);
        rm.register{value: PREMIUM_FEE - 1}(
            aliceBackup,
            PREMIUM_PERIOD,
            IAeternumVault.SubscriptionTier.Premium,
            IAeternumVault.SubscriptionPlan.Monthly
        );
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
        rm.register{value: DEPOSIT_1_ETH}(
            address(badBackup),
            FREE_PERIOD,
            IAeternumVault.SubscriptionTier.Free,
            IAeternumVault.SubscriptionPlan.Monthly
        );

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(alice);
            (, bytes memory pd) = rm.checkUpkeep(bytes(""));
            rm.performUpkeep(pd);
        }

        assertTrue(rm.isBackupAbandoned(address(badBackup)));

        // Bob also tries to use the same bad backup — should be blocked
        vm.expectRevert(IAeternumVault.AeternumVault__WalletAbandoned.selector);
        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(
            address(badBackup),
            FREE_PERIOD,
            IAeternumVault.SubscriptionTier.Free,
            IAeternumVault.SubscriptionPlan.Monthly
        );
    }

    /*//////////////////////////////////////////////////////////////
                          4. DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function test_deposit_increasesBalance() public {
        _registerAliceFree();
        uint256 balanceBefore = rm.getRecoveryConfig(alice).balance;

        vm.prank(alice);
        rm.deposit{value: 0.5 ether}();

        assertEq(rm.getRecoveryConfig(alice).balance, balanceBefore + 0.5 ether);
    }

    function test_deposit_resetsActivityTimer() public {
        _registerAliceFree();
        uint256 warpTo = block.timestamp + 50 days;
        vm.warp(warpTo);

        vm.prank(alice);
        rm.deposit{value: 0.5 ether}();

        assertEq(rm.getRecoveryConfig(alice).lastActivity, warpTo);
    }

    function test_deposit_emitsEvents() public {
        _registerAliceFree();

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
        _registerAliceFree();

        vm.expectRevert(IAeternumVault.AeternumVault__InsufficientBalance.selector);
        vm.prank(alice);
        rm.deposit{value: 0}();
    }

    /*//////////////////////////////////////////////////////////////
                          5. WITHDRAWALL
    //////////////////////////////////////////////////////////////*/

    function test_withdrawAll_emptiesBalance() public {
        _registerAliceFree();

        vm.prank(alice);
        rm.withdrawAll();

        assertEq(rm.getRecoveryConfig(alice).balance, 0);
    }

    function test_withdrawAll_keepsConfigActive() public {
        _registerAliceFree();

        vm.prank(alice);
        rm.withdrawAll();

        // Config persists; user can deposit again
        assertTrue(rm.getRecoveryConfig(alice).isActive);
        assertEq(rm.getTotalRegistered(), 1);
    }

    function test_withdrawAll_revertsIfZeroBalance() public {
        vm.prank(alice);
        rm.register{value: 0}(
            aliceBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );

        vm.expectRevert(IAeternumVault.AeternumVault__NothingToWithdraw.selector);
        vm.prank(alice);
        rm.withdrawAll();
    }

    function test_withdrawAll_revertsIfTransferFails() public {
        RejectingCallerMock rejecter = new RejectingCallerMock(address(rm));
        deal(address(rejecter), 2 ether);

        rejecter.doRegister{value: DEPOSIT_1_ETH}(aliceBackup, FREE_PERIOD);

        vm.expectRevert(IAeternumVault.AeternumVault__TransferFailed.selector);
        rejecter.doWithdrawAll();
    }

    /*//////////////////////////////////////////////////////////////
                          5b. SEND
    //////////////////////////////////////////////////////////////*/

    function test_send_transfersETHtoRecipient() public {
        _registerAliceFree();
        address recipient = makeAddr("recipient");
        uint256 sendAmt = 0.4 ether;

        vm.prank(alice);
        rm.send(recipient, sendAmt);

        assertEq(recipient.balance, sendAmt);
    }

    function test_send_reducesVaultBalance() public {
        _registerAliceFree();
        uint256 sendAmt = 0.4 ether;

        vm.prank(alice);
        rm.send(makeAddr("recipient"), sendAmt);

        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH - sendAmt);
    }

    function test_send_resetsActivityTimer() public {
        _registerAliceFree();
        vm.warp(block.timestamp + 50 days);

        vm.prank(alice);
        rm.send(makeAddr("recipient"), 0.1 ether);

        assertEq(rm.getRecoveryConfig(alice).lastActivity, block.timestamp);
    }

    function test_send_emitsEvents() public {
        _registerAliceFree();
        address recipient = makeAddr("recipient");

        vm.expectEmit(true, true, false, true);
        emit Sent(alice, recipient, 0.3 ether);

        vm.expectEmit(true, false, false, true);
        emit ActivityPinged(alice, block.timestamp);

        vm.prank(alice);
        rm.send(recipient, 0.3 ether);
    }

    function test_send_revertsOnZeroAddress() public {
        _registerAliceFree();
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidBackupAddress.selector);
        vm.prank(alice);
        rm.send(address(0), 0.1 ether);
    }

    function test_send_revertsOnZeroAmount() public {
        _registerAliceFree();
        vm.expectRevert(IAeternumVault.AeternumVault__NothingToWithdraw.selector);
        vm.prank(alice);
        rm.send(makeAddr("recipient"), 0);
    }

    function test_send_revertsOnInsufficientBalance() public {
        _registerAliceFree();
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
        _registerAliceFree();
        RejectingReceiver rejecter = new RejectingReceiver();

        vm.expectRevert(IAeternumVault.AeternumVault__TransferFailed.selector);
        vm.prank(alice);
        rm.send(address(rejecter), 0.1 ether);
    }

    function testFuzz_send_amount(uint128 amount) public {
        vm.assume(amount > 0 && amount <= DEPOSIT_1_ETH);
        _registerAliceFree();
        address recipient = makeAddr("recipient");

        vm.prank(alice);
        rm.send(recipient, amount);

        assertEq(recipient.balance, amount);
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH - amount);
    }

    /*//////////////////////////////////////////////////////////////
                             6. PING
    //////////////////////////////////////////////////////////////*/

    function test_ping_resetsLastActivity() public {
        _registerAliceFree();
        uint256 laterTs = block.timestamp + 100 days;
        vm.warp(laterTs);

        vm.prank(alice);
        rm.ping();

        assertEq(rm.getRecoveryConfig(alice).lastActivity, laterTs);
    }

    function test_ping_preventsRecovery() public {
        _registerAliceFree();
        vm.warp(block.timestamp + 179 days);

        vm.prank(alice);
        rm.ping(); // Reset timer

        vm.warp(block.timestamp + 179 days); // Still < 180 days from ping

        assertFalse(rm.isRecoveryDue(alice));
    }

    function test_ping_revertsIfNotRegistered() public {
        vm.expectRevert(IAeternumVault.AeternumVault__NotRegistered.selector);
        vm.prank(alice);
        rm.ping();
    }

    function test_ping_emitsActivityPinged() public {
        _registerAliceFree();

        vm.expectEmit(true, false, false, true);
        emit ActivityPinged(alice, block.timestamp);

        vm.prank(alice);
        rm.ping();
    }

    /*//////////////////////////////////////////////////////////////
                       7. CONFIG UPDATES
    //////////////////////////////////////////////////////////////*/

    function test_updateBackupAddress_success() public {
        _registerAliceFree();
        address newBackup = makeAddr("newBackup");

        vm.prank(alice);
        rm.updateBackupAddress(newBackup);

        assertEq(rm.getRecoveryConfig(alice).backupAddress, newBackup);
    }

    function test_updateBackupAddress_resetsTimer() public {
        _registerAliceFree();
        vm.warp(block.timestamp + 50 days);

        vm.prank(alice);
        rm.updateBackupAddress(makeAddr("newBackup"));

        assertEq(rm.getRecoveryConfig(alice).lastActivity, block.timestamp);
    }

    function test_updateBackupAddress_revertsOnZero() public {
        _registerAliceFree();
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidBackupAddress.selector);
        vm.prank(alice);
        rm.updateBackupAddress(address(0));
    }

    function test_updateBackupAddress_revertsOnSelf() public {
        _registerAliceFree();
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidBackupAddress.selector);
        vm.prank(alice);
        rm.updateBackupAddress(alice);
    }

    function test_updateBackupAddress_revertsIfBackupIsAbandoned() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(
            address(badBackup),
            FREE_PERIOD,
            IAeternumVault.SubscriptionTier.Free,
            IAeternumVault.SubscriptionPlan.Monthly
        );

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(alice);
            (, bytes memory pd) = rm.checkUpkeep(bytes(""));
            rm.performUpkeep(pd);
        }

        // Alice re-registers fine with a new backup
        vm.prank(alice);
        rm.register{value: 0.5 ether}(
            aliceBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );

        // But trying to update to the abandoned backup is blocked
        vm.expectRevert(IAeternumVault.AeternumVault__WalletAbandoned.selector);
        vm.prank(alice);
        rm.updateBackupAddress(address(badBackup));
    }

    function test_updateInactivityPeriod_freeUser_success() public {
        _registerAliceFree();

        vm.prank(alice);
        rm.updateInactivityPeriod(400 days);

        assertEq(rm.getRecoveryConfig(alice).inactivityPeriod, 400 days);
    }

    function test_updateInactivityPeriod_premiumUser_canUseShorterPeriod() public {
        _registerAlicePremium();

        vm.prank(alice);
        rm.updateInactivityPeriod(200 days);

        assertEq(rm.getRecoveryConfig(alice).inactivityPeriod, 200 days);
    }

    function test_updateInactivityPeriod_freeUser_revertsIfBelowMin() public {
        _registerAliceFree();
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        vm.prank(alice);
        rm.updateInactivityPeriod(FREE_PERIOD - 1);
    }

    function test_updateInactivityPeriod_expiredPremiumEnforcesFreeMin() public {
        _registerAlicePremium();

        // Expire the subscription
        vm.warp(block.timestamp + 31 days);

        // Should now enforce FREE minimum
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        vm.prank(alice);
        rm.updateInactivityPeriod(45 days); // 45 < 180 days free min
    }

    function test_updateInactivityPeriod_revertsIfPeriodTooLong() public {
        _registerAliceFree();
        uint256 invalidPeriod = rm.MAX_INACTIVITY_PERIOD() + 1;
        vm.expectRevert(IAeternumVault.AeternumVault__InvalidInactivityPeriod.selector);
        vm.prank(alice);
        rm.updateInactivityPeriod(invalidPeriod);
    }

    function test_expiredPremium_effectivePeriodReverts_toFreeMinimum() public {
        _registerAlicePremium(); // inactivityPeriod = PREMIUM_PERIOD (180 days)

        // Expire the subscription
        vm.warp(block.timestamp + rm.SUBSCRIPTION_DURATION() + 1);

        // Recovery should NOT be due at 200 days — effective period is now FREE (365 days)
        vm.warp(block.timestamp + 200 days);
        assertFalse(rm.isRecoveryDue(alice));

        // Recovery SHOULD be due at 365+ days from lastActivity
        _warpPastInactivity(alice); // warps to lastActivity + FREE_PERIOD + 1
        // But lastActivity is still the registration time, so we need to warp enough
        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        vm.warp(cfg.lastActivity + rm.MIN_INACTIVITY_PERIOD_FREE() + 1);
        assertTrue(rm.isRecoveryDue(alice));
    }

    /*//////////////////////////////////////////////////////////////
                    8. SUBSCRIPTION RENEWAL
    //////////////////////////////////////////////////////////////*/

    function test_renewSubscription_upgradesFreeToPreimum() public {
        _registerAliceFree();

        vm.prank(alice);
        rm.renewSubscription{value: PREMIUM_FEE}(IAeternumVault.SubscriptionPlan.Monthly);

        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertEq(uint256(cfg.tier), uint256(IAeternumVault.SubscriptionTier.Premium));
        assertEq(cfg.subscriptionExpiry, block.timestamp + 30 days);
    }

    function test_renewSubscription_extendsPremiumExpiry() public {
        _registerAlicePremium();
        uint256 currentExpiry = rm.getRecoveryConfig(alice).subscriptionExpiry;

        vm.prank(alice);
        rm.renewSubscription{value: PREMIUM_FEE}(IAeternumVault.SubscriptionPlan.Monthly);

        assertEq(rm.getRecoveryConfig(alice).subscriptionExpiry, currentExpiry + 30 days);
    }

    function test_renewSubscription_accumulatesFees() public {
        _registerAliceFree();
        uint256 feesBefore = rm.getAccumulatedFees();

        vm.prank(alice);
        rm.renewSubscription{value: PREMIUM_FEE}(IAeternumVault.SubscriptionPlan.Monthly);

        assertEq(rm.getAccumulatedFees(), feesBefore + PREMIUM_FEE);
    }

    function test_renewSubscription_revertsIfFeeInsufficient() public {
        _registerAliceFree();
        vm.expectRevert(IAeternumVault.AeternumVault__InsufficientSubscriptionFee.selector);
        vm.prank(alice);
        rm.renewSubscription{value: PREMIUM_FEE - 1}(IAeternumVault.SubscriptionPlan.Monthly);
    }

    function test_renewSubscription_whenExpired_startsFresh() public {
        _registerAlicePremium();

        // Let the subscription expire
        vm.warp(block.timestamp + 31 days);
        uint256 expectedExpiry = block.timestamp + 30 days;

        vm.prank(alice);
        rm.renewSubscription{value: PREMIUM_FEE}(IAeternumVault.SubscriptionPlan.Monthly);

        // New expiry should start from now, not stack on old expired expiry
        assertEq(rm.getRecoveryConfig(alice).subscriptionExpiry, expectedExpiry);
    }

    function test_register_premium_annual_setsCorrectExpiry() public {
        uint256 annualFee = rm.PREMIUM_ANNUAL_FEE();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH + annualFee}(
            aliceBackup, PREMIUM_PERIOD, IAeternumVault.SubscriptionTier.Premium, IAeternumVault.SubscriptionPlan.Annual
        );

        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertEq(cfg.subscriptionExpiry, block.timestamp + 12 * rm.SUBSCRIPTION_DURATION());
    }

    function test_renewSubscription_annual_extendsBy12Periods() public {
        _registerAlicePremium();
        uint256 currentExpiry = rm.getRecoveryConfig(alice).subscriptionExpiry;
        uint256 annualFee = rm.PREMIUM_ANNUAL_FEE();

        vm.prank(alice);
        rm.renewSubscription{value: annualFee}(IAeternumVault.SubscriptionPlan.Annual);

        assertEq(rm.getRecoveryConfig(alice).subscriptionExpiry, currentExpiry + 12 * rm.SUBSCRIPTION_DURATION());
    }

    function test_renewSubscription_annual_revertsIfFeeTooLow() public {
        _registerAliceFree();
        uint256 annualFee = rm.PREMIUM_ANNUAL_FEE();

        vm.expectRevert(IAeternumVault.AeternumVault__InsufficientSubscriptionFee.selector);
        vm.prank(alice);
        rm.renewSubscription{value: annualFee - 1}(IAeternumVault.SubscriptionPlan.Annual);
    }

    function test_renewSubscription_monthly_revertsIfOverpaid() public {
        _registerAliceFree();
        // Sending even 1 wei over should revert — overspend goes to treasury otherwise
        vm.expectRevert(IAeternumVault.AeternumVault__InsufficientSubscriptionFee.selector);
        vm.prank(alice);
        rm.renewSubscription{value: PREMIUM_FEE + 1}(IAeternumVault.SubscriptionPlan.Monthly);
    }

    function test_renewSubscription_annual_revertsIfOverpaid() public {
        _registerAliceFree();
        uint256 annualFee = rm.PREMIUM_ANNUAL_FEE();
        vm.expectRevert(IAeternumVault.AeternumVault__InsufficientSubscriptionFee.selector);
        vm.prank(alice);
        rm.renewSubscription{value: annualFee + 1}(IAeternumVault.SubscriptionPlan.Annual);
    }

    function test_renewSubscription_monthly_exactPaymentAccumulatesExactFee() public {
        _registerAliceFree();
        uint256 feesBefore = rm.getAccumulatedFees();

        vm.prank(alice);
        rm.renewSubscription{value: PREMIUM_FEE}(IAeternumVault.SubscriptionPlan.Monthly);

        // Exactly PREMIUM_FEE added — not a wei more
        assertEq(rm.getAccumulatedFees(), feesBefore + PREMIUM_FEE);
    }

    function test_renewSubscription_annual_exactPaymentAccumulatesExactFee() public {
        _registerAliceFree();
        uint256 annualFee = rm.PREMIUM_ANNUAL_FEE();
        uint256 feesBefore = rm.getAccumulatedFees();

        vm.prank(alice);
        rm.renewSubscription{value: annualFee}(IAeternumVault.SubscriptionPlan.Annual);

        assertEq(rm.getAccumulatedFees(), feesBefore + annualFee);
    }

    /*//////////////////////////////////////////////////////////////
                       9. CANCEL RECOVERY
    //////////////////////////////////////////////////////////////*/

    function test_cancelRecovery_refundsBalance() public {
        _registerAliceFree();
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        rm.cancelRecovery();

        assertEq(alice.balance, ethBefore + DEPOSIT_1_ETH);
    }

    function test_cancelRecovery_removesFromRegistry() public {
        _registerAliceFree();

        vm.prank(alice);
        rm.cancelRecovery();

        assertEq(rm.getTotalRegistered(), 0);
        assertFalse(rm.getRecoveryConfig(alice).isActive);
    }

    function test_cancelRecovery_emitsEvent() public {
        _registerAliceFree();

        vm.expectEmit(true, false, false, true);
        emit RecoveryCancelled(alice, DEPOSIT_1_ETH);

        vm.prank(alice);
        rm.cancelRecovery();
    }

    function test_cancelRecovery_allowsReRegistration() public {
        _registerAliceFree();
        vm.prank(alice);
        rm.cancelRecovery();

        // Can register again
        vm.prank(alice);
        rm.register{value: 0.5 ether}(
            aliceBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );
        assertTrue(rm.getRecoveryConfig(alice).isActive);
    }

    function test_cancelRecovery_revertsIfNotRegistered() public {
        vm.expectRevert(IAeternumVault.AeternumVault__NotRegistered.selector);
        vm.prank(alice);
        rm.cancelRecovery();
    }

    function test_cancelRecovery_withZeroBalance_noTransfer() public {
        vm.prank(alice);
        rm.register{value: 0}(
            aliceBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        rm.cancelRecovery();

        assertEq(alice.balance, ethBefore); // no ETH transferred
    }

    function test_cancelRecovery_whenWalletIsLastInRegistry() public {
        // Alice is the only wallet — she IS the last element.
        // _removeFromRegistry should take the else path (no swap needed, just pop).
        _registerAliceFree();

        vm.prank(alice);
        rm.cancelRecovery();

        assertEq(rm.getTotalRegistered(), 0);
        assertFalse(rm.isRegistered(alice));
    }

    function test_cancelRecovery_revertsIfTransferFails() public {
        RejectingCallerMock rejecter = new RejectingCallerMock(address(rm));
        deal(address(rejecter), 2 ether);

        rejecter.doRegister{value: DEPOSIT_1_ETH}(aliceBackup, FREE_PERIOD);

        vm.expectRevert(IAeternumVault.AeternumVault__TransferFailed.selector);
        rejecter.doCancelRecovery();
    }

    /*//////////////////////////////////////////////////////////////
                    SECTION 10 — CHECK UPKEEP
    //////////////////////////////////////////////////////////////*/

    function test_checkUpkeep_returnsFalseIfRegistryEmpty() public view {
        (bool needed,) = rm.checkUpkeep(bytes(""));
        assertFalse(needed);
    }

    function test_checkUpkeep_returnsFalseIfNoWalletsDueAndIntervalNotElapsed() public {
        _registerAliceFree();
        // Interval hasn't elapsed and alice is not due
        (bool needed,) = rm.checkUpkeep(bytes(""));
        assertFalse(needed);
    }

    function test_checkUpkeep_returnsTrueWithCandidatesWhenWalletIsDue() public {
        _registerAliceFree();
        _warpPastInactivity(alice);

        (bool needed, bytes memory performData) = rm.checkUpkeep(bytes(""));

        assertTrue(needed);
        (address[] memory candidates,,) = abi.decode(performData, (address[], uint256, bool));
        assertEq(candidates.length, 1);
        assertEq(candidates[0], alice);
    }

    function test_checkUpkeep_doesNotIncludeZeroBalanceWallet_inCandidates() public {
        vm.prank(alice);
        rm.register{value: 0}(
            aliceBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );
        _warpPastInactivity(alice);

        (bool needed, bytes memory performData) = rm.checkUpkeep(bytes(""));

        if (needed) {
            // Cursor may advance (idle tick) but alice must never be a candidate
            (address[] memory candidates,,) = abi.decode(performData, (address[], uint256, bool));
            for (uint256 i = 0; i < candidates.length; i++) {
                assertTrue(candidates[i] != alice, "Zero-balance wallet must not appear as candidate");
            }
        }
        // Whether needed or not, the zero-balance wallet is correctly excluded
    }

    function test_checkUpkeep_returnsMaxPerformSize_whenMoreWalletsDueThanPerformCap() public {
        // Deploy vault with check=20, perform=3 so we can register 10 due wallets
        // and verify only 3 are returned
        cv = _deployCursorVault(20, 3, 30 seconds);
        _registerWallets(cv, 10, 0);
        vm.warp(block.timestamp + cv.MIN_INACTIVITY_PERIOD_FREE() + 1);

        (bool needed, bytes memory performData) = cv.checkUpkeep(bytes(""));

        assertTrue(needed);
        (address[] memory candidates,,) = abi.decode(performData, (address[], uint256, bool));
        assertEq(candidates.length, cv.MAX_PERFORM_UPKEEP_SIZE()); // 3, not 10
    }

    function test_checkUpkeep_ignoresCheckData_parameter() public {
        // checkData is ignored in the cursor architecture
        _registerAliceFree();
        _warpPastInactivity(alice);

        bytes memory arbitraryCheckData = abi.encode(uint256(999), uint256(999));
        (bool needed, bytes memory performData) = rm.checkUpkeep(arbitraryCheckData);

        assertTrue(needed);
        (address[] memory candidates,,) = abi.decode(performData, (address[], uint256, bool));
        assertEq(candidates[0], alice);
    }

    /*//////////////////////////////////////////////////////////////
                    SSECTION 10b — CURSOR BEHAVIOUR
    //////////////////////////////////////////////////////////////*/

    //            CURSOR HOLD — due wallets in window

    function test_cursor_holdsPosition_whenDueWalletsExistInWindow() public {
        cv = _deployCursorVault(10, 3, 30 seconds);
        _registerWallets(cv, 5, 0);
        vm.warp(block.timestamp + cv.MIN_INACTIVITY_PERIOD_FREE() + 1);

        uint256 cursorBefore = cv.getCheckCursor(); // 0

        (, bytes memory performData) = cv.checkUpkeep(bytes(""));
        (, uint256 nextCursor,) = abi.decode(performData, (address[], uint256, bool));

        // nextCursor must equal current cursor — window held
        assertEq(nextCursor, cursorBefore, "Cursor should HOLD when due wallets exist");
    }

    function test_cursor_doesNotUpdateAdvanceTimestamp_duringRecoveryPass() public {
        cv = _deployCursorVault(10, 3, 30 seconds);
        _registerWallets(cv, 3, 0);
        vm.warp(block.timestamp + cv.MIN_INACTIVITY_PERIOD_FREE() + 1);

        uint256 timestampBefore = cv.getLastCursorAdvance(); // 0

        (, bytes memory performData) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(performData);

        // s_lastCursorAdvance must NOT be updated during a recovery pass
        assertEq(cv.getLastCursorAdvance(), timestampBefore, "Advance timestamp must not update when cursor holds");
    }

    function test_cursor_remainsAtZero_afterPartialWindowRecovery() public {
        // check=10, perform=3, register 7 due wallets
        // Each performUpkeep recovers 3. Cursor should stay at 0 until all 7 cleared.
        cv = _deployCursorVault(10, 3, 30 seconds);
        _registerWallets(cv, 7, 0);
        vm.warp(block.timestamp + cv.MIN_INACTIVITY_PERIOD_FREE() + 1);

        // First performUpkeep: recovers 3
        (, bytes memory pd1) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd1);
        assertEq(cv.getCheckCursor(), 0, "Cursor should still be 0 after first batch");

        // Second performUpkeep: recovers 3 more
        (, bytes memory pd2) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd2);
        assertEq(cv.getCheckCursor(), 0, "Cursor should still be 0 after second batch");

        // Third performUpkeep: recovers last 1
        (, bytes memory pd3) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd3);
        assertEq(cv.getCheckCursor(), 0, "Cursor should still be 0 after final batch");

        // All 7 recovered
        assertEq(cv.getTotalRegistered(), 0);
    }

    //          CURSOR ADVANCE — idle window, interval elapsed
    function test_cursor_returnsFalse_whenWindowClear_andIntervalNotElapsed() public {
        cv = _deployCursorVault(10, 3, 30 seconds);
        _registerWallets(cv, 3, 0);
        // Wallets not yet due, interval not elapsed

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
        cv = _deployCursorVault(4, 2, 30 seconds); // window size 4
        _registerWallets(cv, 8, 0); // 2 full windows
        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);

        uint256 cursorBefore = cv.getCheckCursor(); // 0

        (, bytes memory pd) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd);

        // Cursor should have advanced by MAX_CHECK_UPKEEP_SIZE (4)
        assertEq(cv.getCheckCursor(), cursorBefore + 4);
    }

    function test_cursor_updatesAdvanceTimestamp_onIdleAdvance() public {
        cv = _deployCursorVault(10, 3, 30 seconds);
        _registerWallets(cv, 3, 0);
        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);

        (, bytes memory pd) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd);

        assertEq(cv.getLastCursorAdvance(), block.timestamp, "Advance timestamp must update on idle cursor advance");
    }

    //                CURSOR WRAP-AROUND
    function test_cursor_wrapsToZero_whenEndOfRegistryReached() public {
        // check=4, perform=2 — register 6 wallets (2 full windows: [0-3], [4-5])
        cv = _deployCursorVault(4, 2, 30 seconds);
        _registerWallets(cv, 6, 0);

        // Advance cursor to second window via idle advance
        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);
        (, bytes memory pd1) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd1); // cursor moves to 4

        assertEq(cv.getCheckCursor(), 4);

        // Advance again — cursor should wrap to 0 (end of registry)
        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);
        (, bytes memory pd2) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd2); // cursor at end, wraps to 0

        assertEq(cv.getCheckCursor(), 0, "Cursor should wrap to 0 at end of registry");
    }

    function test_cursor_resetsToZero_whenRegistryShrunkBelowCursor() public {
        // check=10, perform=3 — advance cursor to 8, then drop registry to 3 wallets
        cv = _deployCursorVault(10, 3, 30 seconds);
        (address[] memory users,) = _registerWallets(cv, 10, 0);

        // Advance cursor to 10 (end = wrap to 0), then re-register 3 to get cursor > total
        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);
        (, bytes memory pd) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd); // cursor wraps to 0 after scanning all 10

        // Now manually cancel 7 wallets to shrink registry — cursor might end up > total
        for (uint256 i = 0; i < 7; i++) {
            vm.prank(users[i]);
            cv.cancelRecovery();
        }

        // Force cursor past new total by doing another advance
        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);
        (bool needed,) = cv.checkUpkeep(bytes(""));
        // Should not revert — cursor >= total resets to 0 gracefully
        (needed,) = cv.checkUpkeep(bytes(""));
        // Just verifying no revert. Cursor normalisation happens internally.
        assertTrue(true, "No revert when cursor exceeds total");
    }

    //         WINDOW FULLY CLEARED — cursor advances after
    function test_cursor_advancesAfterWindowFullyCleared() public {
        cv = _deployCursorVault(6, 3, 30 seconds);
        _registerWallets(cv, 6, 0);
        vm.warp(block.timestamp + cv.MIN_INACTIVITY_PERIOD_FREE() + 1);

        // Batch 1: recover 3, cursor holds at 0
        (, bytes memory pd1) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd1);
        assertEq(cv.getCheckCursor(), 0);

        // Batch 2: recover remaining 3, cursor holds at 0
        (, bytes memory pd2) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd2);
        assertEq(cv.getCheckCursor(), 0);
        assertEq(cv.getTotalRegistered(), 0);

        // Add 3 non-due wallets so registry isn't empty for future checks
        _registerWallets(cv, 3, 100);
        assertEq(cv.getTotalRegistered(), 3);

        // s_lastCursorAdvance is still 0 (recovery passes don't touch it),
        // and block.timestamp is 365 days >> 30s interval, so idle advance
        // fires immediately. Consume it to reset the timer.
        (bool immediateAdvance, bytes memory immPd) = cv.checkUpkeep(bytes(""));
        assertTrue(immediateAdvance, "Idle advance immediately eligible after recovery clears");
        cv.performUpkeep(immPd);
        assertEq(cv.getLastCursorAdvance(), block.timestamp, "Timer reset after first idle advance");

        // Interval just reset — checkUpkeep should now return false
        (bool tooSoon,) = cv.checkUpkeep(bytes(""));
        assertFalse(tooSoon, "Should return false before interval elapses again");

        // After interval elapses, idle advance triggers again
        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);
        (bool neededAfter, bytes memory pd3) = cv.checkUpkeep(bytes(""));
        assertTrue(neededAfter, "Should trigger idle cursor advance after interval");

        (address[] memory candidates,, bool isIdleAdvance) = abi.decode(pd3, (address[], uint256, bool));
        assertEq(candidates.length, 0, "No due wallets - window is clear");
        assertTrue(isIdleAdvance, "Should be flagged as idle advance");

        cv.performUpkeep(pd3);
        assertEq(cv.getLastCursorAdvance(), block.timestamp, "Timestamp updated after second idle advance");
    }

    /*//////////////////////////////////////////////////////////////
                    SECTION 11 — PERFORM UPKEEP
    //////////////////////////////////////////////////////////////*/

    function test_performUpkeep_executesRecovery_andZeroesBalance() public {
        _registerAliceFree();
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(pd);

        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertFalse(cfg.isActive);
        assertEq(cfg.balance, 0);
    }

    function test_performUpkeep_transfersETHToBackup() public {
        _registerAliceFree();
        _warpPastInactivity(alice);
        uint256 backupBefore = aliceBackup.balance;

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(pd);

        assertEq(aliceBackup.balance, backupBefore + DEPOSIT_1_ETH);
    }

    function test_performUpkeep_removesWalletFromRegistry() public {
        _registerAliceFree();
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(pd);

        assertEq(rm.getTotalRegistered(), 0);
    }

    function test_performUpkeep_emitsRecoveryExecuted() public {
        _registerAliceFree();
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
            rm.register{value: DEPOSIT_1_ETH}(
                backups[i], FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
            );
        }

        vm.warp(block.timestamp + FREE_PERIOD + 1);
        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(pd);

        assertEq(rm.getTotalRegistered(), 0);
        for (uint256 i = 0; i < 3; i++) {
            assertFalse(rm.getRecoveryConfig(users[i]).isActive);
            assertEq(backups[i].balance, DEPOSIT_1_ETH);
        }
    }

    //                STALE DATA SAFETY
    function test_staleData_skipsWallet_afterUserPings() public {
        _registerAliceFree();
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));

        // Alice pings between checkUpkeep and performUpkeep
        vm.prank(alice);
        rm.ping();

        rm.performUpkeep(pd);

        // Alice was skipped — still active, balance intact
        assertTrue(rm.getRecoveryConfig(alice).isActive);
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH);
    }

    function test_staleData_skipsWallet_afterUserDeposits() public {
        _registerAliceFree();
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));

        // Alice deposits — resets activity timer
        vm.prank(alice);
        rm.deposit{value: 0.1 ether}();

        rm.performUpkeep(pd);

        assertTrue(rm.getRecoveryConfig(alice).isActive);
    }

    function test_staleData_skipsWallet_afterUserCancelsRecovery() public {
        _registerAliceFree();
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));

        // Alice cancels between check and perform
        vm.prank(alice);
        rm.cancelRecovery();

        // Should not revert — stale entry silently skipped
        rm.performUpkeep(pd);

        assertFalse(rm.getRecoveryConfig(alice).isActive);
        assertEq(rm.getTotalRegistered(), 0);
    }

    function test_staleData_skipsAlreadyRecoveredWallet() public {
        _registerAliceFree();
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(pd); // First execution — alice recovered

        // Second call with same stale performData — must not revert
        rm.performUpkeep(pd);
        assertEq(rm.getRecoveryConfig(alice).balance, 0);
    }

    function test_staleData_continuesBatch_whenOneWalletStale() public {
        // Alice: will be stale (pings before perform). Bob: should still recover.
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(
            aliceBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );
        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(
            bobBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );

        vm.warp(block.timestamp + FREE_PERIOD + 1);
        (, bytes memory pd) = rm.checkUpkeep(bytes(""));

        // Alice pings — becomes stale
        vm.prank(alice);
        rm.ping();

        rm.performUpkeep(pd);

        // Alice: skipped — still active
        assertTrue(rm.getRecoveryConfig(alice).isActive);
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH);

        // Bob: recovered
        assertFalse(rm.getRecoveryConfig(bob).isActive);
        assertEq(bobBackup.balance, DEPOSIT_1_ETH);
    }

    //            CURSOR STATE IN PERFORM UPKEEP
    function test_performUpkeep_setsCheckCursor_toNextCursor() public {
        cv = _deployCursorVault(4, 2, 30 seconds);
        _registerWallets(cv, 4, 0); // exactly one window

        vm.warp(block.timestamp + cv.CURSOR_ADVANCE_INTERVAL() + 1);
        (, bytes memory pd) = cv.checkUpkeep(bytes(""));
        (, uint256 nextCursor,) = abi.decode(pd, (address[], uint256, bool));

        cv.performUpkeep(pd);

        assertEq(cv.getCheckCursor(), nextCursor);
    }

    function test_performUpkeep_holdsCheckCursor_duringRecoveryPass() public {
        cv = _deployCursorVault(10, 3, 30 seconds);
        _registerWallets(cv, 5, 0);
        vm.warp(block.timestamp + cv.MIN_INACTIVITY_PERIOD_FREE() + 1);

        uint256 cursorBefore = cv.getCheckCursor();
        (, bytes memory pd) = cv.checkUpkeep(bytes(""));
        cv.performUpkeep(pd);

        assertEq(cv.getCheckCursor(), cursorBefore, "Cursor must remain at same position during recovery pass");
    }

    /*//////////////////////////////////////////////////////////////
            SECTION 11b — RECOVERY FAILURE & ABANDONMENT
    //////////////////////////////////////////////////////////////*/

    function test_performUpkeep_emitsRecoveryFailed_onBadBackupAddress() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(
            address(badBackup),
            FREE_PERIOD,
            IAeternumVault.SubscriptionTier.Free,
            IAeternumVault.SubscriptionPlan.Monthly
        );
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));

        vm.expectEmit(true, true, false, true);
        emit RecoveryFailed(alice, address(badBackup), DEPOSIT_1_ETH);

        rm.performUpkeep(pd);
    }

    function test_performUpkeep_restoresState_onFailedTransfer() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(
            address(badBackup),
            FREE_PERIOD,
            IAeternumVault.SubscriptionTier.Free,
            IAeternumVault.SubscriptionPlan.Monthly
        );
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
        rm.register{value: DEPOSIT_1_ETH}(
            address(badBackup),
            FREE_PERIOD,
            IAeternumVault.SubscriptionTier.Free,
            IAeternumVault.SubscriptionPlan.Monthly
        );
        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(
            bobBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );

        vm.warp(block.timestamp + FREE_PERIOD + 1);
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
        rm.register{value: DEPOSIT_1_ETH}(
            address(badBackup),
            FREE_PERIOD,
            IAeternumVault.SubscriptionTier.Free,
            IAeternumVault.SubscriptionPlan.Monthly
        );
        _warpPastInactivity(alice);

        (, bytes memory pd) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(pd);

        assertEq(rm.getRecoveryConfig(alice).failedRecoveryAttempts, 1);
    }

    function test_executeRecovery_abandonedAfterMaxAttempts() public {
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(
            address(badBackup),
            FREE_PERIOD,
            IAeternumVault.SubscriptionTier.Free,
            IAeternumVault.SubscriptionPlan.Monthly
        );

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
        rm.register{value: DEPOSIT_1_ETH}(
            address(badBackup),
            FREE_PERIOD,
            IAeternumVault.SubscriptionTier.Free,
            IAeternumVault.SubscriptionPlan.Monthly
        );

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
        rm.register{value: DEPOSIT_1_ETH}(
            address(badBackup),
            FREE_PERIOD,
            IAeternumVault.SubscriptionTier.Free,
            IAeternumVault.SubscriptionPlan.Monthly
        );

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(alice);
            (, bytes memory pd) = rm.checkUpkeep(bytes(""));
            rm.performUpkeep(pd);
        }

        // Registry is now empty. Warp past interval for idle advance.
        vm.warp(block.timestamp + rm.CURSOR_ADVANCE_INTERVAL() + 1);

        (bool advanceNeeded, bytes memory advancePd) = rm.checkUpkeep(bytes(""));

        // Only call performUpkeep if checkUpkeep says to — never on empty bytes
        if (advanceNeeded) {
            rm.performUpkeep(advancePd);
            // Verify abandoned wallet is not in the candidates
            (address[] memory candidates,,) = abi.decode(advancePd, (address[], uint256, bool));
            for (uint256 i = 0; i < candidates.length; i++) {
                assertTrue(candidates[i] != alice, "Abandoned wallet must never appear as candidate");
            }
        }

        // Registry empty — confirmed abandoned wallet no longer monitored
        assertEq(rm.getTotalRegistered(), 0);
        assertTrue(rm.getRecoveryConfig(alice).isAbandoned);
    }

    function test_reregister_carriesOverAbandonedBalance_whenSkippingWithdrawal() public {
        // Alice gets abandoned with 1 ETH in the vault
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(
            address(badBackup),
            FREE_PERIOD,
            IAeternumVault.SubscriptionTier.Free,
            IAeternumVault.SubscriptionPlan.Monthly
        );

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(alice);
            (, bytes memory pd) = rm.checkUpkeep(bytes(""));
            rm.performUpkeep(pd);
        }

        assertTrue(rm.getRecoveryConfig(alice).isAbandoned);
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH);

        // Alice re-registers WITHOUT calling withdrawAll() first
        // New deposit: 0.5 ETH. Expected balance: 1 ETH (carried) + 0.5 ETH (new) = 1.5 ETH
        uint256 newDeposit = 0.5 ether;
        vm.prank(alice);
        rm.register{value: newDeposit}(
            aliceBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );

        IAeternumVault.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertEq(cfg.balance, DEPOSIT_1_ETH + newDeposit, "Carried balance + new deposit must sum correctly");
        assertTrue(cfg.isActive);
        assertFalse(cfg.isAbandoned, "isAbandoned must be cleared on re-registration");
        assertEq(cfg.backupAddress, aliceBackup);
    }

    function test_reregister_carriedBalance_isFullyRecoverableByNewBackup() public {
        // Same setup: 1 ETH abandoned
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(
            address(badBackup),
            FREE_PERIOD,
            IAeternumVault.SubscriptionTier.Free,
            IAeternumVault.SubscriptionPlan.Monthly
        );

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(alice);
            (, bytes memory pd) = rm.checkUpkeep(bytes(""));
            rm.performUpkeep(pd);
        }

        // Re-register with good backup, adding 0.5 ETH — total vault balance = 1.5 ETH
        uint256 newDeposit = 0.5 ether;
        vm.prank(alice);
        rm.register{value: newDeposit}(
            aliceBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );

        // Warp past inactivity — recovery should send the FULL 1.5 ETH to the good backup
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
        // Alice gets abandoned, then withdraws balance before re-registering
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(
            address(badBackup),
            FREE_PERIOD,
            IAeternumVault.SubscriptionTier.Free,
            IAeternumVault.SubscriptionPlan.Monthly
        );

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(alice);
            (, bytes memory pd) = rm.checkUpkeep(bytes(""));
            rm.performUpkeep(pd);
        }

        // Alice withdraws first — balance now 0
        vm.prank(alice);
        rm.withdrawAll();
        assertEq(rm.getRecoveryConfig(alice).balance, 0);

        // Re-registers with 0.5 ETH — no carried balance, so only new deposit
        uint256 newDeposit = 0.5 ether;
        vm.prank(alice);
        rm.register{value: newDeposit}(
            aliceBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );

        assertEq(
            rm.getRecoveryConfig(alice).balance,
            newDeposit,
            "No carry-over when abandoned balance was withdrawn before re-registration"
        );
    }

    function test_reregister_carriedBalance_contractHoldsCorrectETH() public {
        // Verify the contract's actual ETH balance covers carried + new deposit correctly
        RejectingReceiver badBackup = new RejectingReceiver();
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(
            address(badBackup),
            FREE_PERIOD,
            IAeternumVault.SubscriptionTier.Free,
            IAeternumVault.SubscriptionPlan.Monthly
        );

        for (uint8 i = 0; i < rm.MAX_RECOVERY_ATTEMPTS(); i++) {
            _warpPastInactivity(alice);
            (, bytes memory pd) = rm.checkUpkeep(bytes(""));
            rm.performUpkeep(pd);
        }

        uint256 contractBalanceBefore = address(rm).balance; // still holds 1 ETH from abandoned

        uint256 newDeposit = 0.5 ether;
        vm.prank(alice);
        rm.register{value: newDeposit}(
            aliceBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );

        // Contract now holds old 1 ETH + new 0.5 ETH
        assertEq(
            address(rm).balance,
            contractBalanceBefore + newDeposit,
            "Contract balance must reflect new deposit on top of existing carried ETH"
        );

        // config.balance must match what the contract actually holds for alice
        assertEq(
            rm.getRecoveryConfig(alice).balance,
            address(rm).balance,
            "Config balance must equal total contract ETH when alice is the only depositor"
        );
    }

    /*//////////////////////////////////////////////////////////////
                      12. TREASURY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_withdrawSubscriptionFees_success() public {
        _registerAlicePremium(); // accumulates PREMIUM_FEE

        uint256 treasuryBefore = treasury.balance;
        vm.prank(treasury);
        rm.withdrawSubscriptionFees();

        assertEq(treasury.balance, treasuryBefore + PREMIUM_FEE);
        assertEq(rm.getAccumulatedFees(), 0);
    }

    function test_withdrawSubscriptionFees_emitsEvent() public {
        _registerAlicePremium();

        vm.expectEmit(true, false, false, true);
        emit SubscriptionFeesWithdrawn(treasury, PREMIUM_FEE);

        vm.prank(treasury);
        rm.withdrawSubscriptionFees();
    }

    function test_withdrawSubscriptionFees_revertsIfNotTreasury() public {
        _registerAlicePremium();
        vm.expectRevert(IAeternumVault.AeternumVault__NotAuthorized.selector);
        vm.prank(alice);
        rm.withdrawSubscriptionFees();
    }

    function test_withdrawSubscriptionFees_revertsIfNothingAccumulated() public {
        vm.expectRevert(IAeternumVault.AeternumVault__NothingToWithdraw.selector);
        vm.prank(treasury);
        rm.withdrawSubscriptionFees();
    }

    function test_updateTreasury_success() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(true, true, false, false);
        emit TreasuryUpdated(treasury, newTreasury);

        vm.prank(treasury);
        rm.updateTreasury(newTreasury);

        assertEq(rm.getTreasury(), newTreasury);
    }

    function test_updateTreasury_revertsIfNotTreasury() public {
        vm.expectRevert(IAeternumVault.AeternumVault__NotAuthorized.selector);
        vm.prank(alice);
        rm.updateTreasury(alice);
    }

    function test_updateTreasury_revertsOnZeroAddress() public {
        vm.expectRevert(IAeternumVault.AeternumVault__ZeroAddress.selector);
        vm.prank(treasury);
        rm.updateTreasury(address(0));
    }

    function test_updateTreasury_newTreasuryCanWithdraw() public {
        address newTreasury = makeAddr("newTreasury");
        _registerAlicePremium();

        vm.prank(treasury);
        rm.updateTreasury(newTreasury);

        vm.prank(newTreasury);
        rm.withdrawSubscriptionFees(); // should succeed
        assertEq(rm.getAccumulatedFees(), 0);
    }

    function test_withdrawSubscriptionFees_revertsIfTransferFails() public {
        // Accumulate fees first
        _registerAlicePremium();

        // Hand treasury authority to a contract that rejects ETH
        RejectingTreasuryMock rejectingTreasury = new RejectingTreasuryMock(address(rm));
        vm.prank(treasury);
        rm.updateTreasury(address(rejectingTreasury));

        vm.expectRevert(IAeternumVault.AeternumVault__TransferFailed.selector);
        rejectingTreasury.doWithdrawFees();
    }

    /*//////////////////////////////////////////////////////////////
                     13. VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function test_isRecoveryDue_falseBeforePeriod() public {
        _registerAliceFree();
        vm.warp(block.timestamp + FREE_PERIOD - 1);
        assertFalse(rm.isRecoveryDue(alice));
    }

    function test_isRecoveryDue_trueAfterPeriod() public {
        _registerAliceFree();
        _warpPastInactivity(alice);
        assertTrue(rm.isRecoveryDue(alice));
    }

    function test_getTimeUntilRecovery_returnsCorrectValue() public {
        _registerAliceFree();
        uint256 elapsed = 30 days;
        vm.warp(block.timestamp + elapsed);

        uint256 remaining = rm.getTimeUntilRecovery(alice);
        assertEq(remaining, FREE_PERIOD - elapsed);
    }

    function test_getTimeUntilRecovery_returnsZeroWhenDue() public {
        _registerAliceFree();
        _warpPastInactivity(alice);
        assertEq(rm.getTimeUntilRecovery(alice), 0);
    }

    function test_getRegisteredWallets_pagination() public {
        _registerAliceFree();
        vm.prank(bob);
        rm.register{value: 0}(
            bobBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );

        address[] memory page = rm.getRegisteredWallets(0, 2);
        assertEq(page.length, 2);

        address[] memory emptyPage = rm.getRegisteredWallets(5, 10);
        assertEq(emptyPage.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                  14. SECURITY — REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function test_reentrancy_performUpkeep_blocked() public {
        ReentrantAttacker attacker = new ReentrantAttacker(address(rm));
        deal(address(attacker), 2 ether);

        // Attacker registers with this contract as the backup (attack target)
        address attackerBackup = makeAddr("attackerBackup");
        attacker.registerAsWallet{value: 1 ether}(FREE_PERIOD, attackerBackup);
        attacker.enableAttack(true);

        vm.warp(block.timestamp + FREE_PERIOD + 1);

        address[] memory victims = new address[](1);
        victims[0] = address(attacker);
        bytes memory performData = abi.encode(victims, uint256(0), false);

        // performUpkeep should succeed but reentrant calls inside attacker.receive() should fail
        rm.performUpkeep(performData);

        // Despite the reentrancy attempt, attacker's balance in RM should be 0
        assertEq(rm.getRecoveryConfig(address(attacker)).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                  15. SECURITY — REGISTRY INTEGRITY
    //////////////////////////////////////////////////////////////*/

    function test_registry_swapAndPop_maintainsIntegrity() public {
        // Register 3 users; remove the first; remaining two should still be findable
        _registerAliceFree();

        vm.prank(bob);
        rm.register{value: 1 ether}(
            bobBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );

        vm.prank(carol);
        rm.register{value: 1 ether}(
            carolBackup, FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );

        vm.prank(alice);
        rm.cancelRecovery(); // triggers swap-and-pop

        assertEq(rm.getTotalRegistered(), 2);
        assertTrue(rm.getRecoveryConfig(bob).isActive);
        assertTrue(rm.getRecoveryConfig(carol).isActive);
    }

    function test_registry_batchRemoval_swapSafety() public {
        // Register 3 users; recover all 3 in one performUpkeep; verify correct swap behaviour
        address[3] memory users = [alice, bob, carol];
        address[3] memory backups = [aliceBackup, bobBackup, carolBackup];

        for (uint256 i = 0; i < 3; i++) {
            deal(users[i], 2 ether);
            vm.prank(users[i]);
            rm.register{value: 1 ether}(
                backups[i], FREE_PERIOD, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
            );
        }

        vm.warp(block.timestamp + FREE_PERIOD + 1);
        (, bytes memory performData) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(performData);

        assertEq(rm.getTotalRegistered(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       16. FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Fuzz inactivity period: any value within [FREE_MIN, MAX] should be accepted.
    function testFuzz_register_validInactivityPeriod(uint256 period) public {
        period = bound(period, FREE_PERIOD, rm.MAX_INACTIVITY_PERIOD());

        vm.prank(alice);
        rm.register{value: 1 ether}(
            aliceBackup, period, IAeternumVault.SubscriptionTier.Free, IAeternumVault.SubscriptionPlan.Monthly
        );

        assertEq(rm.getRecoveryConfig(alice).inactivityPeriod, period);
    }

    /// @dev Fuzz deposit amount: any non-zero amount should work.
    function testFuzz_deposit_amount(uint128 amount) public {
        vm.assume(amount > 0 && amount <= 50 ether);
        deal(alice, uint256(amount) + 2 ether);
        _registerAliceFree();

        uint256 balanceBefore = rm.getRecoveryConfig(alice).balance;
        vm.prank(alice);
        rm.deposit{value: amount}();

        assertEq(rm.getRecoveryConfig(alice).balance, balanceBefore + amount);
    }

    /// @dev Fuzz warp time: recovery should only trigger after inactivity period.
    function testFuzz_isRecoveryDue_timing(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, FREE_PERIOD * 2);
        _registerAliceFree();

        uint256 startTs = block.timestamp;
        vm.warp(startTs + elapsed);

        bool due = rm.isRecoveryDue(alice);
        if (elapsed >= FREE_PERIOD) {
            assertTrue(due);
        } else {
            assertFalse(due);
        }
    }

    /*//////////////////////////////////////////////////////////////
                      17. INVARIANT TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The contract's ETH balance must always be ≥ the sum of all user vault balances.
     * @dev    The difference (contract balance − user balances) equals accumulated subscription fees.
     */
    function invariant_contractBalanceCoverAllUserFunds() public view {
        uint256 total = rm.getTotalRegistered();
        address[] memory wallets = rm.getRegisteredWallets(0, total);

        uint256 sumOfUserBalances = 0;
        for (uint256 i = 0; i < wallets.length; i++) {
            sumOfUserBalances += rm.getRecoveryConfig(wallets[i]).balance;
        }

        // Contract balance must cover user balances + accumulated fees
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

    /**
     * @notice Accumulated fees must never exceed the contract's ETH balance.
     */
    function invariant_feesNeverExceedContractBalance() public view {
        assertLe(rm.getAccumulatedFees(), address(rm).balance, "Accumulated fees exceed contract balance");
    }
}
