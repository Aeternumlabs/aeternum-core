// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AeternumVault} from "../../src/AeternumVault.sol";

/// @dev Acts as treasury — can call withdrawSubscriptionFees — but rejects incoming ETH.
///      Used to trigger the TransferFailed branch in withdrawSubscriptionFees.
contract RejectingTreasuryMock {
    AeternumVault public vault;

    constructor(address vault_) {
        vault = AeternumVault(payable(vault_));
    }

    function doWithdrawFees() external {
        vault.withdrawSubscriptionFees();
    }

    receive() external payable {
        revert("RejectingTreasuryMock: rejects ETH");
    }
}