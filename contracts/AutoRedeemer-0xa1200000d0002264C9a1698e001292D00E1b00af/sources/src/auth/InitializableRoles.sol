// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { OwnableRoles } from "@solady/src/auth/OwnableRoles.sol";

/// @title InitializableRoles
/// @author Polymarket
/// @notice Abstract role-based access control for proxy-compatible (initializable) contracts
/// @dev Defines five roles: admin, operator, creator, bridge, and resolver.
///      Unlike Roles.sol, this contract has no constructor; the owner must be set via an
///      initializer in the inheriting contract. Admins can grant/revoke all roles.
abstract contract InitializableRoles is OwnableRoles {
    /*--------------------------------------------------------------
                               CONSTANTS
    --------------------------------------------------------------*/

    /// @dev Role flag for admin privileges.
    uint256 internal constant ADMIN_ROLE = _ROLE_0;

    /// @dev Role flag for operator privileges.
    uint256 internal constant OPERATOR_ROLE = _ROLE_1;

    /// @dev Role flag for creator privileges.
    uint256 internal constant CREATOR_ROLE = _ROLE_2;

    /// @dev Role flag for bridge privileges.
    uint256 internal constant BRIDGE_ROLE = _ROLE_3;

    /// @dev Role flag for resolver privileges.
    uint256 internal constant RESOLVER_ROLE = _ROLE_4;

    /*--------------------------------------------------------------
                               MODIFIERS
    --------------------------------------------------------------*/

    /// @dev Restricts access to addresses that hold the admin role.
    modifier onlyAdmin() {
        _checkRoles(ADMIN_ROLE);
        _;
    }

    /// @dev Restricts access to addresses that hold the operator role.
    modifier onlyOperator() {
        _checkRoles(OPERATOR_ROLE);
        _;
    }

    /// @dev Restricts access to addresses that hold the creator role.
    modifier onlyCreator() {
        _checkRoles(CREATOR_ROLE);
        _;
    }

    /*--------------------------------------------------------------
                                EXTERNAL
    --------------------------------------------------------------*/

    /// @notice Grant the admin role to an address
    /// @dev Only callable by the contract owner.
    /// @param _admin Address to receive the admin role
    function addAdmin(address _admin) external onlyOwner {
        _grantRoles(_admin, ADMIN_ROLE);
    }

    /// @notice Revoke the admin role from an address
    /// @dev Only callable by an existing admin.
    /// @param _admin Address to lose the admin role
    function removeAdmin(address _admin) external onlyAdmin {
        _removeRoles(_admin, ADMIN_ROLE);
    }

    /// @notice Grant the operator role to an address
    /// @dev Only callable by an admin.
    /// @param _operator Address to receive the operator role
    function addOperator(address _operator) external onlyAdmin {
        _grantRoles(_operator, OPERATOR_ROLE);
    }

    /// @notice Revoke the operator role from an address
    /// @dev Only callable by an admin.
    /// @param _operator Address to lose the operator role
    function removeOperator(address _operator) external onlyAdmin {
        _removeRoles(_operator, OPERATOR_ROLE);
    }

    /// @notice Grant the creator role to an address
    /// @dev Only callable by an admin.
    /// @param _creator Address to receive the creator role
    function addCreator(address _creator) external onlyAdmin {
        _grantRoles(_creator, CREATOR_ROLE);
    }

    /// @notice Revoke the creator role from an address
    /// @dev Only callable by an admin.
    /// @param _creator Address to lose the creator role
    function removeCreator(address _creator) external onlyAdmin {
        _removeRoles(_creator, CREATOR_ROLE);
    }
}
