// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * @title  RejectingReceiver
 * @notice A mock contract that explicitly rejects all ETH transfers.
 *         Used to simulate a backup address that cannot receive ETH,
 *         testing the graceful failure path in _executeRecovery.
 */
contract RejectingReceiver {
    receive() external payable {
        revert("RejectingReceiver: ETH not accepted");
    }
}
