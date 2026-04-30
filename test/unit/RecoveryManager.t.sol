// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {RecoveryManager} from "../../src/RecoveryManager.sol";
import {IRecoveryManager} from "../../src/interfaces/IRecoveryManager.sol";
import {ReentrantAttacker} from "../mocks/ReentrantAttacker.sol";

/**
 * @title  RecoveryManagerTest
 * @notice Comprehensive test suite for RecoveryManager.
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
contract RecoveryManagerTest is StdInvariant, Test {
    /*//////////////////////////////////////////////////////////////
                              TEST SETUP
    //////////////////////////////////////////////////////////////*/

    RecoveryManager public rm;

    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public aliceBackup = makeAddr("aliceBackup");
    address public bobBackup = makeAddr("bobBackup");
    address public carolBackup = makeAddr("carolBackup");

    uint256 public constant STARTING_BALANCE = 100 ether;
    uint256 public constant DEPOSIT_1_ETH = 1 ether;
    uint256 public constant FREE_PERIOD = 365 days;
    uint256 public constant PREMIUM_PERIOD = 180 days;
    uint256 public constant PREMIUM_FEE = 0.002 ether;

    event RecoveryRegistered(
        address indexed wallet,
        address indexed backupAddress,
        uint256 inactivityPeriod,
        IRecoveryManager.SubscriptionTier tier
    );
    event ActivityPinged(address indexed wallet, uint256 timestamp);
    event RecoveryExecuted(address indexed wallet, address indexed backupAddress, uint256 amount);
    event RecoveryCancelled(address indexed wallet, uint256 refundAmount);
    event Deposited(address indexed wallet, uint256 amount);
    event Sent(address indexed wallet, address indexed to, uint256 amount);
    event BackupAddressUpdated(address indexed wallet, address indexed newBackupAddress);
    event InactivityPeriodUpdated(address indexed wallet, uint256 newPeriod);
    event SubscriptionRenewed(address indexed wallet, IRecoveryManager.SubscriptionTier tier, uint256 expiresAt);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event SubscriptionFeesWithdrawn(address indexed treasury, uint256 amount);

    function setUp() public {
        rm = new RecoveryManager(treasury);

        deal(alice, STARTING_BALANCE);
        deal(bob, STARTING_BALANCE);
        deal(carol, STARTING_BALANCE);

        // Expose RecoveryManager as the invariant target
        targetContract(address(rm));
    }

    /*//////////////////////////////////////////////////////////////
                        HELPERS
    //////////////////////////////////////////////////////////////*/

    function _registerAliceFree() internal {
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(aliceBackup, FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);
    }

    function _registerAlicePremium() internal {
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH + PREMIUM_FEE}(
            aliceBackup, PREMIUM_PERIOD, IRecoveryManager.SubscriptionTier.Premium
        );
    }

    /// @dev Warp past alice's inactivity period.
    function _warpPastInactivity(address wallet) internal {
        IRecoveryManager.RecoveryConfig memory cfg = rm.getRecoveryConfig(wallet);
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
        vm.expectRevert(IRecoveryManager.RecoveryManager__ZeroAddress.selector);
        new RecoveryManager(address(0));
    }

    function test_constructor_initialState() public view {
        assertEq(rm.getTotalRegistered(), 0);
        assertEq(rm.getAccumulatedFees(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       2. REGISTER — SUCCESS PATHS
    //////////////////////////////////////////////////////////////*/

    function test_register_free_storesConfig() public {
        _registerAliceFree();

        IRecoveryManager.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertEq(cfg.backupAddress, aliceBackup);
        assertEq(cfg.inactivityPeriod, FREE_PERIOD);
        assertEq(cfg.balance, DEPOSIT_1_ETH);
        assertEq(cfg.lastActivity, block.timestamp);
        assertEq(uint256(cfg.tier), uint256(IRecoveryManager.SubscriptionTier.Free));
        assertEq(cfg.subscriptionExpiry, 0);
        assertTrue(cfg.isActive);
    }

    function test_register_free_incrementsRegistry() public {
        _registerAliceFree();
        assertEq(rm.getTotalRegistered(), 1);
    }

    function test_register_free_emitsEvents() public {
        vm.expectEmit(true, true, false, true);
        emit RecoveryRegistered(alice, aliceBackup, FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);

        vm.expectEmit(true, false, false, true);
        emit Deposited(alice, DEPOSIT_1_ETH);

        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(aliceBackup, FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);
    }

    function test_register_premium_storesConfig() public {
        _registerAlicePremium();

        IRecoveryManager.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertEq(cfg.balance, DEPOSIT_1_ETH); // fee excluded from balance
        assertEq(uint256(cfg.tier), uint256(IRecoveryManager.SubscriptionTier.Premium));
        assertEq(cfg.subscriptionExpiry, block.timestamp + 30 days);
    }

    function test_register_premium_accumulatesFee() public {
        _registerAlicePremium();
        assertEq(rm.getAccumulatedFees(), PREMIUM_FEE);
    }

    function test_register_withZeroDeposit_isValid() public {
        vm.prank(alice);
        rm.register{value: 0}(aliceBackup, FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);

        IRecoveryManager.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertEq(cfg.balance, 0);
        assertTrue(cfg.isActive);
    }

    function test_register_multipleUsers() public {
        _registerAliceFree();

        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(bobBackup, FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);

        assertEq(rm.getTotalRegistered(), 2);
    }

    /*//////////////////////////////////////////////////////////////
                      3. REGISTER — REVERT PATHS
    //////////////////////////////////////////////////////////////*/

    function test_register_revertsIfAlreadyRegistered() public {
        _registerAliceFree();

        vm.expectRevert(IRecoveryManager.RecoveryManager__AlreadyRegistered.selector);
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(aliceBackup, FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);
    }

    function test_register_revertsIfBackupIsZeroAddress() public {
        vm.expectRevert(IRecoveryManager.RecoveryManager__InvalidBackupAddress.selector);
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(address(0), FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);
    }

    function test_register_revertsIfBackupIsSelf() public {
        vm.expectRevert(IRecoveryManager.RecoveryManager__InvalidBackupAddress.selector);
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(alice, FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);
    }

    function test_register_free_revertsIfPeriodTooShort() public {
        vm.expectRevert(IRecoveryManager.RecoveryManager__InvalidInactivityPeriod.selector);
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(aliceBackup, FREE_PERIOD - 1, IRecoveryManager.SubscriptionTier.Free);
    }

    function test_register_premium_revertsIfPeriodTooShort() public {
        vm.expectRevert(IRecoveryManager.RecoveryManager__InvalidInactivityPeriod.selector);
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH + PREMIUM_FEE}(
            aliceBackup, PREMIUM_PERIOD - 1, IRecoveryManager.SubscriptionTier.Premium
        );
    }

    function test_register_revertsIfPeriodTooLong() public {
        uint256 tooLong = rm.MAX_INACTIVITY_PERIOD() + 1;
        vm.expectRevert(IRecoveryManager.RecoveryManager__InvalidInactivityPeriod.selector);
        vm.prank(alice);
        rm.register{value: DEPOSIT_1_ETH}(aliceBackup, tooLong, IRecoveryManager.SubscriptionTier.Free);
    }

    function test_register_premium_revertsIfFeeInsufficient() public {
        vm.expectRevert(IRecoveryManager.RecoveryManager__InsufficientSubscriptionFee.selector);
        vm.prank(alice);
        rm.register{value: PREMIUM_FEE - 1}(aliceBackup, PREMIUM_PERIOD, IRecoveryManager.SubscriptionTier.Premium);
    }

    function test_register_revertsOnDirectTransfer() public {
        vm.expectRevert(IRecoveryManager.RecoveryManager__DirectTransferNotAllowed.selector);
        vm.prank(alice);
        (bool sent,) = address(rm).call{value: 1 ether}("");
        (sent);
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
        vm.expectRevert(IRecoveryManager.RecoveryManager__NotRegistered.selector);
        vm.prank(alice);
        rm.deposit{value: 0.5 ether}();
    }

    function test_deposit_revertsIfZeroValue() public {
        _registerAliceFree();

        vm.expectRevert(IRecoveryManager.RecoveryManager__InsufficientBalance.selector);
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
        rm.register{value: 0}(aliceBackup, FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);

        vm.expectRevert(IRecoveryManager.RecoveryManager__NothingToWithdraw.selector);
        vm.prank(alice);
        rm.withdrawAll();
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
        vm.expectRevert(IRecoveryManager.RecoveryManager__InvalidBackupAddress.selector);
        vm.prank(alice);
        rm.send(address(0), 0.1 ether);
    }

    function test_send_revertsOnZeroAmount() public {
        _registerAliceFree();
        vm.expectRevert(IRecoveryManager.RecoveryManager__NothingToWithdraw.selector);
        vm.prank(alice);
        rm.send(makeAddr("recipient"), 0);
    }

    function test_send_revertsOnInsufficientBalance() public {
        _registerAliceFree();
        vm.expectRevert(IRecoveryManager.RecoveryManager__InsufficientBalance.selector);
        vm.prank(alice);
        rm.send(makeAddr("recipient"), DEPOSIT_1_ETH + 1);
    }

    function test_send_revertsIfNotRegistered() public {
        vm.expectRevert(IRecoveryManager.RecoveryManager__NotRegistered.selector);
        vm.prank(alice);
        rm.send(makeAddr("recipient"), 0.1 ether);
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
        vm.expectRevert(IRecoveryManager.RecoveryManager__NotRegistered.selector);
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
        vm.expectRevert(IRecoveryManager.RecoveryManager__InvalidBackupAddress.selector);
        vm.prank(alice);
        rm.updateBackupAddress(address(0));
    }

    function test_updateBackupAddress_revertsOnSelf() public {
        _registerAliceFree();
        vm.expectRevert(IRecoveryManager.RecoveryManager__InvalidBackupAddress.selector);
        vm.prank(alice);
        rm.updateBackupAddress(alice);
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
        vm.expectRevert(IRecoveryManager.RecoveryManager__InvalidInactivityPeriod.selector);
        vm.prank(alice);
        rm.updateInactivityPeriod(FREE_PERIOD - 1);
    }

    function test_updateInactivityPeriod_expiredPremiumEnforcesFreeMin() public {
        _registerAlicePremium();

        // Expire the subscription
        vm.warp(block.timestamp + 31 days);

        // Should now enforce FREE minimum
        vm.expectRevert(IRecoveryManager.RecoveryManager__InvalidInactivityPeriod.selector);
        vm.prank(alice);
        rm.updateInactivityPeriod(45 days); // 45 < 180 days free min
    }

    /*//////////////////////////////////////////////////////////////
                    8. SUBSCRIPTION RENEWAL
    //////////////////////////////////////////////////////////////*/

    function test_renewSubscription_upgradesFreeToPreimum() public {
        _registerAliceFree();

        vm.prank(alice);
        rm.renewSubscription{value: PREMIUM_FEE}();

        IRecoveryManager.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertEq(uint256(cfg.tier), uint256(IRecoveryManager.SubscriptionTier.Premium));
        assertEq(cfg.subscriptionExpiry, block.timestamp + 30 days);
    }

    function test_renewSubscription_extendsPremiumExpiry() public {
        _registerAlicePremium();
        uint256 currentExpiry = rm.getRecoveryConfig(alice).subscriptionExpiry;

        vm.prank(alice);
        rm.renewSubscription{value: PREMIUM_FEE}();

        assertEq(rm.getRecoveryConfig(alice).subscriptionExpiry, currentExpiry + 30 days);
    }

    function test_renewSubscription_accumulatesFees() public {
        _registerAliceFree();
        uint256 feesBefore = rm.getAccumulatedFees();

        vm.prank(alice);
        rm.renewSubscription{value: PREMIUM_FEE}();

        assertEq(rm.getAccumulatedFees(), feesBefore + PREMIUM_FEE);
    }

    function test_renewSubscription_revertsIfFeeInsufficient() public {
        _registerAliceFree();
        vm.expectRevert(IRecoveryManager.RecoveryManager__InsufficientSubscriptionFee.selector);
        vm.prank(alice);
        rm.renewSubscription{value: PREMIUM_FEE - 1}();
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
        rm.register{value: 0.5 ether}(aliceBackup, FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);
        assertTrue(rm.getRecoveryConfig(alice).isActive);
    }

    function test_cancelRecovery_revertsIfNotRegistered() public {
        vm.expectRevert(IRecoveryManager.RecoveryManager__NotRegistered.selector);
        vm.prank(alice);
        rm.cancelRecovery();
    }

    function test_cancelRecovery_withZeroBalance_noTransfer() public {
        vm.prank(alice);
        rm.register{value: 0}(aliceBackup, FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        rm.cancelRecovery();

        assertEq(alice.balance, ethBefore); // no ETH transferred
    }

    /*//////////////////////////////////////////////////////////////
                    10. CHECK UPKEEP
    //////////////////////////////////////////////////////////////*/

    function test_checkUpkeep_returnsFalseIfEmpty() public view {
        (bool needed,) = rm.checkUpkeep(bytes(""));
        assertFalse(needed);
    }

    function test_checkUpkeep_returnsFalseIfNotDue() public {
        _registerAliceFree();
        (bool needed,) = rm.checkUpkeep(bytes(""));
        assertFalse(needed);
    }

    function test_checkUpkeep_returnsTrueWhenDue() public {
        _registerAliceFree();
        _warpPastInactivity(alice);

        (bool needed, bytes memory performData) = rm.checkUpkeep(bytes(""));

        assertTrue(needed);
        address[] memory wallets = abi.decode(performData, (address[]));
        assertEq(wallets.length, 1);
        assertEq(wallets[0], alice);
    }

    function test_checkUpkeep_returnsFalseIfBalanceZero() public {
        vm.prank(alice);
        rm.register{value: 0}(aliceBackup, FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);
        _warpPastInactivity(alice);

        (bool needed,) = rm.checkUpkeep(bytes(""));
        assertFalse(needed); // zero balance → no recovery needed
    }

    function test_checkUpkeep_paginationFiltersCorrectly() public {
        // Register alice and bob; only bob is due
        _registerAliceFree();

        vm.prank(bob);
        rm.register{value: DEPOSIT_1_ETH}(bobBackup, FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);

        _warpPastInactivity(bob);

        // Check with pagination starting at index 1 (bob's position)
        bytes memory checkData = abi.encode(uint256(1), uint256(10));
        (bool needed, bytes memory performData) = rm.checkUpkeep(checkData);

        assertTrue(needed);
        address[] memory wallets = abi.decode(performData, (address[]));
        assertEq(wallets[0], bob);
    }

    function test_checkUpkeep_defaultBatchSizeCappedAtMax() public {
        // Register MAX_BATCH_SIZE + 1 wallets, all due
        for (uint256 i = 0; i < rm.MAX_BATCH_SIZE() + 1; i++) {
            address user = address(uint160(0xBEEF + i));
            address backup = address(uint160(0xDEAD + i));
            deal(user, 2 ether);
            vm.prank(user);
            rm.register{value: 1 ether}(backup, FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);
        }

        vm.warp(block.timestamp + FREE_PERIOD + 1);

        // With default empty checkData, should cap at MAX_BATCH_SIZE
        (, bytes memory performData) = rm.checkUpkeep(bytes(""));
        address[] memory wallets = abi.decode(performData, (address[]));
        assertEq(wallets.length, rm.MAX_BATCH_SIZE());
    }

    /*//////////////////////////////////////////////////////////////
                   11. PERFORM UPKEEP
    //////////////////////////////////////////////////////////////*/

    function test_performUpkeep_executesRecovery() public {
        _registerAliceFree();
        _warpPastInactivity(alice);

        (, bytes memory performData) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(performData);

        // Config should be inactive and balance zeroed
        IRecoveryManager.RecoveryConfig memory cfg = rm.getRecoveryConfig(alice);
        assertFalse(cfg.isActive);
        assertEq(cfg.balance, 0);
    }

    function test_performUpkeep_transfersETHtoBackup() public {
        _registerAliceFree();
        _warpPastInactivity(alice);

        uint256 backupBefore = aliceBackup.balance;
        (, bytes memory performData) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(performData);

        assertEq(aliceBackup.balance, backupBefore + DEPOSIT_1_ETH);
    }

    function test_performUpkeep_removesFromRegistry() public {
        _registerAliceFree();
        _warpPastInactivity(alice);

        (, bytes memory performData) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(performData);

        assertEq(rm.getTotalRegistered(), 0);
    }

    function test_performUpkeep_emitsRecoveryExecuted() public {
        _registerAliceFree();
        _warpPastInactivity(alice);

        (, bytes memory performData) = rm.checkUpkeep(bytes(""));

        vm.expectEmit(true, true, false, true);
        emit RecoveryExecuted(alice, aliceBackup, DEPOSIT_1_ETH);

        rm.performUpkeep(performData);
    }

    function test_performUpkeep_skipsAlreadyRecovered() public {
        _registerAliceFree();
        _warpPastInactivity(alice);

        (, bytes memory performData) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(performData);

        // Call again with the same (now stale) performData — should not revert
        rm.performUpkeep(performData);
        // Balance should still be 0
        assertEq(rm.getRecoveryConfig(alice).balance, 0);
    }

    function test_performUpkeep_skipsIfUserPingedAfterCheck() public {
        _registerAliceFree();
        _warpPastInactivity(alice);

        (, bytes memory performData) = rm.checkUpkeep(bytes(""));

        // Alice pings just before performUpkeep
        vm.prank(alice);
        rm.ping();

        // Should skip alice gracefully
        rm.performUpkeep(performData);

        // Alice's config should still be active with non-zero balance
        assertTrue(rm.getRecoveryConfig(alice).isActive);
        assertEq(rm.getRecoveryConfig(alice).balance, DEPOSIT_1_ETH);
    }

    function test_performUpkeep_revertsIfBatchTooLarge() public {
        uint256 overSize = rm.MAX_BATCH_SIZE() + 1;
        address[] memory tooMany = new address[](overSize);
        bytes memory performData = abi.encode(tooMany);

        vm.expectRevert(IRecoveryManager.RecoveryManager__MaxBatchSizeExceeded.selector);
        rm.performUpkeep(performData);
    }

    function test_performUpkeep_batchRecovery_multipleWallets() public {
        // Register three wallets
        address[3] memory users = [alice, bob, carol];
        address[3] memory backups = [aliceBackup, bobBackup, carolBackup];

        for (uint256 i = 0; i < 3; i++) {
            deal(users[i], 2 ether);
            vm.prank(users[i]);
            rm.register{value: DEPOSIT_1_ETH}(backups[i], FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);
        }

        vm.warp(block.timestamp + FREE_PERIOD + 1);

        (, bytes memory performData) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(performData);

        // All three should be recovered
        assertEq(rm.getTotalRegistered(), 0);
        for (uint256 i = 0; i < 3; i++) {
            assertFalse(rm.getRecoveryConfig(users[i]).isActive);
            assertEq(backups[i].balance, DEPOSIT_1_ETH);
        }
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
        vm.expectRevert(IRecoveryManager.RecoveryManager__NotAuthorized.selector);
        vm.prank(alice);
        rm.withdrawSubscriptionFees();
    }

    function test_withdrawSubscriptionFees_revertsIfNothingAccumulated() public {
        vm.expectRevert(IRecoveryManager.RecoveryManager__NothingToWithdraw.selector);
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
        vm.expectRevert(IRecoveryManager.RecoveryManager__NotAuthorized.selector);
        vm.prank(alice);
        rm.updateTreasury(alice);
    }

    function test_updateTreasury_revertsOnZeroAddress() public {
        vm.expectRevert(IRecoveryManager.RecoveryManager__ZeroAddress.selector);
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

    function test_isRegistered_returnsTrueWhenRegistered() public {
        _registerAliceFree();
        assertTrue(rm.isRegistered(alice));
    }

    function test_isRegistered_returnsFalseWhenNotRegistered() public view {
        assertFalse(rm.isRegistered(alice));
    }

    function test_isRegistered_returnsFalseAfterCancellation() public {
        _registerAliceFree();
        vm.prank(alice);
        rm.cancelRecovery();
        assertFalse(rm.isRegistered(alice));
    }

    function test_isRegistered_returnsFalseAfterRecoveryExecuted() public {
        _registerAliceFree();
        _warpPastInactivity(alice);

        (, bytes memory performData) = rm.checkUpkeep(bytes(""));
        rm.performUpkeep(performData);

        assertFalse(rm.isRegistered(alice));
    }

    function test_getRegisteredWallets_pagination() public {
        _registerAliceFree();
        vm.prank(bob);
        rm.register{value: 0}(bobBackup, FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);

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

        address attackerBackup = makeAddr("attackerBackup");

        attacker.registerAsWallet{value: 1 ether}(FREE_PERIOD, attackerBackup); // <-- pass backup
        attacker.enableAttack(true);

        vm.warp(block.timestamp + FREE_PERIOD + 1);

        address[] memory victims = new address[](1);
        victims[0] = address(attacker);
        bytes memory performData = abi.encode(victims);

        rm.performUpkeep(performData);

        assertEq(rm.getRecoveryConfig(address(attacker)).balance, 0);
    }
    /*//////////////////////////////////////////////////////////////
                  15. SECURITY — REGISTRY INTEGRITY
    //////////////////////////////////////////////////////////////*/

    function test_registry_swapAndPop_maintainsIntegrity() public {
        // Register 3 users; remove the first; remaining two should still be findable
        _registerAliceFree();

        vm.prank(bob);
        rm.register{value: 1 ether}(bobBackup, FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);

        vm.prank(carol);
        rm.register{value: 1 ether}(carolBackup, FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);

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
            rm.register{value: 1 ether}(backups[i], FREE_PERIOD, IRecoveryManager.SubscriptionTier.Free);
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
        rm.register{value: 1 ether}(aliceBackup, period, IRecoveryManager.SubscriptionTier.Free);

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
