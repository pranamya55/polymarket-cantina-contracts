// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Initializable } from "@solady/src/utils/Initializable.sol";
import { UUPSUpgradeable } from "@solady/src/utils/UUPSUpgradeable.sol";

import { ConditionId, EventId, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";

import { BaseModule } from "./abstract/BaseModule.sol";
import { NegRiskMigrationMixin } from "./migration/NegRiskMigrationMixin.sol";

/// @title NegRiskModuleEvents
/// @notice Events emitted by NegRiskModule.
abstract contract NegRiskModuleEvents {
    /// @notice Emitted when collateral is split into YES positions across every condition in an
    ///         event.
    /// @param initiator The address that initiated the horizontal split.
    /// @param eventId The neg-risk event that was split.
    /// @param recipient Recipient of the minted YES positions.
    /// @param amount Amount of collateral split.
    event HorizontalSplit(
        address indexed initiator, EventId indexed eventId, address indexed recipient, uint256 amount
    );

    /// @notice Emitted when YES positions across every condition in an event are merged back
    ///         into collateral.
    /// @param initiator The address that initiated the horizontal merge.
    /// @param eventId The neg-risk event that was merged.
    /// @param recipient Recipient of the minted collateral.
    /// @param amount Amount per condition merged.
    event HorizontalMerge(
        address indexed initiator, EventId indexed eventId, address indexed recipient, uint256 amount
    );

    /// @notice Emitted when a NO position is converted into YES positions for every other
    ///         condition in the event.
    /// @param initiator The address that initiated the conversion.
    /// @param eventId The neg-risk event.
    /// @param recipient Recipient of the minted YES positions.
    /// @param conditionIndex Index of the condition whose NO was burned.
    /// @param amount Amount converted.
    event PositionConverted(
        address indexed initiator,
        EventId indexed eventId,
        address indexed recipient,
        uint256 conditionIndex,
        uint256 amount
    );
}

/// @title NegRiskModule
/// @author Polymarket
/// @notice Unified module for neg-risk markets and legacy neg-risk migration
/// @dev Registered at moduleId=2 (NEGRISK)
///      ConditionId encodes:
///      [moduleId(8) | baseHash(128) | arity(16) | reserved(80) | conditionIndex(16) |
///      outcomeIndex(8)]
///      Neg-risk events use real condition indexes [0, arity) and a synthetic Other condition at
///      index arity.
contract NegRiskModule is UUPSUpgradeable, Initializable, BaseModule, NegRiskMigrationMixin, NegRiskModuleEvents {
    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice Event ID to cumulative results sum.
    /// @dev Typed `EventId` key: writes are structurally restricted to canonical event IDs.
    mapping(EventId => uint256) public resultsSum;

    /// @notice Event ID to number of resolved conditions.
    mapping(EventId => uint256) public conditionsResolved;

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Initialize the NegRiskModule contract
    /// @param _positionManager The PositionManager contract address
    /// @param _conditionalTokens The legacy CTF contract address
    /// @param _usdceToken The USDC.e token address
    /// @param _negRiskAdapter The legacy NegRisk adapter address
    constructor(address _positionManager, address _conditionalTokens, address _usdceToken, address _negRiskAdapter)
        BaseModule(_positionManager)
        NegRiskMigrationMixin(_conditionalTokens, _usdceToken, _negRiskAdapter)
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

    /// @notice Report result for a neg-risk condition.
    /// @dev Resolver callers may report real condition indexes only. Bridge callers may also
    ///      report the synthetic Other condition at index `eventId.arity()`.
    /// @param _conditionId The condition ID.
    /// @param _result The result array [yesValue, noValue] summing to RESULT_DENOMINATOR.
    function reportResult(ConditionId _conditionId, uint256[] calldata _result)
        external
        override
        onlyResolver(_conditionId)
    {
        if (result[_conditionId].length > 0) return;

        _finalizeNegriskResolution(_conditionId, _result);
    }

    /// @notice Force-resolve a real condition to NO once aggregate YES equals one.
    /// @dev Callable by anyone once `resultsSum[eventId] == RESULT_DENOMINATOR`. Reverts on
    ///      the synthetic Other condition (index `>= eventId.arity()`). Respects resolution
    ///      pause. For migrated conditions, routes through `_resolveMigrationCondition` so
    ///      legacy positions are redeemed and wcol is settled to the vault; requires the
    ///      legacy oracle to have reported the loser, otherwise reverts `ConditionNotResolved`.
    /// @param _conditionId The real condition ID to resolve to NO.
    function resolveConditionToNo(ConditionId _conditionId) external {
        if (_isMigrationCondition(_conditionId)) {
            _resolveMigrationCondition(_conditionId);
            return;
        }

        require(result[_conditionId].length == 0, ConditionAlreadyResolved());
        require(resolutionPausedAt[_conditionId] == 0, ResolutionIsPaused());

        // Will revert if the condition index >= arity
        (EventId eventId_,) = _validateConditionId(_conditionId);
        require(resultsSum[eventId_] == RESULT_DENOMINATOR, InvalidResults());

        uint256[] memory result_ = new uint256[](2);
        result_[1] = RESULT_DENOMINATOR;

        _storeResult(_conditionId, result_);

        conditionsResolved[eventId_] = conditionsResolved[eventId_] + 1;

        emit ResultReported(address(this), _conditionId, result_);
    }

    /*--------------------------------------------------------------
                        NEGRISK HORIZONTAL OPERATIONS
    --------------------------------------------------------------*/

    /// @notice Mint one YES position per real condition plus the synthetic Other, burn collateral.
    ///         Collateral must be pre-transferred to the module before calling.
    /// @param _to Recipient of the minted YES positions.
    /// @param _eventId The neg-risk event ID.
    /// @param _amount Amount of collateral to split.
    function horizontalSplit(address _to, EventId _eventId, uint256 _amount) external {
        (PositionId[] memory positionIds, uint256[] memory amounts) = _buildEventArrays(_eventId, _amount);

        POSITION_MANAGER.batchMint(_to, positionIds, amounts);

        COLLATERAL_TOKEN.burn(_amount);

        emit HorizontalSplit(msg.sender, _eventId, _to, _amount);
    }

    /// @notice Burn one YES position per real condition plus the synthetic Other, mint collateral.
    ///         Positions must be pre-transferred to the module before calling.
    /// @param _to Recipient of the minted collateral.
    /// @param _eventId The neg-risk event ID.
    /// @param _amount Amount per condition to merge.
    function horizontalMerge(address _to, EventId _eventId, uint256 _amount) external {
        (PositionId[] memory positionIds, uint256[] memory amounts) = _buildEventArrays(_eventId, _amount);

        COLLATERAL_TOKEN.mint(_to, _amount);

        POSITION_MANAGER.batchBurn(positionIds, amounts);

        emit HorizontalMerge(msg.sender, _eventId, _to, _amount);
    }

    /// @notice Convert a NO position into YES positions for all other conditions.
    /// @dev 1 NO(i) = all YES(j) for j != i, including the synthetic Other at index
    ///      `eventId.arity()`. NO position must be pre-transferred to the module before calling.
    /// @param _to Recipient for the YES positions.
    /// @param _eventId The event ID.
    /// @param _conditionIndex Real condition index in `[0, arity]` (Other at `arity`).
    /// @param _amount Amount to convert.
    function convert(address _to, EventId _eventId, uint256 _conditionIndex, uint256 _amount) external {
        uint256 conditionCount_ = _validateEventId(_eventId);
        // Including the synthetic fallback condition
        require(_conditionIndex <= conditionCount_, InvalidConditionIndex());

        ConditionId sourceConditionId = _eventId.computeConditionId(_conditionIndex);
        PositionId noPositionId = sourceConditionId.computePositionId(1);

        // Mint YES positions for all other conditions
        for (uint256 i = 0; i <= conditionCount_; ++i) {
            if (i == _conditionIndex) continue;
            PositionId yesPositionId = _eventId.computeConditionId(i).computePositionId(0);
            POSITION_MANAGER.mint(_to, yesPositionId, _amount);
        }

        POSITION_MANAGER.burn(noPositionId, _amount);

        emit PositionConverted(msg.sender, _eventId, _to, _conditionIndex, _amount);
    }

    /*--------------------------------------------------------------
                             MODULE IDENTITY
    --------------------------------------------------------------*/

    /// @notice Returns the module identifier for neg-risk markets
    /// @return The NEGRISK module ID constant
    function moduleId() external pure override returns (uint256) {
        return ModuleIds.NEGRISK;
    }

    /*--------------------------------------------------------------
                                 PUBLIC
    --------------------------------------------------------------*/

    /// @notice Get event ID from data
    /// @dev Uses conditionIndex=0 for the event root
    /// @param _conditionCount Number of conditions in the event
    /// @param _data Data used to derive the event ID
    /// @return The derived event ID
    function getEventId(uint256 _conditionCount, bytes calldata _data) public pure returns (EventId) {
        require(_conditionCount >= 2 && _conditionCount <= type(uint16).max, InvalidConditionCount());
        return EventIdLib.encodeFromData(ModuleIds.NEGRISK, _conditionCount, _data);
    }

    /// @notice Get condition count from a neg-risk event ID
    /// @param _eventId The event ID
    /// @return The decoded condition count, or 0 if the event ID is not a valid neg-risk event
    function conditionCount(EventId _eventId) public pure returns (uint256) {
        if (_eventId.moduleId() != ModuleIds.NEGRISK) return 0;

        uint256 conditionCount_ = _eventId.arity();
        if (conditionCount_ < 2 || conditionCount_ > type(uint16).max) return 0;

        return conditionCount_;
    }

    /*--------------------------------------------------------------
                                INTERNAL
    --------------------------------------------------------------*/

    /// @dev Builds the positionIds and amounts arrays shared by horizontalSplit and
    /// horizontalMerge.
    function _buildEventArrays(EventId _eventId, uint256 _amount)
        private
        pure
        returns (PositionId[] memory positionIds, uint256[] memory amounts)
    {
        // Increment by 1 to include the synthetic fallback condition
        uint256 conditionCount_ = _validateEventId(_eventId) + 1;

        positionIds = new PositionId[](conditionCount_);
        amounts = new uint256[](conditionCount_);

        for (uint256 i = 0; i < conditionCount_; ++i) {
            positionIds[i] = _eventId.computeConditionId(i).computePositionId(0);
            amounts[i] = _amount;
        }
    }

    function _validateEventId(EventId _eventId) private pure returns (uint256 conditionCount_) {
        conditionCount_ = conditionCount(_eventId);
        require(conditionCount_ != 0, InvalidEventId());
    }

    function _validateConditionId(ConditionId _conditionId)
        internal
        pure
        returns (EventId eventId_, uint256 conditionCount_)
    {
        eventId_ = _conditionId.eventId();
        conditionCount_ = _validateEventId(eventId_);
        require(_conditionId.conditionIndex() < conditionCount_, InvalidConditionIndex());
    }

    /// @dev Delegates to `_finalizeNegriskResolution`, overrides behavior from `BaseMigrationMixin`.
    function _finalizeMigrationResolution(ConditionId _conditionId, uint256[] memory _result) internal override {
        _finalizeNegriskResolution(_conditionId, _result);
    }

    /// @dev Shared resolution finalizer for oracle and migration paths. Bounds aggregate YES
    ///      with `resultsSum <= RESULT_DENOMINATOR`. Uses `<=` rather than strict equality so
    ///      legacy all-NO events remain resolvable. When every real condition is resolved or
    ///      aggregate YES reaches `RESULT_DENOMINATOR`, auto-derives the synthetic Other result
    ///      at index `eventId.arity()`.
    /// @param _conditionId The structured condition being resolved.
    /// @param _result The normalised payout vector (length 2, summing to RESULT_DENOMINATOR).
    function _finalizeNegriskResolution(ConditionId _conditionId, uint256[] memory _result) internal {
        EventId eventId_ = _conditionId.eventId();
        uint256 conditionCount_ = _validateEventId(eventId_);
        uint256 conditionIndex_ = _conditionId.conditionIndex();

        require(
            conditionIndex_ < conditionCount_
                || (conditionIndex_ == conditionCount_ && hasAllRoles(msg.sender, BRIDGE_ROLE)),
            InvalidConditionIndex()
        );

        // Store result
        _storeResult(_conditionId, _result);

        // Compute new results sum and conditions resolved
        uint256 resultsSum_ = resultsSum[eventId_] + _result[0];
        uint256 conditionsResolved_ = conditionsResolved[eventId_] + 1;

        require(resultsSum_ <= RESULT_DENOMINATOR, InvalidResults());

        // Update neg risk state
        conditionsResolved[eventId_] = conditionsResolved_;
        resultsSum[eventId_] = resultsSum_;

        emit ResultReported(msg.sender, _conditionId, _result);

        // Resolve fallback if we can
        ConditionId fallbackConditionId = eventId_.computeConditionId(conditionCount_);
        if (
            (conditionsResolved_ == conditionCount_ || resultsSum_ == RESULT_DENOMINATOR)
                && result[fallbackConditionId].length == 0
        ) {
            uint256[] memory fallbackResult = new uint256[](2);
            fallbackResult[0] = RESULT_DENOMINATOR - resultsSum_;
            fallbackResult[1] = resultsSum_;

            _storeResult(fallbackConditionId, fallbackResult);

            conditionsResolved[eventId_] = conditionsResolved_ + 1;
            resultsSum[eventId_] = RESULT_DENOMINATOR;

            emit ResultReported(address(this), fallbackConditionId, fallbackResult);
        }

        // After all conditions, including the synthetic fallback, we should sum to RESULT_DENOMINATOR
        // Enforces at least some valid combination of YESes occurred.
        if (conditionsResolved_ == conditionCount_ + 1) {
            require(resultsSum_ == RESULT_DENOMINATOR, InvalidResults());
        }
    }

    /*--------------------------------------------------------------
                          UUPS AUTHORIZATION
    --------------------------------------------------------------*/

    /// @dev Restricts upgrades to the owner and enforces immutable config compatibility.
    /// @param newImplementation The proposed implementation contract.
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        NegRiskModule newImpl = NegRiskModule(newImplementation);

        if (
            newImpl.moduleId() != ModuleIds.NEGRISK || address(newImpl.POSITION_MANAGER()) != address(POSITION_MANAGER)
                || address(newImpl.COLLATERAL_TOKEN()) != address(COLLATERAL_TOKEN)
                || address(newImpl.CONDITIONAL_TOKENS()) != address(CONDITIONAL_TOKENS) || newImpl.USDCE() != USDCE
                || address(newImpl.NEG_RISK_ADAPTER()) != address(NEG_RISK_ADAPTER)
        ) revert IncompatibleImplementation();
    }
}
