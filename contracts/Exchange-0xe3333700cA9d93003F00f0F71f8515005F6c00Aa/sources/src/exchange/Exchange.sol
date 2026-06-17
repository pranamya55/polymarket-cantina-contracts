// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { OwnableRoles } from "@solady/src/auth/OwnableRoles.sol";
import { Initializable } from "@solady/src/utils/Initializable.sol";
import { SafeTransferLib } from "@solady/src/utils/SafeTransferLib.sol";
import { EIP712 } from "@solady/src/utils/EIP712.sol";
import { UUPSUpgradeable } from "@solady/src/utils/UUPSUpgradeable.sol";

import { ERC1155TokenReceiver } from "@polymarket-v2/src/abstract/ERC1155TokenReceiver.sol";
import { BaseModule } from "@polymarket-v2/src/modules/abstract/BaseModule.sol";
import { CombinatorialModule } from "@polymarket-v2/src/modules/CombinatorialModule.sol";
import { ConditionId, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";

import { Order, Side, SignatureType, OrderStatus, ORDER_TYPEHASH } from "./OrderStructs.sol";

/// @notice Execution context for matching orders.
struct MatchContext {
    /// @dev The taker's maker-asset fill amount.
    uint256 takerFillAmount;
    /// @dev The taker's fee amount.
    uint256 takerFee;
    /// @dev The taker's address.
    address takerAddr;
    /// @dev The resolved module address (set during batch matching).
    address moduleAddr;
    /// @dev The taker's position token ID
    ///     The UDVT is 32 bytes and we use `uint256` in the typehash -- don't narrow PositionId to <32 bytes.
    PositionId takerTokenId;
    /// @dev The taker's actual receive amount.
    uint256 takerReceiveAmount;
}

struct BatchBuyAccounting {
    uint256 totalTakerTokenIn;
    uint256 totalCollateralIn;
    uint256 totalSellMakerNetOut;
}

struct BatchSellAccounting {
    uint256 totalCollateralIn;
    uint256 totalSellMakerNetOut;
}

/// @notice Bundled taker-side amounts for `matchOrders` and `matchOrdersAndPrepareCombinatorial`.
/// @dev Grouped into a struct to keep the matching entry points within stack limits.
struct TakerAmounts {
    /// @dev Fill amount for the taker.
    uint256 takerFillAmount;
    /// @dev Actual amount received by the taker.
    uint256 takerReceiveAmount;
    /// @dev Total fee charged to the taker.
    uint256 takerFeeAmount;
}

/// @title Exchange
/// @author Polymarket
/// @notice Exchange contract for trading outcome tokens via the PositionManager
contract Exchange is UUPSUpgradeable, Initializable, OwnableRoles, ERC1155TokenReceiver, EIP712 {
    using SafeTransferLib for address;

    /*--------------------------------------------------------------
                                 ERRORS
    --------------------------------------------------------------*/

    /// @notice Thrown when caller lacks operator role
    error NotOperator();

    /// @notice Thrown when trading is paused
    error Paused();

    /// @notice Thrown when the order maker is paused
    error UserIsPaused();

    /// @notice Thrown when the order is already fully filled
    error OrderAlreadyFilled();

    /// @notice Thrown when the order signature is invalid
    error InvalidSignature();

    /// @notice Thrown when an order token ID does not belong to the supplied condition
    error InvalidTokenId();

    /// @notice Thrown when complement validation fails
    error InvalidComplement();

    /// @notice Thrown when order prices do not cross
    error NotCrossing();

    /// @notice Thrown when maker/taker token IDs do not match
    error MismatchedTokenIds();

    /// @notice Thrown when fee exceeds the global max fee rate
    error FeeExceedsMaxRate();

    /// @notice Thrown when max fee rate exceeds the ceiling
    error MaxFeeRateExceedsCeiling();

    /// @notice Thrown when fill amount exceeds remaining
    error MakingGtRemaining();

    /// @notice Thrown when matchOrders is called without maker orders
    error NoMakerOrders();

    /// @notice Thrown when maker fill/fee arrays do not match maker order count
    error MismatchedArrayLengths();

    /// @notice Thrown when an order or fill uses a zero maker amount
    error ZeroMakerAmount();

    /// @notice Thrown when complementary execution consumes more taker making amount than requested
    error ComplementaryFillExceedsTakerFill();

    /// @notice Thrown when batch sell maker consumption does not match taker fill amount
    error TakerFillMismatch();

    /// @notice Thrown when batch settlement accounting does not balance
    error AssetAccountingMismatch();

    /// @notice Thrown when fee exceeds the order's proceeds
    error FeeExceedsProceeds();

    /// @notice Thrown when a user tries to pause but is already paused
    error UserAlreadyPaused();

    /// @notice Thrown when pause interval exceeds the maximum
    error ExceedsMaxPauseInterval();

    /*--------------------------------------------------------------
                                 EVENTS
    --------------------------------------------------------------*/

    /// @notice Emitted when an order is filled
    /// @param orderHash The EIP-712 hash of the filled order
    /// @param maker The address of the order maker
    /// @param taker The address of the order taker
    /// @param side The side of the order (BUY or SELL)
    /// @param tokenId The position token ID traded
    /// @param makerAmountFilled Amount filled in maker asset
    /// @param takerAmountFilled Amount filled in taker asset
    /// @param fee Fee charged for this fill
    /// @param builder Builder code of the filled order
    /// @param metadata Metadata hash of the filled order
    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed taker,
        Side side,
        PositionId tokenId,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled,
        uint256 fee,
        bytes32 builder,
        bytes32 metadata
    );

    /// @notice Emitted for the taker side of a matched trade
    /// @param takerOrderHash EIP-712 hash of the taker order
    /// @param takerOrderMaker Address of the taker
    /// @param side The taker's order side
    /// @param tokenId The taker's position token ID
    /// @param makerAmountFilled Taker's making amount filled
    /// @param takerAmountFilled Taker's taking amount filled
    event OrdersMatched(
        bytes32 indexed takerOrderHash,
        address indexed takerOrderMaker,
        Side side,
        PositionId tokenId,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled
    );

    /// @notice Emitted when fees are transferred to the receiver
    /// @param receiver The fee receiver address
    /// @param amount The total fee amount transferred
    event FeeCharged(address indexed receiver, uint256 amount);

    /// @notice Emitted when trading is paused
    /// @param pauser The address that paused trading
    event TradingPaused(address indexed pauser);

    /// @notice Emitted when trading is unpaused
    /// @param pauser The address that unpaused trading
    event TradingUnpaused(address indexed pauser);

    /// @notice Emitted when an order is preapproved
    /// @param orderHash The EIP-712 hash of the order
    event OrderPreapproved(bytes32 indexed orderHash);

    /// @notice Emitted when a preapproval is invalidated
    /// @param orderHash The EIP-712 hash of the order
    event OrderPreapprovalInvalidated(bytes32 indexed orderHash);

    /// @notice Emitted when a user schedules a pause
    /// @param user The user address
    /// @param effectivePauseBlock Block number when pause activates
    event UserPaused(address indexed user, uint256 effectivePauseBlock);

    /// @notice Emitted when a user cancels their pause
    /// @param user The user address
    event UserUnpaused(address indexed user);

    /// @notice Emitted when the user pause block interval changes
    /// @param oldInterval The previous interval
    /// @param newInterval The new interval
    event UserPauseBlockIntervalUpdated(uint256 oldInterval, uint256 newInterval);

    /*--------------------------------------------------------------
                               CONSTANTS
    --------------------------------------------------------------*/

    /// @dev Role flag for admin privileges
    uint256 internal constant ADMIN_ROLE = _ROLE_0;

    /// @dev Role flag for operator privileges
    uint256 internal constant OPERATOR_ROLE = _ROLE_1;

    /// @dev ERC-1271 magic return value for valid signatures
    bytes4 internal constant ERC1271_MAGIC_VALUE = 0x1626ba7e;

    /// @dev Denominator for basis points calculations
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Maximum allowed fee rate in basis points (100%)
    uint256 internal constant MAX_FEE_RATE_BPS_CAP = 10_000;

    /// @dev Maximum allowed user pause block interval (~5.6 days)
    uint256 internal constant MAX_PAUSE_BLOCK_INTERVAL = 302_400;

    /// @dev Event topic constants for assembly emission
    bytes32 private constant _ORDER_FILLED_TOPIC =
        keccak256("OrderFilled(bytes32,address,address,uint8,uint256,uint256,uint256,uint256,bytes32,bytes32)");
    bytes32 private constant _ORDERS_MATCHED_TOPIC =
        keccak256("OrdersMatched(bytes32,address,uint8,uint256,uint256,uint256)");
    bytes32 private constant _FEE_CHARGED_TOPIC = keccak256("FeeCharged(address,uint256)");

    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice The PositionManager used for token operations
    PositionManager public immutable POSITION_MANAGER;

    /// @notice The collateral token (e.g. PMCT) address
    address public immutable COLLATERAL_TOKEN;

    /// @notice The CombinatorialModule used for preparing combinatorial conditions
    address public immutable COMBINATORIAL_MODULE;

    /// @dev The Polymarket proxy wallet factory contract
    address internal immutable PROXY_FACTORY;

    /// @dev The Polymarket safe factory contract
    address internal immutable SAFE_FACTORY;

    /// @dev Keccak256 of the proxy wallet creation code
    bytes32 internal immutable PROXY_BYTECODE_HASH;

    /// @dev Keccak256 of the safe proxy creation code with implementation appended
    bytes32 internal immutable SAFE_BYTECODE_HASH;

    /// @notice Address that receives trading fees
    address public immutable FEE_RECEIVER;

    /// @notice Maximum fee rate in basis points
    uint256 public immutable MAX_FEE_RATE;

    /// @notice Whether trading is currently paused
    bool public paused;

    /// @notice Blocks before a user pause becomes effective
    uint256 public userPauseBlockInterval;

    /// @notice Order hash to fill status mapping
    mapping(bytes32 => OrderStatus) public orderStatus;

    /// @notice Block at which each user's pause becomes effective
    mapping(address => uint256) public userPausedBlockAt;

    /// @notice Order hashes that have been preapproved
    mapping(bytes32 => bool) public preapproved;

    /*--------------------------------------------------------------
                               MODIFIERS
    --------------------------------------------------------------*/

    /// @dev Restricts access to operator-role holders
    modifier onlyOperator() {
        if (!hasAnyRole(msg.sender, OPERATOR_ROLE)) revert NotOperator();
        _;
    }

    /// @dev Reverts if trading is paused
    modifier notPaused() {
        if (paused) revert Paused();
        _;
    }

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Deploys the Exchange implementation
    /// @param _positionManager PositionManager contract address
    /// @param _combinatorialModule CombinatorialModule contract address
    /// @param _feeReceiver Address that receives trading fees
    /// @param _maxFeeRate Maximum fee rate in basis points
    /// @param _proxyFactory Polymarket proxy wallet factory address
    /// @param _safeFactory Polymarket safe wallet factory address
    /// @param _proxyBytecodeHash Keccak256 of the proxy wallet creation code
    /// @param _safeBytecodeHash Keccak256 of the safe proxy creation code
    // forgefmt: disable-next-item
    constructor(
        address _positionManager,
        address _combinatorialModule,
        address _feeReceiver,
        uint256 _maxFeeRate,
        address _proxyFactory,
        address _safeFactory,
        bytes32 _proxyBytecodeHash,
        bytes32 _safeBytecodeHash
    ) {
        if (_maxFeeRate > MAX_FEE_RATE_BPS_CAP) revert MaxFeeRateExceedsCeiling();

        POSITION_MANAGER = PositionManager(_positionManager);
        COLLATERAL_TOKEN = POSITION_MANAGER.COLLATERAL_TOKEN();
        COMBINATORIAL_MODULE = _combinatorialModule;
        FEE_RECEIVER = _feeReceiver;
        MAX_FEE_RATE = _maxFeeRate;
        PROXY_FACTORY = _proxyFactory;
        SAFE_FACTORY = _safeFactory;
        PROXY_BYTECODE_HASH = _proxyBytecodeHash;
        SAFE_BYTECODE_HASH = _safeBytecodeHash;

        _disableInitializers();
    }

    /*--------------------------------------------------------------
                             INITIALIZER
    --------------------------------------------------------------*/

    /// @notice Initializes the contract with the given owner and admin.
    /// @param _owner The address to set as contract owner.
    /// @param _admin The address to grant the admin role.
    function initialize(address _owner, address _admin) external initializer {
        _initializeOwner(_owner);
        _grantRoles(_admin, ADMIN_ROLE);
        userPauseBlockInterval = 100;
    }

    /*--------------------------------------------------------------
                                 ADMIN
    --------------------------------------------------------------*/

    /// @notice Grants admin role to an address
    /// @param _admin Address to grant admin role
    function addAdmin(address _admin) external onlyOwner {
        _grantRoles(_admin, ADMIN_ROLE);
    }

    /// @notice Revokes admin role from an address
    /// @param _admin Address to revoke admin role from
    function removeAdmin(address _admin) external onlyOwner {
        _removeRoles(_admin, ADMIN_ROLE);
    }

    /// @notice Grants operator role to an address
    /// @param _operator Address to grant operator role
    function addOperator(address _operator) external onlyRoles(ADMIN_ROLE) {
        _grantRoles(_operator, OPERATOR_ROLE);
    }

    /// @notice Revokes operator role from an address
    /// @param _operator Address to revoke operator role from
    function removeOperator(address _operator) external onlyRoles(ADMIN_ROLE) {
        _removeRoles(_operator, OPERATOR_ROLE);
    }

    /// @notice Pauses all trading activity
    function pauseTrading() external onlyRoles(ADMIN_ROLE) {
        paused = true;
        emit TradingPaused(msg.sender);
    }

    /// @notice Unpauses trading activity
    function unpauseTrading() external onlyRoles(ADMIN_ROLE) {
        paused = false;
        emit TradingUnpaused(msg.sender);
    }

    /// @notice Sets the user pause block interval
    /// @param _interval New block interval
    function setUserPauseBlockInterval(uint256 _interval) external onlyRoles(ADMIN_ROLE) {
        if (_interval > MAX_PAUSE_BLOCK_INTERVAL) revert ExceedsMaxPauseInterval();
        uint256 oldInterval = userPauseBlockInterval;
        userPauseBlockInterval = _interval;
        emit UserPauseBlockIntervalUpdated(oldInterval, _interval);
    }

    /// @notice Preapproves an order, validating its signature now
    /// @dev After preapproval, signature checks are skipped
    /// @param order The order to preapprove
    function preapproveOrder(Order calldata order) external onlyOperator {
        bytes32 orderHash = _hashOrder(order);
        if (!_isValidSignature(orderHash, order)) revert InvalidSignature();
        preapproved[orderHash] = true;
        emit OrderPreapproved(orderHash);
    }

    /// @notice Invalidates a previously preapproved order
    /// @param orderHash The EIP-712 hash of the order
    function invalidatePreapprovedOrder(bytes32 orderHash) external onlyOperator {
        preapproved[orderHash] = false;
        emit OrderPreapprovalInvalidated(orderHash);
    }

    /*--------------------------------------------------------------
                                  VIEW
    --------------------------------------------------------------*/

    /// @notice Computes the EIP-712 hash of an order
    /// @param order The order to hash
    /// @return The EIP-712 typed data hash of the order
    function hashOrder(Order calldata order) external view returns (bytes32) {
        return _hashOrder(order);
    }

    /// @notice Returns the EIP-712 domain separator
    /// @return The cached or computed domain separator
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    /// @notice Returns whether an address has the admin role
    /// @param _usr The address to check
    /// @return True if the address is an admin
    function isAdmin(address _usr) external view returns (bool) {
        return hasAnyRole(_usr, ADMIN_ROLE);
    }

    /// @notice Returns whether an address has the operator role
    /// @param _usr The address to check
    /// @return True if the address is an operator
    function isOperator(address _usr) external view returns (bool) {
        return hasAnyRole(_usr, OPERATOR_ROLE);
    }

    /// @notice Checks if a user is currently paused
    /// @param _user The user address to check
    /// @return True if the user's pause is active
    function isUserPaused(address _user) public view returns (bool) {
        uint256 blockPausedAt = userPausedBlockAt[_user];
        return blockPausedAt > 0 && block.number >= blockPausedAt;
    }

    /// @notice Validates an order's status and signature
    /// @dev View-only; does not modify state
    /// @param order The order to validate
    function validateOrder(Order calldata order) external view {
        bytes32 orderHash = _hashOrder(order);

        OrderStatus storage status = orderStatus[orderHash];
        bool filled;
        assembly ("memory-safe") {
            let packed := sload(status.slot)
            filled := and(packed, 0xff)
        }

        if (filled) revert OrderAlreadyFilled();
        if (isUserPaused(order.maker)) revert UserIsPaused();
        _validateSignature(orderHash, order);
    }

    /// @notice Returns the fill status of an order
    /// @param orderHash The EIP-712 hash of the order
    /// @return status The order's fill status
    function getOrderStatus(bytes32 orderHash) external view returns (OrderStatus memory status) {
        OrderStatus storage stored = orderStatus[orderHash];
        bool filled;
        uint248 remaining;
        assembly ("memory-safe") {
            let packed := sload(stored.slot)
            filled := and(packed, 0xff)
            remaining := shr(8, packed)
        }
        status = OrderStatus(filled, remaining);
    }

    /// @notice Validates a fee against the global max fee rate
    /// @param fee The fee amount
    /// @param cashValue The collateral value of the trade
    function validateFee(uint256 fee, uint256 cashValue) external view {
        _validateFeeWithRate(fee, cashValue, MAX_FEE_RATE);
    }

    /// @notice Gets the Polymarket proxy wallet address for a signer
    /// @param _signer The signer address
    /// @return The derived proxy wallet address
    function getProxyWalletAddress(address _signer) external view returns (address) {
        return _getProxyWalletAddress(_signer);
    }

    /// @notice Gets the Polymarket Gnosis Safe address for a signer
    /// @param _signer The signer address
    /// @return The derived safe wallet address
    function getSafeWalletAddress(address _signer) external view returns (address) {
        return _getSafeWalletAddress(_signer);
    }

    /*--------------------------------------------------------------
                             USER ACTIONS
    --------------------------------------------------------------*/

    /// @notice Allows a user to schedule a pause on their account
    /// @dev Pause activates after userPauseBlockInterval blocks
    function pauseUser() external {
        if (userPausedBlockAt[msg.sender] != 0) revert UserAlreadyPaused();
        uint256 blockPausedAt = block.number + userPauseBlockInterval;
        userPausedBlockAt[msg.sender] = blockPausedAt;
        emit UserPaused(msg.sender, blockPausedAt);
    }

    /// @notice Allows a user to cancel their pause
    function unpauseUser() external {
        userPausedBlockAt[msg.sender] = 0;
        emit UserUnpaused(msg.sender);
    }

    /// @notice Allows an operator to renounce their operator role
    function renounceOperatorRole() external onlyOperator {
        _removeRoles(msg.sender, OPERATOR_ROLE);
    }

    /*--------------------------------------------------------------
                                TRADING
    --------------------------------------------------------------*/

    /// @notice Matches a taker order against multiple maker orders
    /// @param takerOrder The taker's order
    /// @param makerOrders Array of maker orders to match against
    /// @param makerFillAmounts Fill amounts for each maker order
    /// @param makerFeeAmounts Fees charged to each maker
    /// @param takerAmounts Bundled taker-side fill, receive, and fee amounts
    function matchOrders(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata makerFillAmounts,
        uint256[] calldata makerFeeAmounts,
        TakerAmounts calldata takerAmounts
    ) external onlyOperator notPaused {
        _matchOrders(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    }

    /// @notice Prepares a combinatorial condition, then matches a taker order against multiple maker orders
    /// @param takerOrder The taker's order
    /// @param makerOrders Array of maker orders to match against
    /// @param makerFillAmounts Fill amounts for each maker order
    /// @param makerFeeAmounts Fees charged to each maker
    /// @param takerAmounts Bundled taker-side fill, receive, and fee amounts
    /// @param combinatorialLegs Canonical leg array to prepare on the CombinatorialModule
    function matchOrdersAndPrepareCombinatorial(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata makerFillAmounts,
        uint256[] calldata makerFeeAmounts,
        TakerAmounts calldata takerAmounts,
        PositionId[] calldata combinatorialLegs
    ) external onlyOperator notPaused {
        ConditionId conditionId = CombinatorialModule(COMBINATORIAL_MODULE).prepareCondition(combinatorialLegs);
        require(conditionId == takerOrder.tokenId.conditionId(), InvalidTokenId());
        _matchOrders(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    }

    function _matchOrders(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata makerFillAmounts,
        uint256[] calldata makerFeeAmounts,
        TakerAmounts calldata takerAmounts
    ) internal {
        if (makerOrders.length == 0) revert NoMakerOrders();
        if (makerFillAmounts.length != makerOrders.length || makerFeeAmounts.length != makerOrders.length) {
            revert MismatchedArrayLengths();
        }
        if (takerOrder.tokenId.outcomeIndex() > 1) revert InvalidTokenId();

        MatchContext memory ctx = MatchContext({
            takerFillAmount: takerAmounts.takerFillAmount,
            takerFee: takerAmounts.takerFeeAmount,
            takerAddr: takerOrder.maker,
            moduleAddr: address(0),
            takerTokenId: takerOrder.tokenId,
            takerReceiveAmount: takerAmounts.takerReceiveAmount
        });

        if (_isAllComplementary(takerOrder, makerOrders)) {
            _matchComplementaryOrders(takerOrder, makerOrders, makerFillAmounts, ctx, makerFeeAmounts);
        } else {
            _matchBatchOrders(takerOrder, makerOrders, makerFillAmounts, ctx, makerFeeAmounts);
        }
    }

    /// @dev Emits OrderFilled and OrdersMatched for the taker order via assembly.
    function _emitTakerEvents(
        bytes32 takerHash,
        Order calldata takerOrder,
        uint256 takerFee,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled
    ) internal {
        _emitOrderFilled(takerHash, address(this), takerOrder, makerAmountFilled, takerAmountFilled, takerFee);
        bytes32 t = _ORDERS_MATCHED_TOPIC;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, calldataload(add(takerOrder, 0xc0)))
            mstore(add(m, 0x20), calldataload(add(takerOrder, 0x60)))
            mstore(add(m, 0x40), makerAmountFilled)
            mstore(add(m, 0x60), takerAmountFilled)
            log3(m, 0x80, t, takerHash, calldataload(add(takerOrder, 0x20)))
        }
    }

    /// @dev Matches complementary orders via the fast path.
    function _matchComplementaryOrders(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata makerFillAmounts,
        MatchContext memory ctx,
        uint256[] calldata makerFeeAmounts
    ) internal {
        bytes32 takerHash = _hashOrder(takerOrder);
        _validateOrder(takerHash, takerOrder, ctx.takerFillAmount, 0);
        uint256 takerMakingAmount;
        uint256 takerTakingAmount;
        uint256 totalFees;

        if (takerOrder.side == Side.BUY) {
            (takerMakingAmount, takerTakingAmount, totalFees) =
                _executeComplementaryBuyFastPath(takerOrder, makerOrders, makerFillAmounts, ctx, makerFeeAmounts);
        } else {
            bool zeroFeePath = ctx.takerFee == 0;
            if (zeroFeePath) {
                uint256 len = makerFeeAmounts.length;
                for (uint256 i; i < len; ++i) {
                    if (makerFeeAmounts[i] != 0) {
                        zeroFeePath = false;
                        break;
                    }
                }
            }

            if (zeroFeePath) {
                (takerMakingAmount, takerTakingAmount) =
                    _executeComplementaryZeroFeeSellFastPath(takerOrder, makerOrders, makerFillAmounts, ctx);
            } else {
                (takerMakingAmount, takerTakingAmount, totalFees) = _executeComplementarySellFastPath(
                    takerOrder, makerOrders, makerFillAmounts, ctx, makerFeeAmounts
                );
            }
        }

        if (takerTakingAmount != ctx.takerReceiveAmount) revert AssetAccountingMismatch();
        _validateFeeWithRate(
            ctx.takerFee, takerOrder.side == Side.BUY ? takerMakingAmount : takerTakingAmount, MAX_FEE_RATE
        );
        _updateOrderStatus(takerHash, takerOrder, _statusFillAmount(takerOrder, takerMakingAmount, takerTakingAmount));

        if (ctx.takerFee > 0) _emitFeeCharged(FEE_RECEIVER, ctx.takerFee);

        if (totalFees > 0) {
            if (takerOrder.side == Side.BUY) {
                COLLATERAL_TOKEN.safeTransferFrom(ctx.takerAddr, FEE_RECEIVER, totalFees);
            } else {
                COLLATERAL_TOKEN.safeTransfer(FEE_RECEIVER, totalFees);
            }
        }

        _emitTakerEvents(takerHash, takerOrder, ctx.takerFee, takerMakingAmount, takerTakingAmount);
    }

    /// @dev Matches orders via module split/merge batch path.
    function _matchBatchOrders(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata makerFillAmounts,
        MatchContext memory ctx,
        uint256[] calldata makerFeeAmounts
    ) internal {
        bytes32 takerHash = _hashOrder(takerOrder);
        _validateOrder(takerHash, takerOrder, ctx.takerFillAmount, 0);
        uint256 takerMakingAmount;
        uint256 takerTakingAmount;
        ctx.moduleAddr = POSITION_MANAGER.moduleById(ctx.takerTokenId.moduleId());
        if (takerOrder.side == Side.BUY) {
            (takerMakingAmount, takerTakingAmount) =
                _executeBatchBuyMatch(takerOrder, makerOrders, makerFillAmounts, ctx, makerFeeAmounts);
        } else {
            takerMakingAmount = ctx.takerFillAmount;
            takerTakingAmount = _executeBatchSellMatch(takerOrder, makerOrders, makerFillAmounts, ctx, makerFeeAmounts);
        }

        _validateFeeWithRate(
            ctx.takerFee, takerOrder.side == Side.BUY ? takerMakingAmount : takerTakingAmount, MAX_FEE_RATE
        );

        _updateOrderStatus(takerHash, takerOrder, _statusFillAmount(takerOrder, takerMakingAmount, takerTakingAmount));

        _emitTakerEvents(takerHash, takerOrder, ctx.takerFee, takerMakingAmount, takerTakingAmount);
    }

    /// @dev Executes a batch match where the taker is a buyer.
    function _executeBatchBuyMatch(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata fillAmounts,
        MatchContext memory ctx,
        uint256[] calldata makerFees
    ) internal returns (uint256 takerMakingAmount, uint256 takerTakingAmount) {
        COLLATERAL_TOKEN.safeTransferFrom(ctx.takerAddr, address(this), ctx.takerFillAmount + ctx.takerFee);
        BatchBuyAccounting memory a = BatchBuyAccounting({
            totalTakerTokenIn: 0, totalCollateralIn: ctx.takerFillAmount + ctx.takerFee, totalSellMakerNetOut: 0
        });

        uint256 totalMintAmount = _collectBuyMakersAssets(takerOrder, makerOrders, fillAmounts, makerFees, ctx, a);

        if (totalMintAmount > 0) {
            COLLATERAL_TOKEN.safeTransfer(ctx.moduleAddr, totalMintAmount);
            _split(ctx.moduleAddr, ctx.takerTokenId.conditionId(), totalMintAmount);
        }

        uint256 totalExchangeFees = ctx.takerFee;
        {
            uint256 len = makerOrders.length;
            for (uint256 i; i < len; ++i) {
                Order calldata makerOrder = makerOrders[i];
                uint256 takingAmount =
                    _calculateTakingAmount(fillAmounts[i], makerOrder.makerAmount, makerOrder.takerAmount);
                uint256 feeAmount = makerFees[i];

                totalExchangeFees += feeAmount;

                if (makerOrder.side == Side.SELL) {
                    if (feeAmount > takingAmount) revert FeeExceedsProceeds();
                    unchecked {
                        a.totalSellMakerNetOut += takingAmount - feeAmount;
                    }
                    COLLATERAL_TOKEN.safeTransfer(makerOrder.maker, takingAmount - feeAmount);
                } else {
                    POSITION_MANAGER.unsafeTransferFrom(
                        address(this), makerOrder.maker, makerOrder.tokenId, takingAmount
                    );
                }
                if (feeAmount > 0) _emitFeeCharged(FEE_RECEIVER, feeAmount);
            }
        }

        takerTakingAmount = a.totalTakerTokenIn;
        if (takerTakingAmount != ctx.takerReceiveAmount) revert AssetAccountingMismatch();
        POSITION_MANAGER.unsafeTransferFrom(address(this), ctx.takerAddr, ctx.takerTokenId, takerTakingAmount);

        if (a.totalCollateralIn < totalMintAmount + a.totalSellMakerNetOut) revert AssetAccountingMismatch();
        uint256 collateralRefund;
        unchecked {
            collateralRefund = a.totalCollateralIn - totalMintAmount - a.totalSellMakerNetOut;
        }
        if (collateralRefund < totalExchangeFees) revert AssetAccountingMismatch();

        unchecked {
            collateralRefund -= totalExchangeFees;
        }
        if (collateralRefund > ctx.takerFillAmount) revert AssetAccountingMismatch();
        takerMakingAmount = ctx.takerFillAmount - collateralRefund;

        if (totalExchangeFees > 0) COLLATERAL_TOKEN.safeTransfer(FEE_RECEIVER, totalExchangeFees);
        if (collateralRefund > 0) COLLATERAL_TOKEN.safeTransfer(ctx.takerAddr, collateralRefund);

        if (ctx.takerFee > 0) _emitFeeCharged(FEE_RECEIVER, ctx.takerFee);
    }

    /// @dev Executes a batch match where the taker is a seller.
    function _executeBatchSellMatch(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata fillAmounts,
        MatchContext memory ctx,
        uint256[] calldata makerFees
    ) internal returns (uint256 takerTakingAmount) {
        BatchSellAccounting memory a = BatchSellAccounting({ totalCollateralIn: 0, totalSellMakerNetOut: 0 });
        {
            uint256 totalMergeAmount = _collectSellMakersAssets(takerOrder, makerOrders, fillAmounts, makerFees, ctx, a);

            if (totalMergeAmount > 0) {
                POSITION_MANAGER.unsafeTransferFrom(ctx.takerAddr, ctx.moduleAddr, ctx.takerTokenId, totalMergeAmount);
                unchecked {
                    a.totalCollateralIn += totalMergeAmount;
                }
            }

            if (totalMergeAmount > 0) _merge(ctx.moduleAddr, ctx.takerTokenId.conditionId(), totalMergeAmount);
        }

        uint256 totalExchangeFees = ctx.takerFee;
        uint256 totalMakerFees;
        {
            uint256 len = makerOrders.length;
            for (uint256 i; i < len; ++i) {
                Order calldata makerOrder = makerOrders[i];
                uint256 takingAmount =
                    _calculateTakingAmount(fillAmounts[i], makerOrder.makerAmount, makerOrder.takerAmount);
                uint256 feeAmount = makerFees[i];

                totalExchangeFees += feeAmount;
                totalMakerFees += feeAmount;

                if (makerOrder.side == Side.BUY) {
                    POSITION_MANAGER.unsafeTransferFrom(ctx.takerAddr, makerOrder.maker, ctx.takerTokenId, takingAmount);
                } else {
                    if (feeAmount > takingAmount) revert FeeExceedsProceeds();
                    unchecked {
                        a.totalSellMakerNetOut += takingAmount - feeAmount;
                    }
                    COLLATERAL_TOKEN.safeTransfer(makerOrder.maker, takingAmount - feeAmount);
                }
                if (feeAmount > 0) _emitFeeCharged(FEE_RECEIVER, feeAmount);
            }
        }

        if (a.totalCollateralIn < a.totalSellMakerNetOut + totalMakerFees) revert AssetAccountingMismatch();
        unchecked {
            takerTakingAmount = a.totalCollateralIn - a.totalSellMakerNetOut - totalMakerFees;
        }
        if (takerTakingAmount != ctx.takerReceiveAmount) revert AssetAccountingMismatch();
        if (ctx.takerFee > takerTakingAmount) revert FeeExceedsProceeds();
        COLLATERAL_TOKEN.safeTransfer(ctx.takerAddr, takerTakingAmount - ctx.takerFee);

        if (totalExchangeFees > 0) COLLATERAL_TOKEN.safeTransfer(FEE_RECEIVER, totalExchangeFees);

        if (ctx.takerFee > 0) _emitFeeCharged(FEE_RECEIVER, ctx.takerFee);
    }

    /// @dev Checks if all makers are complementary to the taker
    /// @param takerOrder The taker order
    /// @param makerOrders Array of maker orders to check
    /// @return True if all makers have opposite side and same ID
    function _isAllComplementary(Order calldata takerOrder, Order[] calldata makerOrders) internal pure returns (bool) {
        uint256 len = makerOrders.length;
        Side takerSide = takerOrder.side;
        PositionId takerTokenId = takerOrder.tokenId;
        for (uint256 i; i < len; ++i) {
            Order calldata makerOrder = makerOrders[i];
            if (makerOrder.side == takerSide || makerOrder.tokenId != takerTokenId) return false;
        }
        return true;
    }

    /// @dev Executes the taker-BUY complementary fast path.
    function _executeComplementaryBuyFastPath(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata fillAmounts,
        MatchContext memory ctx,
        uint256[] calldata makerFees
    ) internal returns (uint256 takerMakingAmount, uint256 takerTakingAmount, uint256 totalFees) {
        totalFees = ctx.takerFee;

        for (uint256 i; i < makerOrders.length; ++i) {
            Order calldata m = makerOrders[i];
            if (takerOrder.makerAmount * m.makerAmount < takerOrder.takerAmount * m.takerAmount) {
                revert NotCrossing();
            }

            {
                uint256 fill = fillAmounts[i];
                uint256 fee = makerFees[i];
                bytes32 mHash = _validateAndUpdate(m, fill, fee);
                uint256 taking = _calculateTakingAmount(fill, m.makerAmount, m.takerAmount);

                POSITION_MANAGER.unsafeTransferFrom(m.maker, ctx.takerAddr, m.tokenId, fill);
                if (fee > taking) revert FeeExceedsProceeds();
                unchecked {
                    COLLATERAL_TOKEN.safeTransferFrom(ctx.takerAddr, m.maker, taking - fee);
                    totalFees += fee;
                    takerMakingAmount += taking;
                    takerTakingAmount += fill;
                }
                _emitOrderFilled(mHash, ctx.takerAddr, m, fill, taking, fee);
                if (fee > 0) _emitFeeCharged(FEE_RECEIVER, fee);
            }
        }

        if (takerMakingAmount > ctx.takerFillAmount) revert ComplementaryFillExceedsTakerFill();

        uint256 minimumTakerTakingAmount =
            _calculateTakingAmount(takerMakingAmount, takerOrder.makerAmount, takerOrder.takerAmount);
        if (takerTakingAmount < minimumTakerTakingAmount) revert NotCrossing();
    }

    /// @dev Executes the taker-SELL complementary fast path when any fee is present.
    function _executeComplementarySellFastPath(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata fillAmounts,
        MatchContext memory ctx,
        uint256[] calldata makerFees
    ) internal returns (uint256 takerMakingAmount, uint256 takerTakingAmount, uint256 totalFees) {
        totalFees = ctx.takerFee;
        uint256 totalCollateralIn;

        for (uint256 i; i < makerOrders.length; ++i) {
            Order calldata m = makerOrders[i];
            if (takerOrder.makerAmount * m.makerAmount < takerOrder.takerAmount * m.takerAmount) {
                revert NotCrossing();
            }

            {
                uint256 fill = fillAmounts[i];
                uint256 fee = makerFees[i];
                uint256 taking;
                {
                    bytes32 mHash = _validateAndUpdate(m, fill, fee);
                    taking = _calculateTakingAmount(fill, m.makerAmount, m.takerAmount);
                    _emitOrderFilled(mHash, ctx.takerAddr, m, fill, taking, fee);
                }

                COLLATERAL_TOKEN.safeTransferFrom(m.maker, address(this), fill + fee);
                POSITION_MANAGER.unsafeTransferFrom(ctx.takerAddr, m.maker, ctx.takerTokenId, taking);

                unchecked {
                    totalFees += fee;
                    takerMakingAmount += taking;
                    takerTakingAmount += fill;
                    totalCollateralIn += fill + fee;
                }
                if (fee > 0) _emitFeeCharged(FEE_RECEIVER, fee);
            }
        }

        if (takerMakingAmount > ctx.takerFillAmount) revert ComplementaryFillExceedsTakerFill();

        uint256 minimumTakerTakingAmount =
            _calculateTakingAmount(takerMakingAmount, takerOrder.makerAmount, takerOrder.takerAmount);
        if (takerTakingAmount < minimumTakerTakingAmount) revert NotCrossing();
        if (ctx.takerFee > takerTakingAmount) revert FeeExceedsProceeds();
        unchecked {
            COLLATERAL_TOKEN.safeTransfer(ctx.takerAddr, takerTakingAmount - ctx.takerFee);
        }
        if (totalCollateralIn < (takerTakingAmount - ctx.takerFee) + totalFees) revert AssetAccountingMismatch();
    }

    /// @dev Executes the taker-SELL complementary fast path when no fee is present.
    function _executeComplementaryZeroFeeSellFastPath(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata fillAmounts,
        MatchContext memory ctx
    ) internal returns (uint256 takerMakingAmount, uint256 takerTakingAmount) {
        for (uint256 i; i < makerOrders.length; ++i) {
            Order calldata m = makerOrders[i];
            if (takerOrder.makerAmount * m.makerAmount < takerOrder.takerAmount * m.takerAmount) {
                revert NotCrossing();
            }

            {
                uint256 fill = fillAmounts[i];
                bytes32 mHash = _validateAndUpdate(m, fill, 0);
                uint256 taking = _calculateTakingAmount(fill, m.makerAmount, m.takerAmount);

                POSITION_MANAGER.unsafeTransferFrom(ctx.takerAddr, m.maker, ctx.takerTokenId, taking);
                COLLATERAL_TOKEN.safeTransferFrom(m.maker, ctx.takerAddr, fill);

                unchecked {
                    takerMakingAmount += taking;
                    takerTakingAmount += fill;
                }
                _emitOrderFilled(mHash, ctx.takerAddr, m, fill, taking, 0);
            }
        }

        if (takerMakingAmount > ctx.takerFillAmount) revert ComplementaryFillExceedsTakerFill();

        uint256 minimumTakerTakingAmount =
            _calculateTakingAmount(takerMakingAmount, takerOrder.makerAmount, takerOrder.takerAmount);
        if (takerTakingAmount < minimumTakerTakingAmount) revert NotCrossing();
    }

    /// @dev Validates makers, transfers assets, accumulates totals
    /// @param takerOrder The taker order
    /// @param makerOrders Array of maker orders
    /// @param fillAmounts Fill amounts per maker
    /// @param makerFees Fee amounts per maker
    /// @param ctx Execution context for the match
    /// @return totalMintAmount Collateral to split into positions
    function _collectBuyMakersAssets(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata fillAmounts,
        uint256[] calldata makerFees,
        MatchContext memory ctx,
        BatchBuyAccounting memory a
    ) internal returns (uint256 totalMintAmount) {
        uint256 len = makerOrders.length;

        for (uint256 i; i < len; ++i) {
            Order calldata makerOrder = makerOrders[i];
            _validateTakerBuyMaker(takerOrder, makerOrder);
            uint256 fillAmount = fillAmounts[i];
            uint256 feeAmount = makerFees[i];
            bytes32 makerHash = _validateAndUpdate(makerOrder, fillAmount, feeAmount);
            uint256 takingAmount = _calculateTakingAmount(fillAmount, makerOrder.makerAmount, makerOrder.takerAmount);

            if (makerOrder.side == Side.BUY) {
                COLLATERAL_TOKEN.safeTransferFrom(makerOrder.maker, address(this), fillAmount + feeAmount);
                totalMintAmount += takingAmount;
                unchecked {
                    a.totalCollateralIn += fillAmount + feeAmount;
                }
            } else {
                POSITION_MANAGER.unsafeTransferFrom(makerOrder.maker, address(this), makerOrder.tokenId, fillAmount);
                unchecked {
                    a.totalTakerTokenIn += fillAmount;
                }
            }
            _emitOrderFilled(makerHash, ctx.takerAddr, makerOrder, fillAmount, takingAmount, feeAmount);
        }

        unchecked {
            a.totalTakerTokenIn += totalMintAmount;
        }
    }

    /// @dev Validates makers, transfers assets, accumulates totals.
    /// @return totalMergeAmount Positions to merge into collateral.
    function _collectSellMakersAssets(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256[] calldata fillAmounts,
        uint256[] calldata makerFees,
        MatchContext memory ctx,
        BatchSellAccounting memory a
    ) internal returns (uint256 totalMergeAmount) {
        uint256 len = makerOrders.length;
        uint256 remainingTakerFill = ctx.takerFillAmount;

        for (uint256 i; i < len; ++i) {
            Order calldata makerOrder = makerOrders[i];
            _validateTakerSellMaker(takerOrder, makerOrder);
            uint256 fillAmount = fillAmounts[i];
            uint256 feeAmount = makerFees[i];
            bytes32 makerHash = _validateAndUpdate(makerOrder, fillAmount, feeAmount);
            uint256 takingAmount = _calculateTakingAmount(fillAmount, makerOrder.makerAmount, makerOrder.takerAmount);

            if (makerOrder.side == Side.BUY) {
                COLLATERAL_TOKEN.safeTransferFrom(makerOrder.maker, address(this), fillAmount + feeAmount);
                unchecked {
                    a.totalCollateralIn += fillAmount + feeAmount;
                }
                remainingTakerFill -= takingAmount;
            } else {
                POSITION_MANAGER.unsafeTransferFrom(makerOrder.maker, ctx.moduleAddr, makerOrder.tokenId, fillAmount);
                totalMergeAmount += fillAmount;
                remainingTakerFill -= fillAmount;
            }
            _emitOrderFilled(makerHash, ctx.takerAddr, makerOrder, fillAmount, takingAmount, feeAmount);
        }
        if (remainingTakerFill != 0) revert TakerFillMismatch();
    }

    /// @dev Validates a maker order against a BUY taker order
    /// @param takerOrder The taker BUY order
    /// @param makerOrder The maker order to validate
    function _validateTakerBuyMaker(Order calldata takerOrder, Order calldata makerOrder) internal pure {
        if (makerOrder.side == Side.SELL) {
            if (takerOrder.tokenId != makerOrder.tokenId) revert MismatchedTokenIds();
            if (takerOrder.makerAmount * makerOrder.makerAmount < takerOrder.takerAmount * makerOrder.takerAmount) {
                revert NotCrossing();
            }
            return;
        }

        ConditionId takerConditionId = takerOrder.tokenId.conditionId();
        ConditionId makerConditionId = makerOrder.tokenId.conditionId();
        if (makerConditionId != takerConditionId) revert InvalidComplement();

        uint256 takerOutcomeIndex = takerOrder.tokenId.outcomeIndex();
        uint256 makerOutcomeIndex = makerOrder.tokenId.outcomeIndex();
        if (makerOutcomeIndex + takerOutcomeIndex != 1) revert InvalidComplement();

        if (
            takerOrder.takerAmount * makerOrder.makerAmount + makerOrder.takerAmount * takerOrder.makerAmount
                < takerOrder.takerAmount * makerOrder.takerAmount
        ) revert NotCrossing();
    }

    /// @dev Validates a maker order against a SELL taker order
    /// @param takerOrder The taker SELL order
    /// @param makerOrder The maker order to validate
    function _validateTakerSellMaker(Order calldata takerOrder, Order calldata makerOrder) internal pure {
        if (makerOrder.side == Side.BUY) {
            if (takerOrder.tokenId != makerOrder.tokenId) revert MismatchedTokenIds();
            if (takerOrder.makerAmount * makerOrder.makerAmount < takerOrder.takerAmount * makerOrder.takerAmount) {
                revert NotCrossing();
            }
            return;
        }

        ConditionId takerConditionId = takerOrder.tokenId.conditionId();
        ConditionId makerConditionId = makerOrder.tokenId.conditionId();
        if (makerConditionId != takerConditionId) revert InvalidComplement();

        uint256 takerOutcomeIndex = takerOrder.tokenId.outcomeIndex();
        uint256 makerOutcomeIndex = makerOrder.tokenId.outcomeIndex();
        if (makerOutcomeIndex + takerOutcomeIndex != 1) revert InvalidComplement();

        if (
            takerOrder.takerAmount * makerOrder.makerAmount + makerOrder.takerAmount * takerOrder.makerAmount
                > takerOrder.makerAmount * makerOrder.makerAmount
        ) revert NotCrossing();
    }

    /// @dev Splits collateral into outcome positions via the module
    /// @param moduleAddr Address of the module to call
    /// @param conditionId The condition ID for the split
    /// @param amount Amount of collateral to split
    function _split(address moduleAddr, ConditionId conditionId, uint256 amount) internal {
        // Build address[] without Solidity's zero-initialization overhead
        address[] memory to;
        assembly ("memory-safe") {
            to := mload(0x40)
            mstore(to, 2)
            mstore(add(to, 0x20), address())
            mstore(add(to, 0x40), address())
            mstore(0x40, add(to, 0x60))
        }

        BaseModule(moduleAddr).split(to, conditionId, amount);
    }

    /// @dev Merges outcome positions back into collateral
    /// @param moduleAddr Address of the module to call
    /// @param conditionId The condition ID for the merge
    /// @param amount Amount of positions to merge
    function _merge(address moduleAddr, ConditionId conditionId, uint256 amount) internal {
        BaseModule(moduleAddr).merge(address(this), conditionId, amount);
    }

    /// @dev Computes the taking amount from the making amount and ratio.
    function _calculateTakingAmount(uint256 makingAmount, uint256 makerAmount, uint256 takerAmount)
        internal
        pure
        returns (uint256)
    {
        return makingAmount * takerAmount / makerAmount;
    }

    /// @dev Limit BUYs consume live share size; store the maker-amount equivalent.
    function _statusFillAmount(Order calldata order, uint256 makingAmount, uint256 takingAmount)
        internal
        pure
        returns (uint256)
    {
        if (order.side == Side.BUY) return takingAmount * order.makerAmount / order.takerAmount;
        return makingAmount;
    }

    /*--------------------------------------------------------------
                                INTERNAL
    --------------------------------------------------------------*/

    /// @dev Emits FeeCharged via assembly log2.
    function _emitFeeCharged(address receiver, uint256 amount) internal {
        bytes32 t = _FEE_CHARGED_TOPIC;
        assembly ("memory-safe") {
            mstore(0x00, amount)
            log2(0x00, 0x20, t, receiver)
        }
    }

    /// @dev Emits OrderFilled via assembly log4.
    function _emitOrderFilled(
        bytes32 orderHash,
        address taker,
        Order calldata order,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled,
        uint256 fee
    ) internal {
        bytes32 t = _ORDER_FILLED_TOPIC;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, calldataload(add(order, 0xc0)))
            mstore(add(m, 0x20), calldataload(add(order, 0x60)))
            mstore(add(m, 0x40), makerAmountFilled)
            mstore(add(m, 0x60), takerAmountFilled)
            mstore(add(m, 0x80), fee)
            mstore(add(m, 0xa0), calldataload(add(order, 0x140)))
            mstore(add(m, 0xc0), calldataload(add(order, 0x120)))
            log4(m, 0xe0, t, orderHash, calldataload(add(order, 0x20)), taker)
        }
    }

    /// @dev Validates an order and updates its fill status
    /// @param order The order to validate and update
    /// @param fillAmount Amount to fill in this execution
    /// @param fee Fee amount for this fill
    /// @return The EIP-712 hash of the order
    function _validateAndUpdate(Order calldata order, uint256 fillAmount, uint256 fee) internal returns (bytes32) {
        bytes32 orderHash = _hashOrder(order);
        uint256 remaining = _validateOrder(orderHash, order, fillAmount, fee);
        unchecked {
            remaining -= fillAmount;
        }
        _storeOrderStatus(orderHash, remaining);
        return orderHash;
    }

    /// @dev Validates order state, signature, and fee bounds.
    function _validateOrder(bytes32 orderHash, Order calldata order, uint256 fillAmount, uint256 fee)
        internal
        view
        returns (uint256 remaining)
    {
        OrderStatus storage status = orderStatus[orderHash];
        bool filled;

        assembly ("memory-safe") {
            let packed := sload(status.slot)
            filled := and(packed, 0xff)
            remaining := shr(8, packed)
        }

        if (isUserPaused(order.maker)) revert UserIsPaused();
        if (filled) revert OrderAlreadyFilled();
        if (order.makerAmount == 0 || fillAmount == 0) revert ZeroMakerAmount();
        remaining = remaining == 0 ? order.makerAmount : remaining;
        if (fillAmount > remaining) revert MakingGtRemaining();

        _validateSignature(orderHash, order);

        _validateFeeRate(fee, fillAmount, order);
    }

    /// @dev Validates fee does not exceed the global max fee rate.
    /// @param fee The fee amount in collateral
    /// @param fillAmount The fill amount (maker's making amount)
    /// @param order The order being filled
    function _validateFeeRate(uint256 fee, uint256 fillAmount, Order calldata order) internal view {
        if (fee == 0) return;
        uint256 _maxFeeRate = MAX_FEE_RATE;
        if (_maxFeeRate == 0) return;

        uint256 cashValue;
        if (order.side == Side.BUY) cashValue = fillAmount;
        else cashValue = fillAmount * order.takerAmount / order.makerAmount;

        uint256 maxAllowedFee = (cashValue * _maxFeeRate) / BPS_DENOMINATOR;
        if (fee > maxAllowedFee) revert FeeExceedsMaxRate();
    }

    /// @dev Validates fee against a given max rate and cash value.
    function _validateFeeWithRate(uint256 fee, uint256 cashValue, uint256 rate) internal pure {
        if (fee == 0) return;
        if (rate == 0) return;
        uint256 maxAllowedFee = (cashValue * rate) / BPS_DENOMINATOR;
        if (fee > maxAllowedFee) revert FeeExceedsMaxRate();
    }

    /// @dev Updates order remaining amount after a complementary fill.
    function _updateOrderStatus(bytes32 orderHash, Order calldata order, uint256 fillAmount) internal {
        OrderStatus storage status = orderStatus[orderHash];
        uint256 remaining;

        assembly ("memory-safe") {
            let packed := sload(status.slot)
            remaining := shr(8, packed)
        }

        remaining = remaining == 0 ? order.makerAmount : remaining;
        if (fillAmount > remaining) revert MakingGtRemaining();

        unchecked {
            remaining -= fillAmount;
        }

        _storeOrderStatus(orderHash, remaining);
    }

    /// @dev Stores the remaining amount and filled flag in one slot.
    function _storeOrderStatus(bytes32 orderHash, uint256 remaining) internal {
        OrderStatus storage status = orderStatus[orderHash];

        assembly ("memory-safe") {
            sstore(status.slot, or(shl(8, remaining), iszero(remaining)))
        }
    }

    /// @dev Computes the EIP-712 typed data hash of an order
    /// @param order The order to hash
    /// @return The EIP-712 hash
    function _hashOrder(Order calldata order) internal view returns (bytes32) {
        return _hashTypedData(_computeStructHash(order));
    }

    /// @dev Computes the EIP-712 struct hash of an order
    /// @param order The order to compute the struct hash for
    /// @return result The keccak256 struct hash
    function _computeStructHash(Order calldata order) private pure returns (bytes32 result) {
        bytes32 typeHash = ORDER_TYPEHASH;
        assembly {
            // Allocate memory for encoding: 12 * 32 = 384 bytes
            let ptr := mload(0x40)
            mstore(ptr, typeHash) // ORDER_TYPEHASH
            mstore(add(ptr, 0x20), calldataload(order)) // salt
            mstore(add(ptr, 0x40), calldataload(add(order, 0x20))) // maker
            mstore(add(ptr, 0x60), calldataload(add(order, 0x40))) // signer
            mstore(add(ptr, 0x80), calldataload(add(order, 0x60))) // tokenId
            mstore(add(ptr, 0xa0), calldataload(add(order, 0x80))) // makerAmount
            mstore(add(ptr, 0xc0), calldataload(add(order, 0xa0))) // takerAmount
            mstore(add(ptr, 0xe0), calldataload(add(order, 0xc0))) // side
            mstore(add(ptr, 0x100), calldataload(add(order, 0xe0))) // signatureType
            mstore(add(ptr, 0x120), calldataload(add(order, 0x100))) // timestamp
            mstore(add(ptr, 0x140), calldataload(add(order, 0x120))) // metadata
            mstore(add(ptr, 0x160), calldataload(add(order, 0x140))) // builder
            result := keccak256(ptr, 0x180) // 12 * 32 = 384 = 0x180
        }
    }

    /// @dev Returns the EIP-712 domain name and version
    /// @return name The domain name
    /// @return version The domain version
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "Polymarket CTF Exchange";
        version = "3";
    }

    /// @dev Validates order signature or preapproval status.
    /// @dev Empty signatures are only valid for preapproved orders.
    /// @param orderHash The EIP-712 hash of the order
    /// @param order The order whose signature to validate
    function _validateSignature(bytes32 orderHash, Order calldata order) internal view {
        if (order.signature.length == 0) {
            if (preapproved[orderHash]) return;
            revert InvalidSignature();
        }
        if (!_isValidSignature(orderHash, order)) revert InvalidSignature();
    }

    /// @dev Checks if the order signature is valid
    /// @param orderHash The EIP-712 hash of the order
    /// @param order The order whose signature to check
    /// @return True if the signature is valid
    function _isValidSignature(bytes32 orderHash, Order calldata order) internal view returns (bool) {
        if (order.signatureType == SignatureType.EOA) {
            return order.signer == order.maker && _isValidEOASignature(orderHash, order.signer, order.signature);
        }
        if (order.signatureType == SignatureType.POLY_1271) {
            return order.signer == order.maker && order.maker.code.length > 0
                && _isValidERC1271(order.maker, orderHash, order.signature);
        }
        if (order.signatureType == SignatureType.POLY_PROXY) {
            return _isValidEOASignature(orderHash, order.signer, order.signature)
                && _getProxyWalletAddress(order.signer) == order.maker;
        }
        if (order.signatureType == SignatureType.POLY_GNOSIS_SAFE) {
            return _isValidEOASignature(orderHash, order.signer, order.signature)
                && _getSafeWalletAddress(order.signer) == order.maker;
        }
        return false;
    }

    /// @dev Validates an EOA signature via ecrecover
    /// @param hash The message hash that was signed
    /// @param maker Expected signer address
    /// @param sig The 65-byte ECDSA signature
    /// @return True if ecrecover matches the maker
    function _isValidEOASignature(bytes32 hash, address maker, bytes calldata sig) internal pure returns (bool) {
        if (sig.length != 65) return false;

        uint8 v;
        bytes32 r;
        bytes32 s;

        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 0x20))
            v := byte(0, calldataload(add(sig.offset, 0x40)))
        }

        if (v < 27) v += 27;
        if (v != 27 && v != 28) return false;

        address recovered = ecrecover(hash, v, r, s);
        return recovered != address(0) && recovered == maker;
    }

    /// @dev Validates an ERC-1271 contract signature.
    ///      Uses a low-level staticcall so we can cap the returndata copy at
    ///      32 bytes. A naive high-level staticcall copies the full
    ///      returndata into memory, letting a malicious signer grief the
    ///      caller via oversized return payloads. The output slot `d`
    ///      holds the ABI offset `0x40` before the call; if the signer
    ///      returns fewer than 32 bytes `d` keeps that constant, so the
    ///      equality check below cleanly rejects short returns.
    /// @param signer The contract address to validate against
    /// @param hash The message hash that was signed
    /// @param sig The signature bytes
    /// @return isValid True if the contract returns the magic value
    function _isValidERC1271(address signer, bytes32 hash, bytes calldata sig) internal view returns (bool isValid) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            // `isValidSignature(bytes32,bytes)` selector in the top 4 bytes.
            let f := shl(224, 0x1626ba7e)
            mstore(m, f)
            mstore(add(m, 0x04), hash)
            let d := add(m, 0x24)
            mstore(d, 0x40) // Offset of `signature` in the ABI-encoded call.
            mstore(add(m, 0x44), sig.length)
            calldatacopy(add(m, 0x64), sig.offset, sig.length)
            isValid := staticcall(gas(), signer, m, add(sig.length, 0x64), d, 0x20)
            isValid := and(eq(mload(d), f), isValid)
        }
    }

    function _getProxyWalletAddress(address signer) internal view returns (address) {
        return _computeCreate2Address(PROXY_FACTORY, PROXY_BYTECODE_HASH, _proxySalt(signer));
    }

    function _getSafeWalletAddress(address signer) internal view returns (address) {
        return _computeCreate2Address(SAFE_FACTORY, SAFE_BYTECODE_HASH, _safeSalt(signer));
    }

    function _proxySalt(address signer) internal pure returns (bytes32 salt) {
        assembly ("memory-safe") {
            mstore(0x20, signer)
            salt := keccak256(44, 20)
        }
    }

    function _safeSalt(address signer) internal pure returns (bytes32 salt) {
        assembly ("memory-safe") {
            mstore(0x00, signer)
            salt := keccak256(0x00, 0x20)
        }
    }

    function _computeCreate2Address(address deployer, bytes32 bytecodeHash, bytes32 salt)
        internal
        pure
        returns (address result)
    {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, or(0xff00000000000000000000000000000000000000000000000000000000000000, shl(88, deployer)))
            mstore(add(ptr, 21), salt)
            mstore(add(ptr, 53), bytecodeHash)
            result := and(keccak256(ptr, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /*--------------------------------------------------------------
                         UUPS UPGRADE AUTHORIZATION
    --------------------------------------------------------------*/

    /// @dev Restricts upgrades to the contract owner.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner { }
}
