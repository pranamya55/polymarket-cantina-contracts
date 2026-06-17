// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.15;

/// @title ModuleIds
/// @author Polymarket
/// @notice Constants for module identifiers used across the protocol
/// @dev Module IDs are used for cross-chain routing and module identification
library ModuleIds {
    /// @notice Binary market module ID
    uint256 internal constant BINARY = 1;

    /// @notice NegRisk (multi-outcome) market module ID
    uint256 internal constant NEGRISK = 2;

    /// @notice Combinatorial conjunction module ID
    uint256 internal constant COMBINATORIAL = 3;
}
