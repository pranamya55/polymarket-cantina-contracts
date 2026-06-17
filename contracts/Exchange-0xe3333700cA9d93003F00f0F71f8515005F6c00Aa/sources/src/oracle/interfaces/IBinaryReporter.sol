// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { ConditionId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title IBinaryReporter
/// @notice Interface for BinaryReporter from the PositionManager.
interface IBinaryReporter {
    /// @notice Report the result for a binary condition
    /// @param conditionId The condition identifier
    /// @param result Payout array [YES, NO] summing to RESULT_DENOMINATOR
    function reportResult(ConditionId conditionId, uint256[] calldata result) external;
}
