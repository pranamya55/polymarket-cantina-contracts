// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IConditionalTokens } from "@polymarket-v2/src/legacy/interfaces/IConditionalTokens.sol";
import { CTHelpers } from "@polymarket-v2/src/legacy/libraries/CTHelpers.sol";
import { CTFHelpers } from "@polymarket-v2/src/legacy/libraries/CTFHelpers.sol";
import { ConditionId, ConditionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";

import { BaseMigrationMixin } from "./BaseMigrationMixin.sol";

/// @title BinaryMigrationMixin
/// @author Polymarket
/// @notice Migration logic for binary markets, handling legacy CTF condition preparation,
///         position migration, and resolution from legacy payouts.
abstract contract BinaryMigrationMixin is BaseMigrationMixin {
    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice The legacy Conditional Tokens Framework contract
    IConditionalTokens public immutable CONDITIONAL_TOKENS;

    /// @notice The USDC.e token address used as legacy collateral
    address public immutable USDCE;

    /// @notice Structured conditionId => legacy CTF conditionId
    /// @dev Typed `ConditionId` key: writes are structurally restricted to canonical condition IDs.
    mapping(ConditionId => bytes32) public legacyConditionId;

    /// @dev Reserved storage gap for future base upgrades.
    uint256[49] private __gap;

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Initialize legacy binary migration references
    /// @param _conditionalTokens The legacy CTF contract address
    /// @param _usdceToken The USDC.e token address
    constructor(address _conditionalTokens, address _usdceToken) {
        CONDITIONAL_TOKENS = IConditionalTokens(_conditionalTokens);
        USDCE = _usdceToken;
    }

    /*--------------------------------------------------------------
                              ONLY CREATOR
    --------------------------------------------------------------*/

    /// @notice Register a legacy binary condition for migration
    /// @param _legacyConditionId The legacy CTF conditionId
    function prepareMigrationCondition(bytes32 _legacyConditionId) external onlyCreator {
        require(address(CONDITIONAL_TOKENS) != address(0), MigrationNotSupported());
        require(CONDITIONAL_TOKENS.getOutcomeSlotCount(_legacyConditionId) == 2, MigrationNotSupported());

        ConditionId conditionId = _legacyConditionIdToConditionId(_legacyConditionId);

        require(legacyConditionId[conditionId] == bytes32(0), MigrationAlreadyRegistered());

        legacyConditionId[conditionId] = _legacyConditionId;

        emit MigrationConditionRegistered(conditionId, _legacyConditionId);
    }

    /*--------------------------------------------------------------
                                 PUBLIC
    --------------------------------------------------------------*/

    /// @notice Get structured condition ID from legacy condition ID
    /// @param _legacyConditionId The legacy CTF condition ID
    /// @return The structured condition ID for migration
    function getMigrationConditionId(bytes32 _legacyConditionId) public pure returns (bytes32) {
        return ConditionId.unwrap(_legacyConditionIdToConditionId(_legacyConditionId));
    }

    /// @notice Get legacy CTF position ID for CTF interaction
    /// @param _conditionId The structured condition ID
    /// @param _outcomeIndex The outcome index (0 or 1)
    /// @return 0 if not from a migrated condition
    function getLegacyPositionId(bytes32 _conditionId, uint256 _outcomeIndex) public view returns (uint256) {
        require(_outcomeIndex < 2, InvalidOutcomeIndex());
        bytes32 legacyConditionId_ = legacyConditionId[ConditionIdLib.from(_conditionId)];
        if (legacyConditionId_ == bytes32(0)) return 0;
        return CTHelpers.getPositionId(
            address(USDCE), CTHelpers.getCollectionId(bytes32(0), legacyConditionId_, _outcomeIndex + 1)
        );
    }

    /*--------------------------------------------------------------
                                INTERNAL
    --------------------------------------------------------------*/

    /// @dev Redeem legacy positions for underlying collateral
    /// @param _legacyConditionId The legacy conditional tokens condition ID
    function _redeemLegacyPositions(bytes32 _legacyConditionId) internal override {
        // forgefmt: disable-next-item
        CONDITIONAL_TOKENS.redeemPositions({
            collateralToken: address(USDCE),
            parentCollectionId: bytes32(0),
            conditionId: _legacyConditionId,
            indexSets: CTFHelpers.partition()
        });
    }

    /// @dev Resolves a structured binary condition to its legacy CTF condition ID
    function _getLegacyConditionIdForResolve(ConditionId _conditionId) internal view override returns (bytes32) {
        return legacyConditionId[_conditionId];
    }

    /*--------------------------------------------------------------
                        LEGACY MIGRATION HOOKS
    --------------------------------------------------------------*/

    /// @dev Checks if a condition has been registered for binary migration
    function _isMigrationCondition(ConditionId _conditionId) internal view override returns (bool) {
        return legacyConditionId[_conditionId] != bytes32(0);
    }

    /// @dev Returns the legacy CTF contract
    function _legacyConditionalTokens() internal view override returns (IConditionalTokens) {
        return CONDITIONAL_TOKENS;
    }

    /// @dev Returns USDC.e as the legacy collateral token
    function _legacyCollateralToken() internal view override returns (address) {
        return address(USDCE);
    }

    /// @dev Maps legacy condition ID to structured ID via ConditionIdLib.encode
    function _legacyConditionIdToConditionId(bytes32 _legacyConditionId) internal pure override returns (ConditionId) {
        return ConditionIdLib.encode(ModuleIds.BINARY, _legacyConditionId, 0, 0);
    }

    /// @dev Returns the USDC.e address for vault settlement
    function _usdce() internal view override returns (address) {
        return address(USDCE);
    }
}
