// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Initializable } from "@solady/src/utils/Initializable.sol";
import { UUPSUpgradeable } from "@solady/src/utils/UUPSUpgradeable.sol";
import { FixedPointMathLib } from "@solady/src/utils/FixedPointMathLib.sol";

import { ERC1155TokenReceiver } from "@polymarket-v2/src/abstract/ERC1155TokenReceiver.sol";
import { InitializableRoles } from "@polymarket-v2/src/auth/InitializableRoles.sol";
import { CollateralToken } from "@polymarket-v2/src/collateral/CollateralToken.sol";
import { ConditionId, ConditionIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";
import { BaseModule } from "@polymarket-v2/src/modules/abstract/BaseModule.sol";
import { IPositionManagerModule } from "@polymarket-v2/src/positionManager/IPositionManagerModule.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";

/// @title CombinatorialModuleErrors
/// @notice Custom errors for CombinatorialModule operations.
abstract contract CombinatorialModuleErrors {
    /// @notice Thrown when the condition array is empty or otherwise invalid.
    error InvalidConditionSet();
    /// @notice Thrown when two conditions share the same conditionId with different outcomes.
    error ConflictingConditions();
    /// @notice Thrown when the condition is already present in the parent combinatorial position.
    error MarketAlreadyPresent();
    /// @notice Thrown when the condition array is not in ascending order or has duplicates.
    error NonCanonicalInput();
    /// @notice Thrown when not all conditions are resolved for redemption.
    error PositionNotRedeemable();
    /// @notice Thrown when a condition references an unsupported module (not binary or negrisk).
    error InvalidConditionModule();
    /// @notice Thrown when the combinatorial condition array has not been stored.
    error ConditionNotPrepared();
    /// @notice Thrown when unwrap/wrap requires exactly one condition but found more.
    error SingleConditionRequired();
    /// @notice Thrown when array lengths do not match or are invalid.
    error InvalidArrayLength();
    /// @notice Thrown when a condition has an invalid outcome index (not 0 or 1).
    error InvalidOutcomeIndex();
    /// @notice Thrown when the condition index is out of range.
    error ConditionIndexOutOfRange();
    /// @notice Thrown when no conditions were compressible.
    error PositionNotCompressible();
    /// @notice Thrown when a proposed upgrade has incompatible immutables.
    error IncompatibleImplementation();
}

/// @title CombinatorialModuleEvents
/// @notice Events emitted by CombinatorialModule.
abstract contract CombinatorialModuleEvents {
    /// @notice Emitted when a bridge mints a combinatorial position into the module.
    /// @param to The recipient address.
    /// @param positionId The minted position ID.
    /// @param amount The amount minted.
    event BridgePositionMinted(address indexed to, PositionId indexed positionId, uint256 amount);

    /// @notice Emitted when a bridge burns combinatorial positions held by the module.
    /// @param positionIds The position IDs burned.
    /// @param amounts The amounts burned for each position.
    event BridgePositionsBurned(PositionId[] positionIds, uint256[] amounts);

    /// @notice Emitted when a new combinatorial condition set is stored.
    /// @param conditionId The combinatorial condition ID.
    /// @param legs The canonical leg array.
    event CombinatorialConditionPrepared(ConditionId indexed conditionId, PositionId[] legs);

    /// @notice Emitted when collateral is split into YES + NO combinatorial positions.
    /// @param initiator The address that initiated the split.
    /// @param conditionId The combinatorial condition ID.
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

    /// @notice Emitted when YES + NO combinatorial positions are merged into collateral.
    /// @param initiator The address that initiated the merge.
    /// @param conditionId The combinatorial condition ID.
    /// @param recipient Recipient of the minted collateral.
    /// @param amount Amount per position merged.
    event PositionsMerged(
        address indexed initiator, ConditionId indexed conditionId, address indexed recipient, uint256 amount
    );

    /// @notice Emitted when a YES combinatorial position is split on a new condition.
    /// @param user The caller address.
    /// @param parentConditionId The parent combinatorial condition ID.
    /// @param childYesConditionId The child YES combinatorial condition ID.
    /// @param childNoConditionId The child NO combinatorial condition ID.
    /// @param amount The amount split.
    event SplitOnCondition(
        address indexed user,
        ConditionId indexed parentConditionId,
        ConditionId childYesConditionId,
        ConditionId childNoConditionId,
        uint256 amount
    );

    /// @notice Emitted when two child YES combinatorial positions are merged back into a parent.
    /// @param user The caller address.
    /// @param parentConditionId The parent combinatorial condition ID.
    /// @param childYesConditionId The child YES combinatorial condition ID.
    /// @param childNoConditionId The child NO combinatorial condition ID.
    /// @param amount The amount merged.
    event MergedOnCondition(
        address indexed user,
        ConditionId indexed parentConditionId,
        ConditionId childYesConditionId,
        ConditionId childNoConditionId,
        uint256 amount
    );

    /// @notice Emitted when a condition is extracted from a NO combinatorial position.
    /// @param user The caller address.
    /// @param fullConditionId The full NO combinatorial condition ID (input).
    /// @param reducedConditionId The reduced NO combinatorial condition ID (output).
    /// @param residualConditionId The residual YES combinatorial condition ID (output).
    /// @param amount The amount extracted.
    event Extracted(
        address indexed user,
        ConditionId indexed fullConditionId,
        ConditionId reducedConditionId,
        ConditionId residualConditionId,
        uint256 amount
    );

    /// @notice Emitted when a condition is injected back into a NO combinatorial position.
    /// @param user The caller address.
    /// @param fullConditionId The full NO combinatorial condition ID (output).
    /// @param reducedConditionId The reduced NO combinatorial condition ID (input).
    /// @param residualConditionId The residual YES combinatorial condition ID (input).
    /// @param amount The amount injected.
    event Injected(
        address indexed user,
        ConditionId indexed fullConditionId,
        ConditionId reducedConditionId,
        ConditionId residualConditionId,
        uint256 amount
    );

    /// @notice Emitted when a NO combinatorial position is converted into its canonical YES basket.
    /// @param user The caller address.
    /// @param fullConditionId The full NO combinatorial condition ID.
    /// @param amount The amount converted.
    event ConvertedToYesBasket(address indexed user, ConditionId indexed fullConditionId, uint256 amount);

    /// @notice Emitted when the canonical YES basket is merged back into a NO combinatorial position.
    /// @param user The caller address.
    /// @param fullConditionId The reconstructed NO combinatorial condition ID.
    /// @param amount The amount merged.
    event MergedFromYesBasket(address indexed user, ConditionId indexed fullConditionId, uint256 amount);

    /// @notice Emitted when a combinatorial position is compressed after resolution.
    /// @param user The caller address.
    /// @param oldPositionId The input position ID.
    /// @param newPositionId The output position ID (0 if no output position).
    /// @param amount The amount of the input position burned.
    /// @param positionAmount The amount of the new position minted (0 if fully resolved).
    /// @param collateralOut The amount of collateral redeemed.
    event Compressed(
        address indexed user,
        PositionId indexed oldPositionId,
        PositionId indexed newPositionId,
        uint256 amount,
        uint256 positionAmount,
        uint256 collateralOut
    );

    /// @notice Emitted when a fully resolved combinatorial position is redeemed.
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

    /// @notice Emitted when a single-condition combinatorial position is unwrapped to an underlying position.
    /// @param user The caller address.
    /// @param combinatorialPositionId The combinatorial position ID burned.
    /// @param underlyingPositionId The underlying position ID minted.
    /// @param amount The amount converted.
    event Unwrapped(
        address indexed user, PositionId combinatorialPositionId, PositionId underlyingPositionId, uint256 amount
    );

    /// @notice Emitted when an underlying position is wrapped into a single-condition combinatorial position.
    /// @param user The caller address.
    /// @param underlyingPositionId The underlying position ID burned.
    /// @param combinatorialPositionId The combinatorial position ID minted.
    /// @param amount The amount converted.
    event Wrapped(
        address indexed user, PositionId underlyingPositionId, PositionId combinatorialPositionId, uint256 amount
    );
}

/// @title CombinatorialModule
/// @author Polymarket
/// @notice Module for multi-leg conjunction positions. A YES combinatorial position is a conjunction
///         of underlying binary/negrisk position conditions. A NO combinatorial position is its complement. Supports
///         split, merge, refinement, extraction, compression, redemption, and wrap/unwrap.
/// @dev Registered as moduleId=3. Requires crossModuleAuth on PositionManager for wrap/unwrap.
///      Requires MINTER_ROLE on CollateralToken for mint/burn of collateral.
contract CombinatorialModule is
    UUPSUpgradeable,
    Initializable,
    InitializableRoles,
    ERC1155TokenReceiver,
    IPositionManagerModule,
    CombinatorialModuleEvents,
    CombinatorialModuleErrors
{
    /*--------------------------------------------------------------
                              CONSTANTS
    --------------------------------------------------------------*/

    /// @dev Denominator used for payout calculations (1_000_000 = 100%).
    uint256 internal constant RESULT_DENOMINATOR = 1_000_000;

    /// @dev High-precision accumulator scale for products of payout numerators.
    uint256 internal constant PAYOUT_FACTOR_DENOMINATOR = 1e36;

    /// @dev Maximum number of legs in a combinatorial position.
    uint256 internal constant MAX_LEGS = 50;

    /*--------------------------------------------------------------
                            STATE VARIABLES
    --------------------------------------------------------------*/

    /// @notice The PositionManager contract used for minting and burning position tokens.
    PositionManager public immutable POSITION_MANAGER;

    /// @notice The CollateralToken contract used for minting and burning collateral.
    CollateralToken public immutable COLLATERAL_TOKEN;

    /// @notice Stored canonical leg arrays per combinatorial condition.
    mapping(ConditionId => PositionId[]) public legs;

    /*--------------------------------------------------------------
                              MODIFIERS
    --------------------------------------------------------------*/

    /// @dev Restricts access to addresses that hold the bridge role.
    modifier onlyBridge() {
        _checkRoles(BRIDGE_ROLE);
        _;
    }

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Sets immutable references. Disables initializers on the implementation.
    /// @param _positionManager Address of the PositionManager contract.
    constructor(address _positionManager) {
        POSITION_MANAGER = PositionManager(_positionManager);
        COLLATERAL_TOKEN = CollateralToken(POSITION_MANAGER.COLLATERAL_TOKEN());
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
                                  VIEW
    --------------------------------------------------------------*/

    /// @notice Returns the module ID (3 = COMBINATORIAL).
    function moduleId() external pure returns (uint256) {
        return ModuleIds.COMBINATORIAL;
    }

    /// @notice Returns the stored canonical leg array for a combinatorial condition ID.
    /// @param _conditionId The combinatorial condition ID.
    /// @return The canonical sorted leg array.
    function getLegs(ConditionId _conditionId) external view returns (PositionId[] memory) {
        return legs[_conditionId];
    }

    /// @notice Returns whether the condition definition has been prepared and stored.
    /// @param _conditionId The combinatorial condition ID.
    /// @return True if the condition definition is stored.
    function isConditionPrepared(ConditionId _conditionId) external view returns (bool) {
        return legs[_conditionId].length > 0;
    }

    /// @notice Computes the combinatorial condition ID for a canonical leg array.
    /// @param _legs The canonical leg array.
    /// @return The combinatorial condition ID.
    function getConditionId(PositionId[] memory _legs) public pure returns (ConditionId) {
        return ConditionIdLib.encodeFromData(ModuleIds.COMBINATORIAL, 0, abi.encode(_legs));
    }

    /// @notice Calculates the collateral payout for a redeemable combinatorial position.
    /// @dev YES payout is the product of the referenced underlying condition payouts. NO payout is the complement.
    ///      Reverts if any condition is unresolved unless a resolved zero-payout leg already makes the payout terminal.
    /// @param _positionId The combinatorial position ID.
    /// @param _amount The amount of position tokens.
    /// @return The collateral payout amount.
    function getPayout(PositionId _positionId, uint256 _amount) external view override returns (uint256) {
        return _getPositionPayout(_positionId, _amount);
    }

    /// @notice Stores the canonical leg array for a combinatorial condition if it has not been
    ///         stored already.
    /// @param _legs The canonical leg array.
    /// @return conditionId The combinatorial condition ID.
    function prepareCondition(PositionId[] calldata _legs) external returns (ConditionId conditionId) {
        _validateCanonical(_legs);
        conditionId = ConditionIdLib.encodeFromData(ModuleIds.COMBINATORIAL, 0, abi.encode(_legs));
        if (legs[conditionId].length == 0) {
            legs[conditionId] = _legs;
            emit CombinatorialConditionPrepared(conditionId, _legs);
        }
    }

    /*--------------------------------------------------------------
                           SPLIT / MERGE
    --------------------------------------------------------------*/

    /// @notice Split collateral into YES and NO combinatorial positions. Collateral must be
    ///         pre-transferred to the module before calling.
    /// @param _to Recipients for [YES, NO] positions.
    /// @param _conditionId The combinatorial condition id to split on.
    /// @param _amount Amount of collateral to split.
    function split(address[] calldata _to, ConditionId _conditionId, uint256 _amount) external {
        require(_to.length == 2, InvalidArrayLength());
        _validateCombinatorialConditionId(_conditionId);
        PositionId yesPositionId = _conditionId.computePositionId(0);
        PositionId noPositionId = _conditionId.computePositionId(1);

        POSITION_MANAGER.mint(_to[0], yesPositionId, _amount);
        POSITION_MANAGER.mint(_to[1], noPositionId, _amount);

        COLLATERAL_TOKEN.burn(_amount);

        emit PositionsSplit(msg.sender, _conditionId, _to[0], _to[1], _amount);
    }

    /// @notice Merge YES and NO combinatorial positions back into collateral. Positions must be
    ///         pre-transferred to the module before calling.
    /// @param _to Recipient for collateral.
    /// @param _conditionId The combinatorial condition id to merge on.
    /// @param _amount Amount per position to merge.
    function merge(address _to, ConditionId _conditionId, uint256 _amount) external {
        _validateCombinatorialConditionId(_conditionId);
        PositionId yesPositionId = _conditionId.computePositionId(0);
        PositionId noPositionId = _conditionId.computePositionId(1);

        COLLATERAL_TOKEN.mint(_to, _amount);

        _burnPair(yesPositionId, noPositionId, _amount);

        emit PositionsMerged(msg.sender, _conditionId, _to, _amount);
    }

    /*--------------------------------------------------------------
                     SPLIT ON CONDITION / MERGE ON CONDITION
    --------------------------------------------------------------*/

    /// @notice Split a YES combinatorial position by adding a new condition.
    /// @dev YES(P) -> YES(P^Y(m)) + YES(P^N(m)). Parent YES position must be pre-transferred
    ///      to the module before calling.
    /// @param _to Recipients for [childYes, childNo] positions.
    /// @param _parentYesPositionId The parent YES combinatorial position ID.
    /// @param _conditionId The new condition to split on.
    /// @param _amount Amount of parent position to split.
    function splitOnCondition(
        address[] calldata _to,
        PositionId _parentYesPositionId,
        ConditionId _conditionId,
        uint256 _amount
    ) external {
        require(_to.length == 2, InvalidArrayLength());
        require(_parentYesPositionId.outcomeIndex() == 0, InvalidOutcomeIndex());
        ConditionId parentConditionId = _parentYesPositionId.conditionId();
        PositionId[] memory parentLegs = legs[parentConditionId];
        require(parentLegs.length > 0, ConditionNotPrepared());
        _requireConditionNotPresent(parentLegs, _conditionId);
        _validateConditionModule(_conditionId.computePositionId(0));

        (ConditionId childYesConditionId, ConditionId childNoConditionId) =
            _prepareConditionSplitIds(parentLegs, _conditionId);

        PositionId childYesPositionId = childYesConditionId.computePositionId(0);
        PositionId childNoPositionId = childNoConditionId.computePositionId(0);

        POSITION_MANAGER.mint(_to[0], childYesPositionId, _amount);
        POSITION_MANAGER.mint(_to[1], childNoPositionId, _amount);

        POSITION_MANAGER.burn(_parentYesPositionId, _amount);

        emit SplitOnCondition(msg.sender, parentConditionId, childYesConditionId, childNoConditionId, _amount);
    }

    /// @notice Merge two child YES combinatorial positions back into a parent YES combinatorial position.
    /// @dev YES(P^Y(m)) + YES(P^N(m)) -> YES(P). Child positions must be pre-transferred to
    ///      the module before calling.
    /// @param _to Recipient for parent position.
    /// @param _parentYesPositionId The parent YES combinatorial position ID.
    /// @param _conditionId The condition to merge on.
    /// @param _amount Amount per child position to merge.
    function mergeOnCondition(address _to, PositionId _parentYesPositionId, ConditionId _conditionId, uint256 _amount)
        external
    {
        require(_parentYesPositionId.outcomeIndex() == 0, InvalidOutcomeIndex());
        ConditionId parentConditionId = _parentYesPositionId.conditionId();
        PositionId[] memory parentLegs = legs[parentConditionId];
        require(parentLegs.length > 0, ConditionNotPrepared());
        _requireConditionNotPresent(parentLegs, _conditionId);
        _validateConditionModule(_conditionId.computePositionId(0));

        (ConditionId childYesConditionId, ConditionId childNoConditionId) =
            _getConditionSplitIds(parentLegs, _conditionId);

        PositionId childYesPositionId = childYesConditionId.computePositionId(0);
        PositionId childNoPositionId = childNoConditionId.computePositionId(0);

        POSITION_MANAGER.mint(_to, _parentYesPositionId, _amount);

        _burnPair(childYesPositionId, childNoPositionId, _amount);

        emit MergedOnCondition(msg.sender, parentConditionId, childYesConditionId, childNoConditionId, _amount);
    }

    /*--------------------------------------------------------------
                          EXTRACT / INJECT
    --------------------------------------------------------------*/

    /// @notice Extract a condition from a NO combinatorial position: NO(P^d) -> NO(P) + YES(P^not(d)).
    /// @dev NO position must be pre-transferred to the module before calling.
    /// @param _to Recipients for [reducedNo, residualYes] positions.
    /// @param _fullNoPositionId The full NO combinatorial position ID (Q = P^d).
    /// @param _conditionIndex Index of the condition to extract from Q.
    /// @param _amount Amount of NO position to extract from.
    function extract(address[] calldata _to, PositionId _fullNoPositionId, uint256 _conditionIndex, uint256 _amount)
        external
    {
        require(_fullNoPositionId.outcomeIndex() == 1, InvalidOutcomeIndex());
        require(_to.length == 2, InvalidArrayLength());
        ConditionId fullConditionId = _fullNoPositionId.conditionId();
        PositionId[] memory fullLegs = legs[fullConditionId];
        require(fullLegs.length > 0, ConditionNotPrepared());
        require(fullLegs.length >= 2, InvalidConditionSet());
        require(_conditionIndex < fullLegs.length, ConditionIndexOutOfRange());

        // Scope: build arrays, store conditions, compute position IDs.
        // Only the 3 position IDs survive past the block.
        ConditionId reducedConditionId;
        ConditionId residualConditionId;
        PositionId reducedNoPositionId;
        PositionId residualYesPositionId;

        {
            PositionId d = fullLegs[_conditionIndex];
            PositionId[] memory reduced = _removeLeg(fullLegs, _conditionIndex);
            PositionId[] memory residual = _insertLeg(reduced, _flipLeg(d));

            reducedConditionId = _storeLegsFromMemory(reduced);
            residualConditionId = _storeLegsFromMemory(residual);

            reducedNoPositionId = reducedConditionId.computePositionId(1);
            residualYesPositionId = residualConditionId.computePositionId(0);
        }

        POSITION_MANAGER.mint(_to[0], reducedNoPositionId, _amount);
        POSITION_MANAGER.mint(_to[1], residualYesPositionId, _amount);

        POSITION_MANAGER.burn(_fullNoPositionId, _amount);

        emit Extracted(msg.sender, fullConditionId, reducedConditionId, residualConditionId, _amount);
    }

    /// @notice Inject a condition back into a NO combinatorial position: NO(P) + YES(P^not(d)) -> NO(P^d).
    /// @dev Reduced NO and residual YES positions must be pre-transferred to the module before
    ///      calling.
    /// @param _to Recipient for the full NO position.
    /// @param _fullNoPositionId The full NO combinatorial position ID (Q = P^d).
    /// @param _conditionIndex Index of the condition being injected (its position in Q).
    /// @param _amount Amount per position to inject.
    function inject(address _to, PositionId _fullNoPositionId, uint256 _conditionIndex, uint256 _amount) external {
        require(_fullNoPositionId.outcomeIndex() == 1, InvalidOutcomeIndex());
        ConditionId fullConditionId = _fullNoPositionId.conditionId();
        PositionId[] memory fullLegs = legs[fullConditionId];
        require(fullLegs.length > 0, ConditionNotPrepared());
        require(fullLegs.length >= 2, InvalidConditionSet());
        require(_conditionIndex < fullLegs.length, ConditionIndexOutOfRange());

        ConditionId reducedConditionId;
        ConditionId residualConditionId;
        PositionId reducedNoPositionId;
        PositionId residualYesPositionId;

        {
            PositionId d = fullLegs[_conditionIndex];
            PositionId[] memory reduced = _removeLeg(fullLegs, _conditionIndex);
            PositionId[] memory residual = _insertLeg(reduced, _flipLeg(d));

            reducedConditionId = getConditionId(reduced);
            residualConditionId = getConditionId(residual);

            reducedNoPositionId = reducedConditionId.computePositionId(1);
            residualYesPositionId = residualConditionId.computePositionId(0);
        }

        POSITION_MANAGER.mint(_to, _fullNoPositionId, _amount);

        _burnPair(reducedNoPositionId, residualYesPositionId, _amount);

        emit Injected(msg.sender, fullConditionId, reducedConditionId, residualConditionId, _amount);
    }

    /*--------------------------------------------------------------
                    CONVERT TO YES BASKET / MERGE FROM YES BASKET
    --------------------------------------------------------------*/

    /// @notice Convert a NO combinatorial position into its canonical YES basket.
    /// @dev For Q = c1 ^ ... ^ cd:
    ///      NO(Q) -> YES(!c1) + YES(c1 ^ !c2) + ... + YES(c1 ^ ... ^ !cd).
    ///      NO position must be pre-transferred to the module before calling.
    /// @param _to Recipients for the YES basket positions.
    /// @param _fullNoPositionId The full NO combinatorial position ID.
    /// @param _amount Amount of NO position to convert.
    function convertToYesBasket(address[] calldata _to, PositionId _fullNoPositionId, uint256 _amount) external {
        require(_fullNoPositionId.outcomeIndex() == 1, InvalidOutcomeIndex());
        ConditionId fullConditionId = _fullNoPositionId.conditionId();
        PositionId[] memory fullLegs = legs[fullConditionId];
        require(fullLegs.length > 0, ConditionNotPrepared());
        require(_to.length == fullLegs.length, InvalidArrayLength());

        PositionId[] memory basketPositionIds = _prepareYesBasketPositionIds(fullLegs);

        uint256 length = basketPositionIds.length;
        for (uint256 i; i < length; ++i) {
            POSITION_MANAGER.mint(_to[i], basketPositionIds[i], _amount);
        }

        POSITION_MANAGER.burn(_fullNoPositionId, _amount);

        emit ConvertedToYesBasket(msg.sender, fullConditionId, _amount);
    }

    /// @notice Merge the canonical YES basket back into a NO combinatorial position.
    /// @dev Basket positions must be pre-transferred to the module before calling.
    /// @param _to Recipient for the reconstructed NO position.
    /// @param _fullNoPositionId The full NO combinatorial position ID.
    /// @param _amount Amount per basket position to merge.
    function mergeFromYesBasket(address _to, PositionId _fullNoPositionId, uint256 _amount) external {
        require(_fullNoPositionId.outcomeIndex() == 1, InvalidOutcomeIndex());
        ConditionId fullConditionId = _fullNoPositionId.conditionId();
        PositionId[] memory fullLegs = legs[fullConditionId];
        require(fullLegs.length > 0, ConditionNotPrepared());

        PositionId[] memory basketPositionIds = _getYesBasketPositionIds(fullLegs);

        POSITION_MANAGER.mint(_to, _fullNoPositionId, _amount);

        _burnMany(basketPositionIds, _amount);

        emit MergedFromYesBasket(msg.sender, fullConditionId, _amount);
    }

    /*--------------------------------------------------------------
                         COMPRESS / REDEEM
    --------------------------------------------------------------*/

    /// @notice Compress a combinatorial position by removing resolved conditions.
    /// @dev Permissionless. Burns old position, mints a compressed position, collateral, or both.
    ///      Old position must be pre-transferred to the module before calling.
    /// @param _to Recipient for the output.
    /// @param _positionId The combinatorial position ID to compress.
    /// @param _amount Amount of position to compress.
    function compress(address _to, PositionId _positionId, uint256 _amount) external {
        PositionId newPositionId;
        uint256 positionAmount;
        uint256 collateralOut;

        {
            // Decode the input position and scan the condition set once.
            // Resolved legs contribute to a high-precision payout factor; unresolved legs are kept.
            uint256 outcomeIndex = _positionId.outcomeIndex();
            require(outcomeIndex < 2, InvalidOutcomeIndex());

            PositionId[] memory remaining;
            uint256 remainingCount;
            uint256 payoutFactor;
            uint256 payoutFactorUp;

            {
                ConditionId conditionId = _positionId.conditionId();
                PositionId[] memory storedLegs = legs[conditionId];
                require(storedLegs.length > 0, ConditionNotPrepared());

                remaining = new PositionId[](storedLegs.length);
                payoutFactor = PAYOUT_FACTOR_DENOMINATOR;
                payoutFactorUp = PAYOUT_FACTOR_DENOMINATOR;

                bool compressed;
                uint256 length = storedLegs.length;
                for (uint256 i; i < length; ++i) {
                    (bool resolved, uint256 conditionPayout) = _getConditionPayout(storedLegs[i]);
                    if (!resolved) {
                        remaining[remainingCount] = storedLegs[i];
                        ++remainingCount;
                    } else {
                        compressed = true;
                        if (conditionPayout == 0) {
                            payoutFactor = 0;
                            payoutFactorUp = 0;
                            break;
                        }
                        if (conditionPayout != RESULT_DENOMINATOR) {
                            payoutFactor = FixedPointMathLib.mulDiv(payoutFactor, conditionPayout, RESULT_DENOMINATOR);
                            payoutFactorUp =
                                FixedPointMathLib.mulDivUp(payoutFactorUp, conditionPayout, RESULT_DENOMINATOR);
                        }
                    }
                }

                require(compressed, PositionNotCompressible());
            }

            // Convert the resolved-leg factor into output amounts.
            // YES rounds down. NO gets immediate collateral for the complement and a rounded-up reduced NO.
            if (outcomeIndex == 0) {
                positionAmount = FixedPointMathLib.mulDiv(_amount, payoutFactor, PAYOUT_FACTOR_DENOMINATOR);
                if (positionAmount != 0) {
                    if (remainingCount == 0) {
                        // All legs resolved: the YES payout is pure collateral.
                        // Move the calculated value into collateralOut and clear
                        // positionAmount so the Compressed event correctly reports
                        // zero for the minted position amount.
                        collateralOut = positionAmount;
                        positionAmount = 0;
                    } else {
                        PositionId[] memory trimmed = _trimArray(remaining, remainingCount);
                        newPositionId = _storeLegsFromMemory(trimmed).computePositionId(0);
                    }
                }
            } else {
                positionAmount = FixedPointMathLib.mulDivUp(_amount, payoutFactorUp, PAYOUT_FACTOR_DENOMINATOR);
                collateralOut = _amount - positionAmount;
                if (positionAmount != 0 && remainingCount != 0) {
                    PositionId[] memory trimmed = _trimArray(remaining, remainingCount);
                    newPositionId = _storeLegsFromMemory(trimmed).computePositionId(1);
                } else if (remainingCount == 0) {
                    // All legs resolved: no reduced NO position to mint.
                    // collateralOut was already computed above from
                    // positionAmount, so clear positionAmount afterward to
                    // keep the Compressed event accurate.
                    positionAmount = 0;
                }
            }
        }

        if (collateralOut != 0) COLLATERAL_TOKEN.mint(_to, collateralOut);
        if (PositionId.unwrap(newPositionId) != 0) POSITION_MANAGER.mint(_to, newPositionId, positionAmount);

        POSITION_MANAGER.burn(_positionId, _amount);

        emit Compressed(msg.sender, _positionId, newPositionId, _amount, positionAmount, collateralOut);
    }

    /// @notice Redeem a combinatorial position for collateral once its payout is known.
    /// @dev Requires all legs resolved unless a resolved zero-payout leg already makes YES worth
    ///      zero and NO worth the full amount. Position must be pre-transferred to the module
    ///      before calling.
    /// @param _to Recipient for collateral payout.
    /// @param _positionId The combinatorial position ID to redeem.
    /// @param _amount Amount of position to redeem.
    function redeem(address _to, PositionId _positionId, uint256 _amount) external {
        uint256 payout = _getPositionPayout(_positionId, _amount);

        if (payout > 0) COLLATERAL_TOKEN.mint(_to, payout);

        POSITION_MANAGER.burn(_positionId, _amount);

        emit PositionRedeemed(msg.sender, _positionId, _to, _amount, payout);
    }

    /*--------------------------------------------------------------
                          UNWRAP / WRAP
    --------------------------------------------------------------*/

    /// @notice Unwrap a single-condition combinatorial position into the underlying binary/negrisk position.
    /// @dev Requires crossModuleAuth on PositionManager. Combinatorial position must be
    ///      pre-transferred to the module before calling.
    /// @param _to Recipient for the underlying position.
    /// @param _positionId The combinatorial position ID to unwrap.
    /// @param _amount Amount to unwrap.
    function unwrap(address _to, PositionId _positionId, uint256 _amount) external {
        ConditionId conditionId = _positionId.conditionId();
        uint256 outcomeIndex = _positionId.outcomeIndex();
        require(outcomeIndex < 2, InvalidOutcomeIndex());

        PositionId[] memory storedLegs = legs[conditionId];
        require(storedLegs.length == 1, SingleConditionRequired());

        // YES combinatorial position of condition C -> C itself
        // NO combinatorial position of condition C -> flipped C
        PositionId underlyingPositionId;
        if (outcomeIndex == 0) underlyingPositionId = storedLegs[0];
        else underlyingPositionId = _flipLeg(storedLegs[0]);

        POSITION_MANAGER.mint(_to, underlyingPositionId, _amount);

        POSITION_MANAGER.burn(_positionId, _amount);

        emit Unwrapped(msg.sender, _positionId, underlyingPositionId, _amount);
    }

    /// @notice Wrap an underlying binary/negrisk position into a single-condition combinatorial position.
    /// @dev Requires crossModuleAuth on PositionManager. Underlying position must be
    ///      pre-transferred to the module before calling.
    /// @param _to Recipient for the combinatorial position.
    /// @param _underlyingPositionId The underlying position ID to wrap.
    /// @param _amount Amount to wrap.
    function wrap(address _to, PositionId _underlyingPositionId, uint256 _amount) external {
        uint256 underlyingOutcome = _underlyingPositionId.outcomeIndex();
        require(underlyingOutcome < 2, InvalidOutcomeIndex());
        _validateConditionModule(_underlyingPositionId);

        // The stored condition is always the YES form of the underlying condition:
        // Wrapping underlying YES(m) -> single-condition combinatorial YES([Y(m)])
        // Wrapping underlying NO(m) -> single-condition combinatorial YES([N(m)])
        // The combinatorial condition is the underlying positionId directly.
        PositionId[] memory wrappedLegs = new PositionId[](1);
        wrappedLegs[0] = _underlyingPositionId;

        ConditionId conditionId = _storeLegsFromMemory(wrappedLegs);
        // YES combinatorial position of [underlyingPositionId]
        PositionId combinatorialPositionId = conditionId.computePositionId(0);

        POSITION_MANAGER.mint(_to, combinatorialPositionId, _amount);

        POSITION_MANAGER.burn(_underlyingPositionId, _amount);

        emit Wrapped(msg.sender, _underlyingPositionId, combinatorialPositionId, _amount);
    }

    /*--------------------------------------------------------------
                              ONLY BRIDGE
    --------------------------------------------------------------*/

    /// @notice Mint combinatorial positions from a bridge.
    /// @dev Does not require the condition definition to be prepared in storage. Emits
    ///      `BridgePositionMinted` only when `_amount > 0`; zero-amount calls are no-ops.
    /// @param _to Recipient address.
    /// @param _positionId The combinatorial position ID to mint.
    /// @param _amount Amount to mint.
    function mintFromBridge(address _to, PositionId _positionId, uint256 _amount) external onlyBridge {
        _validateCombinatorialPositionId(_positionId);
        if (_amount > 0) {
            POSITION_MANAGER.mint(_to, _positionId, _amount);
            emit BridgePositionMinted(_to, _positionId, _amount);
        }
    }

    /// @notice Burn bridged combinatorial positions already held by this module.
    /// @dev Positions must be transferred to this module before calling.
    /// @param _positionIds The combinatorial position IDs to burn.
    /// @param _amounts The amounts to burn for each position ID.
    function burnFromBridge(PositionId[] calldata _positionIds, uint256[] calldata _amounts) external onlyBridge {
        uint256 length = _positionIds.length;
        for (uint256 i; i < length; ++i) {
            _validateCombinatorialPositionId(_positionIds[i]);
        }
        POSITION_MANAGER.batchBurn(_positionIds, _amounts);

        emit BridgePositionsBurned(_positionIds, _amounts);
    }

    /*--------------------------------------------------------------
                            MULTICALL
    --------------------------------------------------------------*/

    /// @notice Execute multiple calls in a single transaction.
    /// @param _calls Array of encoded function calls.
    /// @return results Array of return data from each call.
    function multicall(bytes[] calldata _calls) external returns (bytes[] memory results) {
        results = new bytes[](_calls.length);
        uint256 length = _calls.length;
        for (uint256 i; i < length; ++i) {
            (bool success, bytes memory result) = address(this).delegatecall(_calls[i]);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(result, 32), mload(result))
                }
            }
            results[i] = result;
        }
    }

    /*--------------------------------------------------------------
                              ONLY ADMIN
    --------------------------------------------------------------*/

    /// @notice Grant the bridge role to an address.
    /// @dev Only callable by an admin.
    /// @param _bridge Address to receive the bridge role.
    function addBridge(address _bridge) external onlyAdmin {
        _grantRoles(_bridge, BRIDGE_ROLE);
    }

    /// @notice Revoke the bridge role from an address.
    /// @dev Only callable by an admin.
    /// @param _bridge Address to lose the bridge role.
    function removeBridge(address _bridge) external onlyAdmin {
        _removeRoles(_bridge, BRIDGE_ROLE);
    }

    /*--------------------------------------------------------------
                          UUPS AUTHORIZATION
    --------------------------------------------------------------*/

    /// @dev Restricts upgrades to the owner and enforces immutable config compatibility.
    /// @param newImplementation The proposed implementation contract.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        CombinatorialModule newImpl = CombinatorialModule(newImplementation);

        if (
            newImpl.moduleId() != ModuleIds.COMBINATORIAL
                || address(newImpl.POSITION_MANAGER()) != address(POSITION_MANAGER)
                || address(newImpl.COLLATERAL_TOKEN()) != address(COLLATERAL_TOKEN)
        ) revert IncompatibleImplementation();
    }

    /*--------------------------------------------------------------
                          INTERNAL FUNCTIONS
    --------------------------------------------------------------*/

    /// @dev Validates that a leg array is canonical: non-empty, ascending order, no duplicates,
    ///      no contradictions, and all legs from valid modules.
    function _validateCanonical(PositionId[] calldata _legs) internal view {
        uint256 length = _legs.length;
        require(length > 0, InvalidConditionSet());
        require(length <= MAX_LEGS, InvalidConditionSet());

        _validateConditionModule(_legs[0]);
        require(_legs[0].outcomeIndex() < 2, InvalidOutcomeIndex());

        for (uint256 i = 1; i < length; ++i) {
            _validateConditionModule(_legs[i]);
            require(_legs[i].outcomeIndex() < 2, InvalidOutcomeIndex());
            require(PositionId.unwrap(_legs[i]) > PositionId.unwrap(_legs[i - 1]), NonCanonicalInput());
            if (_legs[i].conditionId() == _legs[i - 1].conditionId()) revert ConflictingConditions();
        }
    }

    /// @dev Validates that a leg references a binary or negrisk module.
    function _validateConditionModule(PositionId _leg) internal pure {
        uint256 conditionModuleId = _leg.moduleId();
        require(
            conditionModuleId == ModuleIds.BINARY || conditionModuleId == ModuleIds.NEGRISK, InvalidConditionModule()
        );
    }

    /// @dev Validates that a pair split/merge condition id belongs to the combinatorial module.
    function _validateCombinatorialConditionId(ConditionId _conditionId) internal pure {
        require(_conditionId.moduleId() == ModuleIds.COMBINATORIAL, InvalidConditionModule());
    }

    /// @dev Checks that no leg in the array shares a conditionId with the given condition.
    function _requireConditionNotPresent(PositionId[] memory _legs, ConditionId _conditionId) internal pure {
        uint256 length = _legs.length;
        for (uint256 i; i < length; ++i) {
            if (_legs[i].conditionId() == _conditionId) revert MarketAlreadyPresent();
        }
    }

    /// @dev Stores a leg array from memory. Returns the conditionId. Idempotent.
    function _storeLegsFromMemory(PositionId[] memory _legs) internal returns (ConditionId) {
        uint256 length = _legs.length;
        require(length > 0, InvalidConditionSet());
        require(length <= MAX_LEGS, InvalidConditionSet());
        ConditionId conditionId = getConditionId(_legs);
        if (legs[conditionId].length == 0) {
            legs[conditionId] = _legs;
            emit CombinatorialConditionPrepared(conditionId, _legs);
        }
        return conditionId;
    }

    /// @dev Inserts a leg into a sorted array, maintaining ascending order. The new leg must not
    ///      conflict with existing ones (caller must validate beforehand).
    function _insertLeg(PositionId[] memory _base, PositionId _leg) internal pure returns (PositionId[] memory) {
        uint256 length = _base.length;
        PositionId[] memory result = new PositionId[](length + 1);

        uint256 insertIdx = length;
        for (uint256 i; i < length; ++i) {
            if (PositionId.unwrap(_leg) < PositionId.unwrap(_base[i])) {
                insertIdx = i;
                break;
            }
        }

        for (uint256 i; i < insertIdx; ++i) {
            result[i] = _base[i];
        }
        result[insertIdx] = _leg;
        for (uint256 i = insertIdx; i < length; ++i) {
            result[i + 1] = _base[i];
        }

        return result;
    }

    /// @dev Removes the leg at the given index from a memory array.
    function _removeLeg(PositionId[] memory _base, uint256 _index) internal pure returns (PositionId[] memory) {
        uint256 length = _base.length;
        PositionId[] memory result = new PositionId[](length - 1);

        for (uint256 i; i < _index; ++i) {
            result[i] = _base[i];
        }
        for (uint256 i = _index + 1; i < length; ++i) {
            result[i - 1] = _base[i];
        }

        return result;
    }

    /// @dev Builds and stores child condition IDs for splitOnCondition.
    function _prepareConditionSplitIds(PositionId[] memory _parentLegs, ConditionId _conditionId)
        internal
        returns (ConditionId childYesConditionId, ConditionId childNoConditionId)
    {
        PositionId[] memory childYesLegs = _insertLeg(_parentLegs, _conditionId.computePositionId(0));
        PositionId[] memory childNoLegs = _insertLeg(_parentLegs, _conditionId.computePositionId(1));

        childYesConditionId = _storeLegsFromMemory(childYesLegs);
        childNoConditionId = _storeLegsFromMemory(childNoLegs);
    }

    /// @dev Builds child condition IDs for mergeOnCondition without storing derived legs.
    function _getConditionSplitIds(PositionId[] memory _parentLegs, ConditionId _conditionId)
        internal
        pure
        returns (ConditionId childYesConditionId, ConditionId childNoConditionId)
    {
        PositionId[] memory childYesLegs = _insertLeg(_parentLegs, _conditionId.computePositionId(0));
        PositionId[] memory childNoLegs = _insertLeg(_parentLegs, _conditionId.computePositionId(1));

        childYesConditionId = getConditionId(childYesLegs);
        childNoConditionId = getConditionId(childNoLegs);
    }

    /// @dev Builds and stores the canonical YES basket position IDs for a full leg array.
    ///      Reuses a single array with assembly length manipulation to avoid O(d²) copies.
    function _prepareYesBasketPositionIds(PositionId[] memory _fullLegs)
        internal
        returns (PositionId[] memory basketPositionIds)
    {
        uint256 length = _fullLegs.length;
        basketPositionIds = new PositionId[](length);

        PositionId[] memory basketLegs = new PositionId[](length);
        for (uint256 j; j < length; ++j) {
            basketLegs[j] = _fullLegs[j];
        }

        for (uint256 i; i < length; ++i) {
            PositionId original = basketLegs[i];
            basketLegs[i] = _flipLeg(original);

            assembly ("memory-safe") {
                mstore(basketLegs, add(i, 1))
            }

            ConditionId basketConditionId = _storeLegsFromMemory(basketLegs);
            basketPositionIds[i] = basketConditionId.computePositionId(0);

            basketLegs[i] = original;
            assembly ("memory-safe") {
                mstore(basketLegs, length)
            }
        }
    }

    /// @dev Builds the canonical YES basket position IDs for a full leg array without storing
    ///      derived legs. Reuses a single array with assembly length manipulation.
    function _getYesBasketPositionIds(PositionId[] memory _fullLegs)
        internal
        pure
        returns (PositionId[] memory basketPositionIds)
    {
        uint256 length = _fullLegs.length;
        basketPositionIds = new PositionId[](length);

        PositionId[] memory basketLegs = new PositionId[](length);
        for (uint256 j; j < length; ++j) {
            basketLegs[j] = _fullLegs[j];
        }

        for (uint256 i; i < length; ++i) {
            PositionId original = basketLegs[i];
            basketLegs[i] = _flipLeg(original);

            assembly ("memory-safe") {
                mstore(basketLegs, add(i, 1))
            }

            ConditionId basketConditionId = getConditionId(basketLegs);
            basketPositionIds[i] = basketConditionId.computePositionId(0);

            basketLegs[i] = original;
            assembly ("memory-safe") {
                mstore(basketLegs, length)
            }
        }
    }

    /// @dev Burns a pair of positions with equal amounts.
    function _burnPair(PositionId _positionIdA, PositionId _positionIdB, uint256 _amount) internal {
        PositionId[] memory ids = new PositionId[](2);
        ids[0] = _positionIdA;
        ids[1] = _positionIdB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = _amount;
        amounts[1] = _amount;
        POSITION_MANAGER.batchBurn(ids, amounts);
    }

    /// @dev Burns many positions with equal amounts.
    function _burnMany(PositionId[] memory _positionIds, uint256 _amount) internal {
        uint256 length = _positionIds.length;
        uint256[] memory amounts = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            amounts[i] = _amount;
        }
        POSITION_MANAGER.batchBurn(_positionIds, amounts);
    }

    /// @dev Flips the outcome index of a leg (0 -> 1, 1 -> 0).
    function _flipLeg(PositionId _leg) internal pure returns (PositionId) {
        return _leg.conditionId().computePositionId(_leg.outcomeIndex() ^ 1);
    }

    /// @dev Validates that a bridged position belongs to the combinatorial module and uses a valid
    ///      YES/NO outcome index.
    function _validateCombinatorialPositionId(PositionId _positionId) internal pure {
        require(_positionId.moduleId() == ModuleIds.COMBINATORIAL, InvalidConditionModule());
        require(_positionId.outcomeIndex() < 2, InvalidOutcomeIndex());
    }

    /// @dev Shrinks an oversized array in-place to the given length.
    function _trimArray(PositionId[] memory _arr, uint256 _length) internal pure returns (PositionId[] memory) {
        require(_length <= _arr.length, InvalidArrayLength());
        assembly ("memory-safe") {
            mstore(_arr, _length)
        }
        return _arr;
    }

    /// @dev Calculates the collateral payout once final or terminal.
    ///      Accumulates a high-precision payout factor and rounds once at the amount boundary.
    function _getPositionPayout(PositionId _positionId, uint256 _amount) internal view returns (uint256 payout) {
        ConditionId conditionId = _positionId.conditionId();
        uint256 outcomeIndex = _positionId.outcomeIndex();
        require(outcomeIndex < 2, InvalidOutcomeIndex());

        PositionId[] memory storedLegs = legs[conditionId];
        require(storedLegs.length > 0, ConditionNotPrepared());

        uint256 length = storedLegs.length;

        if (outcomeIndex == 0) {
            uint256 payoutFactor = PAYOUT_FACTOR_DENOMINATOR;
            bool hasUnresolved;
            for (uint256 i; i < length; ++i) {
                (bool resolved, uint256 conditionPayout) = _getConditionPayout(storedLegs[i]);
                if (!resolved) {
                    hasUnresolved = true;
                    continue;
                }

                if (conditionPayout == 0) return 0;
                if (conditionPayout != RESULT_DENOMINATOR) {
                    payoutFactor = FixedPointMathLib.mulDiv(payoutFactor, conditionPayout, RESULT_DENOMINATOR);
                }
            }

            require(!hasUnresolved, PositionNotRedeemable());
            return FixedPointMathLib.mulDiv(_amount, payoutFactor, PAYOUT_FACTOR_DENOMINATOR);
        }

        uint256 payoutFactorUp = PAYOUT_FACTOR_DENOMINATOR;
        bool unresolved;
        for (uint256 i; i < length; ++i) {
            (bool resolved, uint256 conditionPayout) = _getConditionPayout(storedLegs[i]);
            if (!resolved) {
                unresolved = true;
                continue;
            }

            if (conditionPayout == 0) return _amount;
            if (conditionPayout != RESULT_DENOMINATOR) {
                payoutFactorUp = FixedPointMathLib.mulDivUp(payoutFactorUp, conditionPayout, RESULT_DENOMINATOR);
            }
        }

        require(!unresolved, PositionNotRedeemable());
        return _amount - FixedPointMathLib.mulDivUp(_amount, payoutFactorUp, PAYOUT_FACTOR_DENOMINATOR);
    }

    /// @dev Reads the resolution status and payout numerator of a leg from the underlying module.
    /// @return resolved True if the leg's underlying condition has been resolved.
    /// @return conditionPayout The payout numerator for the referenced side of this leg.
    function _getConditionPayout(PositionId _leg) internal view returns (bool resolved, uint256 conditionPayout) {
        address module = POSITION_MANAGER.moduleById(_leg.moduleId());

        uint256[] memory res = BaseModule(module).getResult(_leg.conditionId());
        if (res.length != 2) return (false, 0);

        resolved = true;
        conditionPayout = res[_leg.outcomeIndex()];
    }
}
