// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { ERC1155TokenReceiver } from "@polymarket-v2/src/abstract/ERC1155TokenReceiver.sol";
import { CollateralToken } from "@polymarket-v2/src/collateral/CollateralToken.sol";
import { ConditionId, EventId, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { IPositionManagerModule } from "@polymarket-v2/src/positionManager/IPositionManagerModule.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";
import { IBinaryReporter } from "@polymarket-v2/src/oracle/interfaces/IBinaryReporter.sol";
import { ModuleErrors } from "./ModuleErrors.sol";
import { OracleModule } from "./OracleModule.sol";

/// @title BaseModuleEvents
/// @notice Events emitted by BaseModule and its derived contracts
abstract contract BaseModuleEvents {
    /// @notice Emitted when a resolver reports a result.
    /// @param resolver The resolver that reported.
    /// @param conditionId The structured condition ID.
    /// @param result The reported payout vector.
    event ResultReported(address indexed resolver, ConditionId indexed conditionId, uint256[] result);

    /// @notice Emitted when a condition is resolved.
    /// @param conditionId The structured condition ID.
    /// @param result The final payout vector.
    event ConditionResolved(ConditionId indexed conditionId, uint256[] result);

    /// @notice Emitted when collateral is split into YES and NO positions.
    /// @param initiator The address that initiated the split.
    /// @param conditionId The condition that was split.
    /// @param recipient0 Recipient of the YES position.
    /// @param recipient1 Recipient of the NO position.
    /// @param amount Amount of collateral split.
    event PositionsSplit(
        address indexed initiator,
        ConditionId indexed conditionId,
        address indexed recipient0,
        address recipient1,
        uint256 amount
    );

    /// @notice Emitted when YES and NO positions are merged back into collateral.
    /// @param initiator The address that initiated the merge.
    /// @param conditionId The condition that was merged.
    /// @param recipient Recipient of the minted collateral.
    /// @param amount Amount per position merged.
    event PositionsMerged(
        address indexed initiator, ConditionId indexed conditionId, address indexed recipient, uint256 amount
    );

    /// @notice Emitted when a resolved position is redeemed for its collateral payout.
    /// @param initiator The address that initiated the redemption.
    /// @param positionId The position ID redeemed.
    /// @param recipient Recipient of the collateral payout.
    /// @param amount Amount of position burned.
    /// @param payout Amount of collateral minted to `recipient`.
    event PositionRedeemed(
        address indexed initiator,
        PositionId indexed positionId,
        address indexed recipient,
        uint256 amount,
        uint256 payout
    );

    /// @notice Emitted when a bridge mints a position into the module.
    /// @param to The recipient address.
    /// @param positionId The minted position ID.
    /// @param amount The amount minted.
    event BridgePositionMinted(address indexed to, PositionId indexed positionId, uint256 amount);

    /// @notice Emitted when a bridge burns positions held by the module.
    /// @param positionIds The position IDs burned.
    /// @param amounts The amounts burned for each position.
    event BridgePositionsBurned(PositionId[] positionIds, uint256[] amounts);

    /// @notice Emitted when a neg-risk migration event is initialized
    /// @param eventId The structured event identifier
    /// @param conditionCount The number of conditions in the event
    /// @param legacyEventId The linked legacy neg-risk event identifier
    event EventPrepared(EventId indexed eventId, uint256 conditionCount, bytes32 legacyEventId);
}

/// @title BaseModule
/// @author Polymarket
/// @notice Abstract base for all position modules, providing split/merge/redeem logic and bridge
///         operations.
/// @dev Concrete modules must implement moduleId() and reportResult().
abstract contract BaseModule is
    OracleModule,
    ERC1155TokenReceiver,
    IPositionManagerModule,
    IBinaryReporter,
    BaseModuleEvents,
    ModuleErrors
{
    /*--------------------------------------------------------------
                            STATE VARIABLES
    --------------------------------------------------------------*/

    /// @dev Denominator used for payout calculations. Results are expressed as fractions of this
    /// value (e.g. 1_000_000 = 100%).
    uint256 internal constant RESULT_DENOMINATOR = 1_000_000;

    /// @notice The PositionManager contract used for minting and burning position tokens
    PositionManager public immutable POSITION_MANAGER;

    /// @notice The CollateralToken contract used for minting and burning collateral
    CollateralToken public immutable COLLATERAL_TOKEN;

    /// @notice Stored resolution results per condition: conditionId => result array
    /// @dev Typed `ConditionId` key: writes are structurally restricted to canonical IDs.
    ///      External ABI selector is unchanged because UDVTs encode as their underlying type.
    mapping(ConditionId => uint256[]) public result;

    /// @dev Reserved storage gap for future base upgrades.
    uint256[49] private __gap;

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Initializes the module with a PositionManager
    /// @dev Retrieves the CollateralToken address from the PositionManager
    /// @param _positionManager Address of the PositionManager contract
    constructor(address _positionManager) {
        POSITION_MANAGER = PositionManager(_positionManager);
        COLLATERAL_TOKEN = CollateralToken(POSITION_MANAGER.COLLATERAL_TOKEN());
    }

    /*--------------------------------------------------------------
                           PUBLIC FUNCTIONS
    --------------------------------------------------------------*/

    /// @notice Get the stored result array for a condition
    /// @dev Returns an empty array if the condition has not been resolved
    /// @param _conditionId The condition ID to query
    /// @return The result array (length 2 for resolved conditions, length 0 otherwise)
    function getResult(ConditionId _conditionId) public view virtual returns (uint256[] memory) {
        return result[_conditionId];
    }

    /// @notice Calculates the collateral payout for a resolved position
    /// @dev Extracts conditionId and outcomeIndex from the positionId, then computes
    ///      payout = _amount * result[outcomeIndex] / RESULT_DENOMINATOR.
    ///      Reverts if the outcome index is out of range or the condition is not resolved.
    /// @param _positionId The position ID encoding conditionId and outcomeIndex
    /// @param _amount The amount of position tokens being redeemed
    /// @return The collateral amount owed to the redeemer
    function getPayout(PositionId _positionId, uint256 _amount) public view virtual override returns (uint256) {
        ConditionId conditionId = _positionId.conditionId();
        uint256 outcomeIndex = _positionId.outcomeIndex();

        require(outcomeIndex < 2, InvalidOutcomeIndex());

        uint256[] memory result_ = result[conditionId];
        require(result_.length == 2, ConditionNotResolved());

        uint256 resultNumerator = result_[outcomeIndex];
        return _amount * resultNumerator / RESULT_DENOMINATOR;
    }

    /*--------------------------------------------------------------
                          EXTERNAL FUNCTIONS
    --------------------------------------------------------------*/

    /// @notice Get the module ID (used for cross-chain routing)
    /// @return The module's unique identifier (1 = Binary, 2 = NegRisk, etc.)
    function moduleId() external pure virtual returns (uint256);

    /// @notice Report result for a condition (implemented by concrete modules)
    /// @param _conditionId The condition ID
    /// @param _result The result array
    function reportResult(ConditionId _conditionId, uint256[] calldata _result) external virtual override;

    /*--------------------------------------------------------------
                          SPLIT / MERGE / REDEEM
    --------------------------------------------------------------*/

    /// @notice Split collateral into YES and NO positions. Collateral must be pre-transferred
    ///         to the module before calling.
    /// @param _to Recipients for [YES, NO] positions
    /// @param _conditionId The condition to split on
    /// @param _amount Amount of collateral to split
    function split(address[] calldata _to, ConditionId _conditionId, uint256 _amount) external virtual {
        require(_to.length == 2, InvalidArrayLength());

        PositionId positionId0 = _conditionId.computePositionId(0);
        PositionId positionId1 = _conditionId.computePositionId(1);

        POSITION_MANAGER.mint(_to[0], positionId0, _amount);
        POSITION_MANAGER.mint(_to[1], positionId1, _amount);

        COLLATERAL_TOKEN.burn(_amount);

        emit PositionsSplit(msg.sender, _conditionId, _to[0], _to[1], _amount);
    }

    /// @notice Merge YES and NO positions back into collateral. Positions must be
    ///         pre-transferred to the module before calling.
    /// @param _to Recipient for collateral
    /// @param _conditionId The condition to merge
    /// @param _amount Amount per position to merge
    function merge(address _to, ConditionId _conditionId, uint256 _amount) external virtual {
        PositionId positionId0 = _conditionId.computePositionId(0);
        PositionId positionId1 = _conditionId.computePositionId(1);

        COLLATERAL_TOKEN.mint(_to, _amount);

        POSITION_MANAGER.burn(positionId0, _amount);
        POSITION_MANAGER.burn(positionId1, _amount);

        emit PositionsMerged(msg.sender, _conditionId, _to, _amount);
    }

    /// @notice Redeem a resolved position for collateral payout. Position must be
    ///         pre-transferred to the module before calling.
    /// @param _to Recipient for collateral payout
    /// @param _positionId The position ID to redeem
    /// @param _amount Amount of position to redeem
    function redeem(address _to, PositionId _positionId, uint256 _amount) external virtual {
        uint256 payout = getPayout(_positionId, _amount);

        COLLATERAL_TOKEN.mint(_to, payout);

        POSITION_MANAGER.burn(_positionId, _amount);

        emit PositionRedeemed(msg.sender, _positionId, _to, _amount, payout);
    }

    /*--------------------------------------------------------------
                              ONLY BRIDGE
    --------------------------------------------------------------*/

    /// @notice Mint positions from bridge
    /// @dev Emits `BridgePositionMinted` only when `_amount > 0`; zero-amount calls are no-ops.
    /// @param _to Recipient address
    /// @param _positionId The position ID to mint
    /// @param _amount Amount to mint
    function mintFromBridge(address _to, PositionId _positionId, uint256 _amount) external virtual onlyBridge {
        if (_amount > 0) {
            POSITION_MANAGER.mint(_to, _positionId, _amount);
            emit BridgePositionMinted(_to, _positionId, _amount);
        }
    }

    /// @notice Burn positions from bridge
    /// @dev Positions must be transferred to this module first.
    /// @param _positionIds The position IDs to burn
    /// @param _amounts Amounts to burn
    function burnFromBridge(PositionId[] calldata _positionIds, uint256[] calldata _amounts)
        external
        virtual
        onlyBridge
    {
        POSITION_MANAGER.batchBurn(_positionIds, _amounts);

        emit BridgePositionsBurned(_positionIds, _amounts);
    }

    /// @notice Check if a condition has a result
    /// @param _conditionId The condition ID
    /// @return True if result has been stored
    function hasResult(ConditionId _conditionId) external view virtual returns (bool) {
        return result[_conditionId].length > 0;
    }

    /*--------------------------------------------------------------
                          INTERNAL FUNCTIONS
    --------------------------------------------------------------*/

    /// @notice Stores the resolution result for a condition
    /// @dev Validates that the result has exactly 2 outcomes and that the values sum to
    ///      RESULT_DENOMINATOR. Does NOT check for duplicate resolution — callers must
    ///      guard against already-resolved conditions. Emits ConditionResolved on success.
    /// @param _conditionId The condition to store the result for
    /// @param _result The result array of length 2, whose values must sum to RESULT_DENOMINATOR
    function _storeResult(ConditionId _conditionId, uint256[] memory _result) internal virtual {
        require(_result.length == 2, InvalidArrayLength());
        require(_result[0] + _result[1] == RESULT_DENOMINATOR, InvalidResults());

        result[_conditionId] = _result;

        emit ConditionResolved(_conditionId, _result);
    }
}
