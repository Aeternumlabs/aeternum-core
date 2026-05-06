// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AeternumVault} from "../../src/AeternumVault.sol";
import {IAeternumVault} from "../../src/interfaces/IAeternumVault.sol";

/// @dev Registers itself in AeternumVault but rejects incoming ETH.
///      Used to trigger the TransferFailed branch in withdrawAll and cancelRecovery.
contract RejectingCallerMock {
    AeternumVault public vault;

    constructor(address vault_) {
        vault = AeternumVault(payable(vault_));
    }

    function doRegister(address backup, uint256 period) external payable {
        vault.register{value: msg.value}(backup, period, IAeternumVault.SubscriptionTier.Free);
    }

    function doWithdrawAll() external {
        vault.withdrawAll();
    }

    function doCancelRecovery() external {
        vault.cancelRecovery();
    }

    receive() external payable {
        revert("RejectingCallerMock: rejects ETH");
    }
}