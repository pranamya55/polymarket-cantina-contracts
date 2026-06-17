// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { OwnableRoles } from "@solady/src/auth/OwnableRoles.sol";
import { Initializable } from "@solady/src/utils/Initializable.sol";
import { SafeTransferLib } from "@solady/src/utils/SafeTransferLib.sol";
import { UUPSUpgradeable } from "@solady/src/utils/UUPSUpgradeable.sol";

import { BaseModule } from "@polymarket-v2/src/modules/abstract/BaseModule.sol";
import { NegRiskModule } from "@polymarket-v2/src/modules/NegRiskModule.sol";
import { ConditionId, EventId, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";

/// @title RouterEvents
/// @notice Events emitted by the Router.
abstract contract RouterEvents {
    /// @notice Emitted when collateral is split into YES/NO positions.
    /// @param initiator The address that initiated the split.
    /// @param conditionId The condition that was split.
    /// @param amount The amount of collateral that was split.
    event RouterPositionSplit(address indexed initiator, ConditionId indexed conditionId, uint256 amount);

    /// @notice Emitted when YES/NO positions are merged back into collateral.
    /// @param initiator The address that initiated the merge.
    /// @param conditionId The condition that was merged.
    /// @param amount The amount of each position that was merged.
    event RouterPositionsMerged(address indexed initiator, ConditionId indexed conditionId, uint256 amount);

    /// @notice Emitted when a position is redeemed for collateral payout.
    /// @param initiator The address that initiated the redemption.
    /// @param positionId The position that was redeemed.
    /// @param amount The amount of position that was redeemed.
    event RouterPositionRedeemed(address indexed initiator, PositionId indexed positionId, uint256 amount);

    /// @notice Emitted when collateral is split into YES positions across all neg-risk conditions.
    /// @param initiator The address that initiated the split.
    /// @param eventId The neg-risk event that was split.
    /// @param amount The amount of collateral that was split.
    event RouterHorizontalSplit(address indexed initiator, EventId indexed eventId, uint256 amount);

    /// @notice Emitted when YES positions across all neg-risk conditions are merged into collateral.
    /// @param initiator The address that initiated the merge.
    /// @param eventId The neg-risk event that was merged.
    /// @param amount The amount per condition that was merged.
    event RouterHorizontalMerge(address indexed initiator, EventId indexed eventId, uint256 amount);

    /// @notice Emitted when a NO position is converted into YES positions for all other conditions.
    /// @param initiator The address that initiated the conversion.
    /// @param eventId The neg-risk event.
    /// @param conditionIndex The condition whose NO was converted.
    /// @param amount The amount converted.
    event RouterPositionConverted(
        address indexed initiator, EventId indexed eventId, uint256 conditionIndex, uint256 amount
    );
}

/// @title RouterErrors
/// @notice Errors thrown by the Router.
abstract contract RouterErrors {
    /// @notice Thrown when an outcome index outside the valid binary range (0 or 1) is supplied.
    error InvalidOutcomeIndex();

    /// @notice Thrown when the initializer is invoked with the zero address as the owner.
    error InvalidOwner();
}

/// @title Router
/// @author Polymarket
/// @notice Entry point for split/merge/redeem and NegRisk horizontal operations.
/// @dev UUPS-upgradeable; owner authorizes upgrades. Immutables are bytecode-bound on the
///      implementation, so each implementation deployment is parameterized for one
///      (positionManager, collateralToken) pair.
contract Router is UUPSUpgradeable, Initializable, OwnableRoles, RouterEvents, RouterErrors {
    using SafeTransferLib for address;

    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice The PositionManager contract.
    PositionManager public immutable POSITION_MANAGER;

    /// @notice The collateral token address.
    address public immutable COLLATERAL_TOKEN;

    /// @dev Reserved storage gap for future Router state. Downstream inheritors (e.g.
    ///      `BridgeRouter`) begin their storage layout after slot 49.
    uint256[50] private __gap;

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Deploy the Router implementation
    /// @param _positionManager Address of the PositionManager contract
    constructor(address _positionManager) {
        POSITION_MANAGER = PositionManager(_positionManager);
        COLLATERAL_TOKEN = POSITION_MANAGER.COLLATERAL_TOKEN();

        _disableInitializers();
    }

    /*--------------------------------------------------------------
                             INITIALIZER
    --------------------------------------------------------------*/

    /// @notice Initializes the Router proxy with the given owner.
    /// @dev Replaces the constructor for proxy deployments. Owner authorizes upgrades.
    ///      Rejects the zero address explicitly because Solady's `_initializeOwner` would
    ///      otherwise silently set owner to zero and permanently brick the proxy. `onlyProxy`
    ///      adds defense in depth on top of `_disableInitializers()` in the constructor.
    /// @param _owner The address to set as the owner of the contract.
    function initialize(address _owner) external onlyProxy initializer {
        if (_owner == address(0)) revert InvalidOwner();
        _initializeOwner(_owner);
    }

    /*--------------------------------------------------------------
                         SPLIT / MERGE / REDEEM
    --------------------------------------------------------------*/

    /// @notice Split collateral into YES/NO positions
    /// @param _conditionId The condition to split on
    /// @param _amount Amount of collateral to split
    function split(ConditionId _conditionId, uint256 _amount) external {
        address moduleAddr = POSITION_MANAGER.moduleById(_conditionId.moduleId());

        // Transfer collateral from user to module
        COLLATERAL_TOKEN.safeTransferFrom(msg.sender, moduleAddr, _amount);

        // Build address[] without zero-init overhead.
        address[] memory to;
        assembly ("memory-safe") {
            to := mload(0x40)
            mstore(to, 2)
            mstore(add(to, 0x20), caller())
            mstore(add(to, 0x40), caller())
            mstore(0x40, add(to, 0x60))
        }

        BaseModule(moduleAddr).split(to, _conditionId, _amount);

        emit RouterPositionSplit(msg.sender, _conditionId, _amount);
    }

    /// @notice Merge YES/NO positions back into collateral
    /// @param _conditionId The condition to merge
    /// @param _amount Amount per position to merge
    function merge(ConditionId _conditionId, uint256 _amount) external {
        address moduleAddr = POSITION_MANAGER.moduleById(_conditionId.moduleId());

        PositionId positionId0 = _conditionId.computePositionId(0);
        PositionId positionId1 = _conditionId.computePositionId(1);
        POSITION_MANAGER.unsafeTransferFrom(msg.sender, moduleAddr, positionId0, _amount);
        POSITION_MANAGER.unsafeTransferFrom(msg.sender, moduleAddr, positionId1, _amount);

        BaseModule(moduleAddr).merge(msg.sender, _conditionId, _amount);

        emit RouterPositionsMerged(msg.sender, _conditionId, _amount);
    }

    /// @notice Redeem resolved position for collateral payout
    /// @dev Reverts with `InvalidOutcomeIndex` for values >= 2; the underlying position ID
    /// encoding would otherwise alias non-binary inputs (e.g. 256, 257) to outcomes 0 and 1.
    /// @param _conditionId The condition to redeem
    /// @param _outcomeIndex The outcome index (0=YES, 1=NO)
    /// @param _amount Amount of position to redeem
    function redeem(ConditionId _conditionId, uint256 _outcomeIndex, uint256 _amount) external {
        if (_outcomeIndex > 1) revert InvalidOutcomeIndex();
        PositionId positionId = _conditionId.computePositionId(_outcomeIndex);
        address moduleAddr = POSITION_MANAGER.moduleById(positionId.moduleId());

        POSITION_MANAGER.unsafeTransferFrom(msg.sender, moduleAddr, positionId, _amount);

        BaseModule(moduleAddr).redeem(msg.sender, positionId, _amount);

        emit RouterPositionRedeemed(msg.sender, positionId, _amount);
    }

    /*--------------------------------------------------------------
                         NEGRISK HORIZONTAL OPERATIONS
    --------------------------------------------------------------*/

    /// @notice Split collateral into YES positions across all real conditions and the synthetic Other
    /// @param _eventId The neg-risk event ID
    /// @param _amount Amount of collateral to split
    function horizontalSplit(EventId _eventId, uint256 _amount) external {
        address moduleAddr = POSITION_MANAGER.moduleById(_eventId.moduleId());
        COLLATERAL_TOKEN.safeTransferFrom(msg.sender, moduleAddr, _amount);
        NegRiskModule(moduleAddr).horizontalSplit(msg.sender, _eventId, _amount);

        emit RouterHorizontalSplit(msg.sender, _eventId, _amount);
    }

    /// @notice Merge YES positions across all real conditions and the synthetic Other into collateral
    /// @param _eventId The neg-risk event ID
    /// @param _amount Amount per condition to merge
    function horizontalMerge(EventId _eventId, uint256 _amount) external {
        address moduleAddr = POSITION_MANAGER.moduleById(_eventId.moduleId());
        uint256 conditionCount_ = NegRiskModule(moduleAddr).conditionCount(_eventId);
        PositionId[] memory positionIds = new PositionId[](conditionCount_ + 1);
        uint256[] memory amounts = new uint256[](conditionCount_ + 1);
        // Including the synthetic fallback condition
        for (uint256 i = 0; i <= conditionCount_; ++i) {
            positionIds[i] = _eventId.computeConditionId(i).computePositionId(0);
            amounts[i] = _amount;
        }

        POSITION_MANAGER.unsafeBatchTransferFrom(msg.sender, moduleAddr, positionIds, amounts);
        NegRiskModule(moduleAddr).horizontalMerge(msg.sender, _eventId, _amount);

        emit RouterHorizontalMerge(msg.sender, _eventId, _amount);
    }

    /// @notice Convert a NO position into YES positions for all other conditions.
    /// @dev `_conditionIndex` is typed `uint16` to mirror the 16-bit conditionIndex field in
    ///      position IDs (see `CONDITION_INDEX_MASK` in `Ids.sol`). Valid range is
    ///      `[0, conditionCount(eventId)]`, where `conditionCount` is the synthetic Other index.
    /// @param _eventId The neg-risk event ID.
    /// @param _conditionIndex Index of the condition whose NO to convert (0..65535).
    /// @param _amount Amount to convert
    function convert(EventId _eventId, uint16 _conditionIndex, uint256 _amount) external {
        address moduleAddr = POSITION_MANAGER.moduleById(_eventId.moduleId());
        ConditionId conditionId = _eventId.computeConditionId(_conditionIndex);
        PositionId noPositionId = conditionId.computePositionId(1);
        POSITION_MANAGER.unsafeTransferFrom(msg.sender, moduleAddr, noPositionId, _amount);

        NegRiskModule(moduleAddr).convert(msg.sender, _eventId, _conditionIndex, _amount);

        emit RouterPositionConverted(msg.sender, _eventId, _conditionIndex, _amount);
    }

    /*--------------------------------------------------------------
                       UUPS UPGRADE AUTHORIZATION
    --------------------------------------------------------------*/

    /// @dev Only the owner can authorize upgrades.
    function _authorizeUpgrade(address) internal override onlyOwner { }
}
