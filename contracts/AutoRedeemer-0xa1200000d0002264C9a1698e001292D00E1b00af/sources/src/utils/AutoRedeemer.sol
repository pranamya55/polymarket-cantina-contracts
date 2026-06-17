// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { ERC20 } from "@solady/src/tokens/ERC20.sol";
import { Initializable } from "@solady/src/utils/Initializable.sol";
import { SafeTransferLib } from "@solady/src/utils/SafeTransferLib.sol";
import { UUPSUpgradeable } from "@solady/src/utils/UUPSUpgradeable.sol";

import { ERC1155TokenReceiver } from "@polymarket-v2/src/abstract/ERC1155TokenReceiver.sol";
import { InitializableRoles } from "@polymarket-v2/src/auth/InitializableRoles.sol";
import { CollateralOnramp } from "@polymarket-v2/src/collateral/CollateralOnramp.sol";
import { CollateralToken } from "@polymarket-v2/src/collateral/CollateralToken.sol";
import { IConditionalTokens } from "@polymarket-v2/src/legacy/interfaces/IConditionalTokens.sol";
import { INegRiskAdapter } from "@polymarket-v2/src/legacy/interfaces/INegRiskAdapter.sol";
import { CTFHelpers } from "@polymarket-v2/src/legacy/libraries/CTFHelpers.sol";
import { CTHelpers } from "@polymarket-v2/src/legacy/libraries/CTHelpers.sol";
import { PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";
import { BaseModule } from "@polymarket-v2/src/modules/abstract/BaseModule.sol";

abstract contract AutoRedeemerErrors {
    error LengthMismatch();
}

abstract contract AutoRedeemerEvents {
    event Redemption(address indexed from, PositionId indexed positionId, uint256 payout);
    event BinaryRedemption(address indexed from, bytes32 indexed conditionId, uint256 payout);
    event NegRiskRedemption(address indexed from, bytes32 indexed conditionId, uint256 payout);
}

/// @title AutoRedeemer
/// @author Polymarket
/// @notice Allows authorized operators to redeem resolved positions on behalf of users.
/// @dev Users must approve this contract to transfer their positions via the PositionManager or
///      legacy ConditionalTokens.
contract AutoRedeemer is
    UUPSUpgradeable,
    Initializable,
    InitializableRoles,
    ERC1155TokenReceiver,
    AutoRedeemerErrors,
    AutoRedeemerEvents
{
    using SafeTransferLib for address;

    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice The PositionManager contract used to look up modules and transfer positions.
    PositionManager public immutable POSITION_MANAGER;
    CollateralToken public immutable COLLATERAL_TOKEN;
    CollateralOnramp public immutable COLLATERAL_ONRAMP;
    IConditionalTokens public immutable CONDITIONAL_TOKENS;
    INegRiskAdapter public immutable NEG_RISK_ADAPTER;
    address public immutable USDCE;
    address public immutable WRAPPED_COLLATERAL;

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Deploys the AutoRedeemer implementation.
    /// @param _positionManager Address of the PositionManager contract.
    /// @param _collateralOnramp Address of the permissionless CollateralOnramp contract.
    /// @param _conditionalTokens Address of the legacy ConditionalTokens contract.
    /// @param _negRiskAdapter Address of the legacy NegRiskAdapter contract.
    constructor(
        address _positionManager,
        address _collateralOnramp,
        address _conditionalTokens,
        address _negRiskAdapter
    ) {
        POSITION_MANAGER = PositionManager(_positionManager);
        COLLATERAL_TOKEN = CollateralToken(PositionManager(_positionManager).COLLATERAL_TOKEN());
        COLLATERAL_ONRAMP = CollateralOnramp(_collateralOnramp);
        USDCE = COLLATERAL_TOKEN.USDCE();
        CONDITIONAL_TOKENS = IConditionalTokens(_conditionalTokens);
        NEG_RISK_ADAPTER = INegRiskAdapter(_negRiskAdapter);
        WRAPPED_COLLATERAL = _negRiskAdapter == address(0) ? address(0) : INegRiskAdapter(_negRiskAdapter).wcol();

        _disableInitializers();
    }

    /*--------------------------------------------------------------
                              INITIALIZER
    --------------------------------------------------------------*/

    /// @notice Initializes the proxied AutoRedeemer owner and admin.
    /// @param _owner The owner address.
    /// @param _admin The initial admin address.
    function initialize(address _owner, address _admin) external initializer {
        _initializeOwner(_owner);
        _grantRoles(_admin, ADMIN_ROLE);

        address usdce = USDCE;
        CollateralOnramp collateralOnramp = COLLATERAL_ONRAMP;
        if (usdce != address(0) && address(collateralOnramp) != address(0)) {
            usdce.safeApprove(address(collateralOnramp), type(uint256).max);
        }

        IConditionalTokens conditionalTokens = CONDITIONAL_TOKENS;
        INegRiskAdapter negRiskAdapter = NEG_RISK_ADAPTER;
        if (address(conditionalTokens) != address(0) && address(negRiskAdapter) != address(0)) {
            conditionalTokens.setApprovalForAll(address(negRiskAdapter), true);
        }
    }

    /*--------------------------------------------------------------
                              ONLY OPERATOR
    --------------------------------------------------------------*/

    /// @notice Batch redeem resolved V2 positions on behalf of users.
    /// @dev The module is derived from the position ID, and the user's full balance is redeemed.
    ///      Users that have not approved this contract are skipped so a single missing approval
    ///      does not revert the whole batch.
    /// @param _froms The addresses holding positions to redeem.
    /// @param _positionIds The position IDs to redeem.
    function redeem(address[] calldata _froms, PositionId[] calldata _positionIds) external onlyOperator {
        uint256 len = _froms.length;
        require(len == _positionIds.length, LengthMismatch());

        PositionManager positionManager = POSITION_MANAGER;
        CollateralToken collateralToken = COLLATERAL_TOKEN;

        uint256 collateralBalance = collateralToken.balanceOf(address(this));
        uint256 cachedModuleId = type(uint256).max;
        address cachedModule;

        for (uint256 i; i < len; ++i) {
            address from = _froms[i];
            PositionId positionId = _positionIds[i];

            if (positionManager.isApprovedForAll(from, address(this))) {
                uint256 amount = positionManager.balanceOf(from, PositionId.unwrap(positionId));
                uint256 payout;
                if (amount != 0) {
                    uint256 moduleId = positionId.moduleId();
                    address module = cachedModule;
                    if (moduleId != cachedModuleId) {
                        module = positionManager.moduleById(moduleId);
                        cachedModuleId = moduleId;
                        cachedModule = module;
                    }

                    positionManager.unsafeTransferFrom(from, module, positionId, amount);
                    BaseModule(module).redeem(address(this), positionId, amount);

                    payout = collateralToken.balanceOf(address(this)) - collateralBalance;
                    if (payout != 0) collateralToken.transfer(from, payout);
                }

                emit Redemption(from, positionId, payout);
            }
        }
    }

    /// @notice Batch redeem legacy binary CTF positions on behalf of users.
    /// @dev Matches the legacy auto-redeemer calldata shape. Users that have not approved this
    ///      contract on ConditionalTokens are skipped.
    /// @param _froms The addresses holding legacy CTF positions to redeem.
    /// @param _conditionIds The legacy binary CTF condition IDs to redeem.
    function redeemBinary(address[] calldata _froms, bytes32[] calldata _conditionIds) external onlyOperator {
        uint256 len = _froms.length;
        require(len == _conditionIds.length, LengthMismatch());

        IConditionalTokens conditionalTokens = CONDITIONAL_TOKENS;
        address usdce = USDCE;
        CollateralOnramp collateralOnramp = COLLATERAL_ONRAMP;

        uint256[] memory partition = CTFHelpers.partition();
        uint256[] memory positionIds = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        uint256 usdceBalance = ERC20(usdce).balanceOf(address(this));

        for (uint256 i; i < len; ++i) {
            address from = _froms[i];
            bytes32 conditionId = _conditionIds[i];

            if (conditionalTokens.isApprovedForAll(from, address(this))) {
                // YES / NO position IDs for this binary condition, written into the hoisted buffer.
                positionIds[0] = CTHelpers.getPositionId(usdce, CTHelpers.getCollectionId(bytes32(0), conditionId, 1));
                positionIds[1] = CTHelpers.getPositionId(usdce, CTHelpers.getCollectionId(bytes32(0), conditionId, 2));
                amounts[0] = conditionalTokens.balanceOf(from, positionIds[0]);
                amounts[1] = conditionalTokens.balanceOf(from, positionIds[1]);
                uint256 payout;
                if (amounts[0] != 0 || amounts[1] != 0) {
                    conditionalTokens.safeBatchTransferFrom(from, address(this), positionIds, amounts, "");
                    conditionalTokens.redeemPositions(usdce, bytes32(0), conditionId, partition);

                    payout = ERC20(usdce).balanceOf(address(this)) - usdceBalance;
                    if (payout != 0) collateralOnramp.wrap(usdce, from, payout);
                }

                emit BinaryRedemption(from, conditionId, payout);
            }
        }
    }

    /// @notice Batch redeem legacy neg-risk CTF positions on behalf of users.
    /// @dev Matches the legacy auto-redeemer calldata shape. Users that have not approved this
    ///      contract on ConditionalTokens are skipped.
    /// @param _froms The addresses holding legacy neg-risk positions to redeem.
    /// @param _conditionIds The legacy neg-risk CTF condition IDs to redeem.
    function redeemNegRisk(address[] calldata _froms, bytes32[] calldata _conditionIds) external onlyOperator {
        uint256 len = _froms.length;
        require(len == _conditionIds.length, LengthMismatch());

        IConditionalTokens conditionalTokens = CONDITIONAL_TOKENS;
        INegRiskAdapter negRiskAdapter = NEG_RISK_ADAPTER;
        address usdce = USDCE;
        address wrappedCollateral = WRAPPED_COLLATERAL;
        CollateralOnramp collateralOnramp = COLLATERAL_ONRAMP;

        uint256[] memory positionIds = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        uint256 usdceBalance = ERC20(usdce).balanceOf(address(this));

        for (uint256 i; i < len; ++i) {
            address from = _froms[i];
            bytes32 conditionId = _conditionIds[i];

            if (conditionalTokens.isApprovedForAll(from, address(this))) {
                // YES / NO position IDs for this neg-risk condition, written into the hoisted buffer.
                positionIds[0] =
                    CTHelpers.getPositionId(wrappedCollateral, CTHelpers.getCollectionId(bytes32(0), conditionId, 1));
                positionIds[1] =
                    CTHelpers.getPositionId(wrappedCollateral, CTHelpers.getCollectionId(bytes32(0), conditionId, 2));
                amounts[0] = conditionalTokens.balanceOf(from, positionIds[0]);
                amounts[1] = conditionalTokens.balanceOf(from, positionIds[1]);
                uint256 payout;
                if (amounts[0] != 0 || amounts[1] != 0) {
                    conditionalTokens.safeBatchTransferFrom(from, address(this), positionIds, amounts, "");
                    negRiskAdapter.redeemPositions(conditionId, amounts);

                    payout = ERC20(usdce).balanceOf(address(this)) - usdceBalance;
                    if (payout != 0) collateralOnramp.wrap(usdce, from, payout);
                }

                emit NegRiskRedemption(from, conditionId, payout);
            }
        }
    }

    /*--------------------------------------------------------------
                         UUPS AUTHORIZATION
    --------------------------------------------------------------*/

    /// @dev Restricts upgrades to the owner.
    function _authorizeUpgrade(address) internal override onlyOwner { }
}
