// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Sourced from: https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.8/automation/AutomationCompatible.sol
// Inlined to avoid heavy Chainlink monorepo dependency. Interface is stable and unlikely to change.

interface AutomationCompatibleInterface {
    /**
     * @notice Called by Chainlink Automation infrastructure to determine whether
     *         `performUpkeep` should be called.
     * @dev Simulation occurs off-chain; do not rely on gas costs here.
     * @param checkData  Arbitrary bytes registered with the upkeep.
     * @return upkeepNeeded  True if `performUpkeep` should be called.
     * @return performData   Arbitrary bytes passed to `performUpkeep`.
     */
    function checkUpkeep(bytes calldata checkData) external returns (bool upkeepNeeded, bytes memory performData);

    /**
     * @notice Called by Chainlink Automation infrastructure to trigger work.
     * @param performData  The bytes returned by `checkUpkeep`.
     */
    function performUpkeep(bytes calldata performData) external;
}
