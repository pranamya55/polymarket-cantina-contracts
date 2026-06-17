// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Initializable } from "@solady/src/utils/Initializable.sol";
import { UUPSUpgradeable } from "@solady/src/utils/UUPSUpgradeable.sol";

import { ConditionId, ConditionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";

import { BaseModule } from "./abstract/BaseModule.sol";
import { BinaryMigrationMixin } from "./migration/BinaryMigrationMixin.sol";

/// @title BinaryModule
/// @author Polymarket
/// @notice Unified module for binary markets and legacy binary migration
/// @dev Registered at moduleId=1 (BINARY)
///      ConditionId encodes:
///      [moduleId(8) | baseHash(128) | arity(16) | reserved(80) | conditionIndex(16) |
///      outcomeIndex(8)]
///      Binary conditions use arity = 0, reserved = 0, conditionIndex = 0, outcomeIndex = 0.
contract BinaryModule is UUPSUpgradeable, Initializable, BaseModule, BinaryMigrationMixin {
    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Initialize the BinaryModule contract
    /// @param _positionManager The PositionManager contract address
    /// @param _conditionalTokens The legacy CTF contract address
    /// @param _usdceToken The USDC.e token address
    constructor(address _positionManager, address _conditionalTokens, address _usdceToken)
        BaseModule(_positionManager)
        BinaryMigrationMixin(_conditionalTokens, _usdceToken)
    {
        _disableInitializers();
    }

    /*--------------------------------------------------------------
                             INITIALIZER
    --------------------------------------------------------------*/

    /// @notice Initializes the proxied module owner and admin.
    /// @param _owner The owner address.
    /// @param _admin The initial admin address.
    function initialize(address _owner, address _admin) external initializer {
        _initializeOwner(_owner);
        _grantRoles(_admin, _ROLE_0);
    }

    /*--------------------------------------------------------------
                              ONLY RESOLVER
    --------------------------------------------------------------*/

    /// @notice Report result for a binary condition
    /// @param _conditionId The condition ID to report on
    /// @param _result The result array [yes, no] summing to 1e6
    function reportResult(ConditionId _conditionId, uint256[] calldata _result)
        external
        override
        onlyResolver(_conditionId)
    {
        if (result[_conditionId].length > 0) return;

        _storeResult(_conditionId, _result);

        emit ResultReported(msg.sender, _conditionId, _result);
    }

    /*--------------------------------------------------------------
                             MODULE IDENTITY
    --------------------------------------------------------------*/

    /// @notice Returns the module identifier for binary markets
    /// @return The BINARY module ID constant
    function moduleId() external pure override returns (uint256) {
        return ModuleIds.BINARY;
    }

    /*--------------------------------------------------------------
                                 PUBLIC
    --------------------------------------------------------------*/

    /// @notice Get condition ID from data
    /// @dev Uses conditionIndex=0 for binary
    /// @param _data Data used to derive the condition ID
    /// @return The derived condition ID
    function getConditionId(bytes calldata _data) public pure returns (ConditionId) {
        return ConditionIdLib.encodeFromData(ModuleIds.BINARY, 0, _data);
    }

    /*--------------------------------------------------------------
                          UUPS AUTHORIZATION
    --------------------------------------------------------------*/

    /// @dev Restricts upgrades to the owner and enforces immutable config compatibility.
    /// @param newImplementation The proposed implementation contract.
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        BinaryModule newImpl = BinaryModule(newImplementation);

        if (
            newImpl.moduleId() != ModuleIds.BINARY || address(newImpl.POSITION_MANAGER()) != address(POSITION_MANAGER)
                || address(newImpl.COLLATERAL_TOKEN()) != address(COLLATERAL_TOKEN)
                || address(newImpl.CONDITIONAL_TOKENS()) != address(CONDITIONAL_TOKENS) || newImpl.USDCE() != USDCE
        ) revert IncompatibleImplementation();
    }
}
