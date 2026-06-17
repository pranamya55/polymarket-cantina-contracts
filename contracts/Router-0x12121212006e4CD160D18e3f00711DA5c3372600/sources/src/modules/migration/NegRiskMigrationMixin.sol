// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IConditionalTokens } from "@polymarket-v2/src/legacy/interfaces/IConditionalTokens.sol";
import { INegRiskAdapter } from "@polymarket-v2/src/legacy/interfaces/INegRiskAdapter.sol";
import { CTHelpers } from "@polymarket-v2/src/legacy/libraries/CTHelpers.sol";
import { CTFHelpers } from "@polymarket-v2/src/legacy/libraries/CTFHelpers.sol";
import { NegRiskIdLib } from "@polymarket-v2/src/legacy/libraries/NegRiskIdLib.sol";
import { ConditionId, EventId, EventIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";

import { BaseMigrationMixin } from "./BaseMigrationMixin.sol";

/// @title NegRiskMigrationErrors
/// @notice Custom errors specific to legacy NegRisk migration.
abstract contract NegRiskMigrationErrors {
    /// @notice Thrown when the legacy NegRisk event has more than 256 conditions.
    /// @dev The legacy NegRisk adapter encodes question indices as `uint8`, so
    ///      indices 0..255 (a count up to 256) fit without truncation; any
    ///      migration event exceeding 256 conditions cannot be safely indexed.
    error LegacyConditionCountTooLarge();

    /// @notice Thrown when the legacy NegRisk event has fewer than 2 conditions.
    /// @dev V2 neg-risk events require at least 2 conditions; single-question
    ///      legacy markets cannot be migrated because a 1-condition neg-risk
    ///      event is economically equivalent to a binary market and would
    ///      permit unbacked PMCT issuance via horizontal merge.
    error InsufficientConditionCount();
}

/// @title NegRiskMigrationMixin
/// @author Polymarket
/// @notice Migration logic for neg-risk markets, handling legacy NegRisk adapter event
///         preparation, position migration, and per-condition resolution from legacy payouts.
abstract contract NegRiskMigrationMixin is BaseMigrationMixin, NegRiskMigrationErrors {
    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice The legacy Conditional Tokens Framework contract
    IConditionalTokens public immutable CONDITIONAL_TOKENS;

    /// @notice The USDC.e token address used as legacy collateral
    address public immutable USDCE;

    /// @notice The legacy NegRisk adapter contract
    INegRiskAdapter public immutable NEG_RISK_ADAPTER;

    /// @dev The wrapped collateral token from the legacy NegRisk adapter
    address private immutable WRAPPED_COLLATERAL_TOKEN;

    /// @notice structured eventId => legacy eventId (stored once per event, not per condition)
    /// @dev Typed `EventId` key: writes are structurally restricted to canonical event IDs.
    mapping(EventId => bytes32) public legacyEventId;

    /// @notice legacy conditionId => structured conditionId (used for migration lookup)
    /// @dev Typed `ConditionId` value: returns are guaranteed canonical by construction.
    mapping(bytes32 => ConditionId) public legacyConditionToConditionId;

    /// @dev Reserved storage gap for future base upgrades.
    uint256[48] private __gap;

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Initialize legacy neg-risk migration references
    /// @param _conditionalTokens The legacy CTF contract address
    /// @param _usdceToken The USDC.e token address
    /// @param _negRiskAdapter The legacy NegRisk adapter address
    constructor(address _conditionalTokens, address _usdceToken, address _negRiskAdapter) {
        CONDITIONAL_TOKENS = IConditionalTokens(_conditionalTokens);
        USDCE = _usdceToken;
        NEG_RISK_ADAPTER = INegRiskAdapter(_negRiskAdapter);
        WRAPPED_COLLATERAL_TOKEN = _negRiskAdapter != address(0) ? INegRiskAdapter(_negRiskAdapter).wcol() : address(0);
    }

    /*--------------------------------------------------------------
                              ONLY CREATOR
    --------------------------------------------------------------*/

    /// @notice Register a legacy NegRisk event for migration
    /// @param _legacyEventId The legacy NegRisk adapter event ID
    /// @dev Do not add extra conditions to the old event after calling this method
    function prepareMigrationEvent(bytes32 _legacyEventId) external onlyCreator {
        require(address(NEG_RISK_ADAPTER) != address(0), MigrationNotSupported());
        uint256 conditionCount_ = NEG_RISK_ADAPTER.getQuestionCount(_legacyEventId);
        require(conditionCount_ > 0, EventNotPrepared());
        require(conditionCount_ >= 2, InsufficientConditionCount());
        require(conditionCount_ <= type(uint16).max, InvalidConditionCount());
        // The legacy NegRisk adapter encodes question indices as `uint8` via
        // `NegRiskIdLib.getQuestionId`. Indices 0..255 fit without truncation,
        // so the loop below (and `getLegacyConditionIdFromEvent`) can safely
        // handle up to 256 conditions; anything more would silently truncate.
        require(conditionCount_ <= 256, LegacyConditionCountTooLarge());

        EventId eventId_ = EventIdLib.encode(ModuleIds.NEGRISK, _legacyEventId, conditionCount_);
        require(legacyEventId[eventId_] == bytes32(0), EventAlreadyPrepared());

        legacyEventId[eventId_] = _legacyEventId;

        for (uint256 i = 0; i < conditionCount_; ++i) {
            ConditionId conditionId = eventId_.computeConditionId(i);
            bytes32 legacyConditionId_ = getLegacyConditionIdFromEvent(_legacyEventId, i);
            legacyConditionToConditionId[legacyConditionId_] = conditionId;
            emit MigrationConditionRegistered(conditionId, legacyConditionId_);
        }

        emit EventPrepared(eventId_, conditionCount_, _legacyEventId);
    }

    /*--------------------------------------------------------------
                          LEGACY MIGRATION VIEWS
    --------------------------------------------------------------*/

    /// @notice Get legacy CTF condition ID from legacy event ID
    /// @param _legacyEventId The legacy NegRisk event ID
    /// @param _conditionIndex The condition index within the event
    /// @return The legacy CTF condition ID
    function getLegacyConditionIdFromEvent(bytes32 _legacyEventId, uint256 _conditionIndex)
        internal
        view
        returns (bytes32)
    {
        bytes32 questionId = NegRiskIdLib.getQuestionId(_legacyEventId, uint8(_conditionIndex));
        return CTHelpers.getConditionId(address(NEG_RISK_ADAPTER), questionId, 2);
    }

    /// @notice Get legacy CTF condition ID from structured ID
    /// @param _conditionId The structured condition ID
    /// @return bytes32(0) if not from a migrated event
    function getLegacyConditionId(ConditionId _conditionId) internal view returns (bytes32) {
        EventId eventId_ = _conditionId.eventId();
        bytes32 legacyEventId_ = legacyEventId[eventId_];
        if (legacyEventId_ == bytes32(0)) return bytes32(0);

        uint256 conditionIndex = _conditionId.conditionIndex();
        if (conditionIndex >= eventId_.arity()) return bytes32(0);
        return getLegacyConditionIdFromEvent(legacyEventId_, conditionIndex);
    }

    /*--------------------------------------------------------------
                                INTERNAL
    --------------------------------------------------------------*/

    /// @dev Redeem legacy positions via the legacy CTF
    /// @param _legacyConditionId The legacy conditional tokens condition ID
    function _redeemLegacyPositions(bytes32 _legacyConditionId) internal override {
        // forgefmt: disable-next-item
        CONDITIONAL_TOKENS.redeemPositions({
            collateralToken: WRAPPED_COLLATERAL_TOKEN,
            parentCollectionId: bytes32(0),
            conditionId: _legacyConditionId,
            indexSets: CTFHelpers.partition()
        });
    }

    /// @dev Resolves a structured neg-risk condition to its legacy CTF condition ID
    function _getLegacyConditionIdForResolve(ConditionId _conditionId) internal view override returns (bytes32) {
        bytes32 legacyConditionId_ = getLegacyConditionId(_conditionId);
        require(legacyConditionId_ != bytes32(0), MigrationNotRegistered());
        return legacyConditionId_;
    }

    /*--------------------------------------------------------------
                        LEGACY MIGRATION HOOKS
    --------------------------------------------------------------*/

    /// @dev Returns the legacy CTF contract
    function _legacyConditionalTokens() internal view override returns (IConditionalTokens) {
        return CONDITIONAL_TOKENS;
    }

    /// @dev Returns the wrapped collateral token from the legacy adapter
    function _legacyCollateralToken() internal view override returns (address) {
        return WRAPPED_COLLATERAL_TOKEN;
    }

    /// @dev Looks up structured condition ID from legacy condition ID
    function _legacyConditionIdToConditionId(bytes32 _legacyConditionId) internal view override returns (ConditionId) {
        return legacyConditionToConditionId[_legacyConditionId];
    }

    /// @dev Returns the USDC.e address for vault settlement
    function _usdce() internal view override returns (address) {
        return address(USDCE);
    }

    /// @dev Checks if a condition has been registered for neg-risk migration
    function _isMigrationCondition(ConditionId _conditionId) internal view override returns (bool) {
        EventId eventId_ = _conditionId.eventId();
        return legacyEventId[eventId_] != bytes32(0) && _conditionId.conditionIndex() < eventId_.arity();
    }

    /// @dev Checks if an event has been registered for neg-risk migration
    function _isMigrationEvent(EventId _eventId) internal view returns (bool) {
        return legacyEventId[_eventId] != bytes32(0);
    }
}
