// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { InitializableRoles } from "@polymarket-v2/src/auth/InitializableRoles.sol";
import { ConditionId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title OracleModuleEvents
/// @notice Events emitted by the OracleModule
abstract contract OracleModuleEvents {
    /// @notice Emitted when a resolver is paused
    /// @param resolver The paused resolver address
    /// @param timestamp The block timestamp when paused
    event ResolverPaused(address indexed resolver, uint256 timestamp);
    /// @notice Emitted when a resolver is unpaused
    /// @param resolver The unpaused resolver address
    event ResolverUnpaused(address indexed resolver);
    /// @notice Emitted when resolution is paused for an id
    /// @param id The condition identifier
    /// @param timestamp The block timestamp when paused
    event ResolutionPaused(ConditionId indexed id, uint256 timestamp);
    /// @notice Emitted when resolution is unpaused for an id
    /// @param id The condition identifier
    event ResolutionUnpaused(ConditionId indexed id);
}

/// @title OracleModuleErrors
/// @notice Custom errors for the OracleModule
abstract contract OracleModuleErrors {
    /// @notice Thrown when the resolver is currently paused
    error ResolverIsPaused();
    /// @notice Thrown when resolution is currently paused for the id
    error ResolutionIsPaused();
}

/// @title OracleModule
/// @author Polymarket
/// @notice Role-based resolution controls with pause management for conditions
/// @dev Resolution is authorized by bridge or resolver role. No per-condition oracle assignment.
///      Pause controls operate on resolver addresses and condition IDs.
abstract contract OracleModule is InitializableRoles, OracleModuleEvents, OracleModuleErrors {
    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice Resolver address to the timestamp when it was paused.
    mapping(address => uint256) public resolverPausedAt;

    /// @notice Condition ID to the timestamp when paused.
    /// @dev Per-condition granularity only — no event-level pause. Passing an `EventId`
    ///      pauses subcondition 0; neg-risk events must be paused subcondition-by-subcondition.
    mapping(ConditionId => uint256) public resolutionPausedAt;

    /// @dev Reserved storage gap for future base upgrades.
    uint256[48] private __gap;

    /*--------------------------------------------------------------
                               MODIFIERS
    --------------------------------------------------------------*/

    /// @dev Restricts access to addresses that hold the bridge role.
    modifier onlyBridge() {
        _checkRoles(BRIDGE_ROLE);
        _;
    }

    /// @dev Restricts to bridge or resolver role; reverts if paused. Accepts a typed
    ///      `ConditionId` so non-canonical inputs are caught at the caller boundary; the
    ///      function body may revalidate as defense in depth.
    modifier onlyResolver(ConditionId _id) {
        require(hasAnyRole(msg.sender, BRIDGE_ROLE | RESOLVER_ROLE), Unauthorized());
        require(resolverPausedAt[msg.sender] == 0, ResolverIsPaused());
        require(resolutionPausedAt[_id] == 0, ResolutionIsPaused());
        _;
    }

    /*--------------------------------------------------------------
                               ONLY ADMIN
    --------------------------------------------------------------*/

    /// @notice Grant the bridge role to an address
    /// @dev Only callable by an admin.
    /// @param _bridge Address to receive the bridge role
    function addBridge(address _bridge) external onlyAdmin {
        _grantRoles(_bridge, BRIDGE_ROLE);
    }

    /// @notice Revoke the bridge role from an address
    /// @dev Only callable by an admin.
    /// @param _bridge Address to lose the bridge role
    function removeBridge(address _bridge) external onlyAdmin {
        _removeRoles(_bridge, BRIDGE_ROLE);
    }

    /// @notice Grant the resolver role to an address
    /// @dev Only callable by an admin. Used for oracle aggregators that report results.
    /// @param _resolver Address to receive the resolver role
    function addResolver(address _resolver) external onlyAdmin {
        _grantRoles(_resolver, RESOLVER_ROLE);
    }

    /// @notice Revoke the resolver role from an address
    /// @dev Only callable by an admin.
    /// @param _resolver Address to lose the resolver role
    function removeResolver(address _resolver) external onlyAdmin {
        _removeRoles(_resolver, RESOLVER_ROLE);
    }

    /// @notice Pause a resolver, blocking all its resolutions
    /// @param _resolver The resolver address to pause
    function pauseResolver(address _resolver) external onlyAdmin {
        resolverPausedAt[_resolver] = block.timestamp;

        emit ResolverPaused(_resolver, block.timestamp);
    }

    /// @notice Unpause a resolver, re-enabling its resolutions
    /// @param _resolver The resolver address to unpause
    function unpauseResolver(address _resolver) external onlyAdmin {
        resolverPausedAt[_resolver] = 0;

        emit ResolverUnpaused(_resolver);
    }

    /// @notice Pause resolution for a specific condition.
    /// @dev Per-condition only. Neg-risk events must be paused subcondition-by-subcondition;
    ///      passing an `EventId` pauses subcondition 0 alone.
    /// @param _id The condition identifier to pause
    function pauseResolution(ConditionId _id) external onlyAdmin {
        resolutionPausedAt[_id] = block.timestamp;

        emit ResolutionPaused(_id, block.timestamp);
    }

    /// @notice Unpause resolution for a specific condition.
    /// @dev Per-condition only; see `pauseResolution`.
    /// @param _id The condition identifier to unpause
    function unpauseResolution(ConditionId _id) external onlyAdmin {
        resolutionPausedAt[_id] = 0;

        emit ResolutionUnpaused(_id);
    }
}
