// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.15;

import { PositionId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title IPositionManagerModule
/// @author Polymarket
/// @notice Interface that all position manager modules must implement.
/// @dev Used by PositionManager to calculate payouts during redemption.
interface IPositionManagerModule {
    /// @notice Calculates the payout for a resolved position.
    /// @param _positionId The position ID to calculate payout for.
    /// @param _amount The amount of position tokens being redeemed.
    /// @return The collateral amount to pay out.
    function getPayout(PositionId _positionId, uint256 _amount) external view returns (uint256);
}
