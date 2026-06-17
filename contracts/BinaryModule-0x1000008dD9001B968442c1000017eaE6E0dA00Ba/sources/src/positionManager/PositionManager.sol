// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { ERC1155 } from "@solady/src/tokens/ERC1155.sol";
import { Initializable } from "@solady/src/utils/Initializable.sol";
import { UUPSUpgradeable } from "@solady/src/utils/UUPSUpgradeable.sol";

import { InitializableRoles } from "@polymarket-v2/src/auth/InitializableRoles.sol";
import { ConditionId, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";

import { BaseModule } from "@polymarket-v2/src/modules/abstract/BaseModule.sol";

abstract contract PositionManagerErrors {
    /// @notice Thrown when a module is not registered
    error ModuleNotRegistered();

    /// @notice Thrown when a module is already registered
    error ModuleAlreadyRegistered();

    /// @notice Thrown when a module reports an invalid ID
    error InvalidModuleId();
}

abstract contract PositionManagerEvents {
    /// @notice Emitted when a module is registered
    /// @param moduleId The numeric module identifier
    /// @param module The module contract address
    event ModuleAdded(uint256 indexed moduleId, address indexed module);

    /// @notice Emitted when a module is unregistered
    /// @param moduleId The numeric module identifier
    /// @param module The module contract address
    event ModuleRemoved(uint256 indexed moduleId, address indexed module);

    /// @notice Emitted when cross-module authorization is changed
    /// @param module The module address
    /// @param authorized Whether the module is authorized
    event CrossModuleAuthSet(address indexed module, bool authorized);
}

/// @title PositionManager
/// @author Polymarket
/// @notice ERC1155 position manager with module-based authorization
/// @dev Module ID is encoded in position IDs, enabling O(1) authorization without storage lookup
contract PositionManager is
    UUPSUpgradeable,
    Initializable,
    ERC1155,
    InitializableRoles,
    PositionManagerErrors,
    PositionManagerEvents
{
    /*--------------------------------------------------------------
                               CONSTANTS
    --------------------------------------------------------------*/

    /// @dev ERC1155 master slot seed, same as Solady's ERC1155 storage layout.
    uint256 private constant _ERC1155_MASTER_SLOT_SEED = 0x9a31110384e0b0c9;

    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice The collateral token (e.g. PMCT) address
    address public immutable COLLATERAL_TOKEN;

    /// @notice moduleId => module address
    mapping(uint256 => address) public moduleById;

    /// @notice Whether a module is authorized to mint/burn positions for any module.
    mapping(address => bool) public crossModuleAuth;

    /*--------------------------------------------------------------
                               MODIFIERS
    --------------------------------------------------------------*/

    /// @notice Requires caller to be the module that owns this position, or cross-module authorized
    /// @dev Fast path: moduleById lookup. Fallback: crossModuleAuth flag.
    modifier onlyModuleByPositionId(PositionId _positionId) {
        uint256 moduleId = _positionId.moduleId();
        require(moduleById[moduleId] == msg.sender || crossModuleAuth[msg.sender], Unauthorized());
        _;
    }

    /// @notice Requires caller to be the module that owns all positions, or cross-module authorized
    /// @dev Checks crossModuleAuth lazily on first mismatch, then breaks.
    modifier onlyModuleByPositionIds(PositionId[] calldata _positionIds) {
        uint256 positionIdsLength = _positionIds.length;
        for (uint256 i = 0; i < positionIdsLength; ++i) {
            uint256 moduleId = _positionIds[i].moduleId();
            if (moduleById[moduleId] != msg.sender) {
                require(crossModuleAuth[msg.sender], Unauthorized());
                break;
            }
        }
        _;
    }

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Deploys the PositionManager implementation
    /// @param _collateralToken Address of the collateral token
    constructor(address _collateralToken) {
        COLLATERAL_TOKEN = _collateralToken;

        _disableInitializers();
    }

    /*--------------------------------------------------------------
                             INITIALIZER
    --------------------------------------------------------------*/

    /// @notice Initializes the contract with the given owner.
    /// @dev This replaces the constructor for upgradeable contracts.
    /// @param _owner The address to set as the owner of the contract.
    /// @param _admin The address to set as the admin of the contract.
    function initialize(address _owner, address _admin) external initializer {
        _initializeOwner(_owner);
        _grantRoles(_admin, _ROLE_0);
    }

    /*--------------------------------------------------------------
                                  VIEW
    --------------------------------------------------------------*/

    /// @notice Returns the metadata URI for a position token
    /// @dev Returns the ERC-1155 templated URI. Clients substitute `{id}` with the lowercase
    /// hex-encoded token ID, zero-padded to 64 characters, per EIP-1155. Reverts if the
    /// position's module is not registered, preventing metadata lookups for non-existent IDs.
    /// @param _positionId The position token ID
    /// @return The metadata URI template string
    function uri(uint256 _positionId) public view override returns (string memory) {
        uint256 modId = PositionId.wrap(_positionId).moduleId();
        require(moduleById[modId] != address(0), ModuleNotRegistered());
        return "https://polymarket.com/position/{id}";
    }

    /// @notice Returns balance by condition ID and outcome index
    /// @dev Callers that want soft "balance for arbitrary token id" behavior should use the
    ///      inherited ERC1155 `balanceOf(address, uint256)` directly with a precomputed
    ///      position id.
    /// @param _owner The token owner address
    /// @param _conditionId The condition identifier
    /// @param _outcomeIndex The outcome index (0 or 1)
    /// @return The token balance of the owner
    function balanceOf(address _owner, ConditionId _conditionId, uint256 _outcomeIndex)
        external
        view
        returns (uint256)
    {
        return balanceOf(_owner, PositionId.unwrap(_conditionId.computePositionId(_outcomeIndex)));
    }

    /// @notice Computes the payout for redeeming a position
    /// @param _positionId The position token ID
    /// @param _amount The amount of tokens to redeem
    /// @return The collateral payout amount
    function getPayout(PositionId _positionId, uint256 _amount) external view returns (uint256) {
        uint256 modId = _positionId.moduleId();
        address module = moduleById[modId];
        require(module != address(0), ModuleNotRegistered());
        return BaseModule(module).getPayout(_positionId, _amount);
    }

    /*--------------------------------------------------------------
                              ONLY MODULE
    --------------------------------------------------------------*/

    /// @notice Mints position tokens to an address
    /// @dev Does not call onERC1155Received on the recipient. Uses precomputed OR of
    ///      `_ERC1155_MASTER_SLOT_SEED` and `_to` to derive the balance slot in one MSTORE.
    ///      Modified from Solady's ERC1155 _mint at 90db92c.
    /// @param _to Recipient address
    /// @param _positionId The position token ID to mint
    /// @param _amount Amount of tokens to mint
    function mint(address _to, PositionId _positionId, uint256 _amount) external onlyModuleByPositionId(_positionId) {
        assembly ("memory-safe") {
            let toSlotSeed := or(_ERC1155_MASTER_SLOT_SEED, shl(96, _to))
            // Revert if `_to` is the zero address.
            if iszero(shr(96, toSlotSeed)) {
                mstore(0x00, 0xea553b34) // `TransferToZeroAddress()`.
                revert(0x1c, 0x04)
            }
            // Increase and store the updated balance of `_to`.
            mstore(0x20, toSlotSeed)
            mstore(0x00, _positionId)
            let toBalanceSlot := keccak256(0x00, 0x40)
            let toBalanceBefore := sload(toBalanceSlot)
            let toBalanceAfter := add(toBalanceBefore, _amount)
            if lt(toBalanceAfter, toBalanceBefore) {
                mstore(0x00, 0x01336cea) // `AccountBalanceOverflow()`.
                revert(0x1c, 0x04)
            }
            sstore(toBalanceSlot, toBalanceAfter)
            // Emit a {TransferSingle} event. `_positionId` is already at 0x00.
            mstore(0x20, _amount)
            // forgefmt: disable-next-line
            log4(0x00, 0x40, 0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62, caller(), 0, _to)
        }
    }

    /// @notice Batch mints position tokens to an address
    /// @dev Does not call onERC1155BatchReceived on the recipient. Uses precomputed OR of
    ///      `_ERC1155_MASTER_SLOT_SEED` and `_to` to derive balance slots across the loop.
    ///      Modified from Solady's ERC1155 _batchMint at 90db92c.
    /// @param _to Recipient address
    /// @param _positionIds Array of position token IDs to mint
    /// @param _amounts Array of amounts to mint per ID
    function batchMint(address _to, PositionId[] calldata _positionIds, uint256[] calldata _amounts)
        external
        onlyModuleByPositionIds(_positionIds)
    {
        assembly ("memory-safe") {
            if iszero(eq(_positionIds.length, _amounts.length)) {
                mstore(0x00, 0x3b800a46) // `ArrayLengthsMismatch()`.
                revert(0x1c, 0x04)
            }
            let toSlotSeed := or(_ERC1155_MASTER_SLOT_SEED, shl(96, _to))
            // Revert if `_to` is the zero address.
            if iszero(shr(96, toSlotSeed)) {
                mstore(0x00, 0xea553b34) // `TransferToZeroAddress()`.
                revert(0x1c, 0x04)
            }
            // Loop through all the `_positionIds` and update the balances.
            {
                mstore(0x20, toSlotSeed)
                for { let i := shl(5, _positionIds.length) } i { } {
                    i := sub(i, 0x20)
                    let amount := calldataload(add(_amounts.offset, i))
                    // Increase and store the updated balance of `_to`.
                    mstore(0x00, calldataload(add(_positionIds.offset, i)))
                    let toBalanceSlot := keccak256(0x00, 0x40)
                    let toBalanceBefore := sload(toBalanceSlot)
                    let toBalanceAfter := add(toBalanceBefore, amount)
                    if lt(toBalanceAfter, toBalanceBefore) {
                        mstore(0x00, 0x01336cea) // `AccountBalanceOverflow()`.
                        revert(0x1c, 0x04)
                    }
                    sstore(toBalanceSlot, toBalanceAfter)
                }
            }
            // Emit a {TransferBatch} event.
            {
                let m := mload(0x40)
                // Copy the `_positionIds`.
                mstore(m, 0x40)
                let n := shl(5, _positionIds.length)
                mstore(add(m, 0x40), _positionIds.length)
                calldatacopy(add(m, 0x60), _positionIds.offset, n)
                // Copy the `_amounts`.
                mstore(add(m, 0x20), add(0x60, n))
                let o := add(add(m, n), 0x60)
                mstore(o, _amounts.length)
                calldatacopy(add(o, 0x20), _amounts.offset, n)
                // Do the emit.
                // forgefmt: disable-next-line
                log4(m, add(add(n, n), 0x80), 0x4a39dc06d4c0dbc64b70af90fd698a233a518aa5d07e595d983b8c0526c8f7fb, caller(), 0, _to)
            }
        }
    }

    /// @notice Burns position tokens held by the calling module
    /// @param _positionId The position token ID to burn
    /// @param _amount Amount of tokens to burn
    function burn(PositionId _positionId, uint256 _amount) external onlyModuleByPositionId(_positionId) {
        _burn(msg.sender, PositionId.unwrap(_positionId), _amount);
    }

    /// @notice Batch burns position tokens held by the calling module
    /// @param _positionIds Array of position token IDs to burn
    /// @param _amounts Array of amounts to burn per ID
    function batchBurn(PositionId[] calldata _positionIds, uint256[] calldata _amounts)
        external
        onlyModuleByPositionIds(_positionIds)
    {
        uint256[] calldata positionIds;
        assembly {
            positionIds.offset := _positionIds.offset
            positionIds.length := _positionIds.length
        }

        _batchBurn(msg.sender, positionIds, _amounts);
    }

    /*--------------------------------------------------------------
                            UNSAFE TRANSFERS
    --------------------------------------------------------------*/

    /// @notice Transfers `amount` of token `id` from `from` to `to`
    ///         without calling onERC1155Received on the recipient.
    /// @dev Identical to Solady's safeTransferFrom assembly with the
    ///      onERC1155Received callback and before/after hooks removed.
    ///      The caller must be `from` or approved via setApprovalForAll.
    function unsafeTransferFrom(address from, address to, PositionId id, uint256 amount) external {
        assembly ("memory-safe") {
            let fromSlotSeed := or(_ERC1155_MASTER_SLOT_SEED, shl(96, from))
            let toSlotSeed := or(_ERC1155_MASTER_SLOT_SEED, shl(96, to))
            mstore(0x20, fromSlotSeed)
            // Clear the upper 96 bits.
            from := shr(96, fromSlotSeed)
            to := shr(96, toSlotSeed)
            // Revert if `to` is the zero address.
            if iszero(to) {
                mstore(0x00, 0xea553b34) // `TransferToZeroAddress()`.
                revert(0x1c, 0x04)
            }
            // If the caller is not `from`, do the authorization check.
            if iszero(eq(caller(), from)) {
                mstore(0x00, caller())
                if iszero(sload(keccak256(0x0c, 0x34))) {
                    mstore(0x00, 0x4b6e7f18) // `NotOwnerNorApproved()`.
                    revert(0x1c, 0x04)
                }
            }
            // Subtract and store the updated balance of `from`.
            {
                mstore(0x00, id)
                let fromBalanceSlot := keccak256(0x00, 0x40)
                let fromBalance := sload(fromBalanceSlot)
                if gt(amount, fromBalance) {
                    mstore(0x00, 0xf4d678b8) // `InsufficientBalance()`.
                    revert(0x1c, 0x04)
                }
                sstore(fromBalanceSlot, sub(fromBalance, amount))
            }
            // Increase and store the updated balance of `to`.
            {
                mstore(0x20, toSlotSeed)
                let toBalanceSlot := keccak256(0x00, 0x40)
                let toBalanceBefore := sload(toBalanceSlot)
                let toBalanceAfter := add(toBalanceBefore, amount)
                if lt(toBalanceAfter, toBalanceBefore) {
                    mstore(0x00, 0x01336cea) // `AccountBalanceOverflow()`.
                    revert(0x1c, 0x04)
                }
                sstore(toBalanceSlot, toBalanceAfter)
            }
            // Emit a {TransferSingle} event.
            mstore(0x20, amount)
            // forgefmt: disable-next-line
            log4(0x00, 0x40, 0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62, caller(), from, to)
        }
    }

    /// @notice Batch transfers tokens from `from` to `to`
    ///         without calling onERC1155BatchReceived on the recipient.
    /// @dev Identical to Solady's safeBatchTransferFrom assembly with the
    ///      onERC1155BatchReceived callback and before/after hooks removed.
    ///      The caller must be `from` or approved via setApprovalForAll.
    function unsafeBatchTransferFrom(address from, address to, PositionId[] calldata ids, uint256[] calldata amounts)
        external
    {
        assembly ("memory-safe") {
            if iszero(eq(ids.length, amounts.length)) {
                mstore(0x00, 0x3b800a46) // `ArrayLengthsMismatch()`.
                revert(0x1c, 0x04)
            }
            let fromSlotSeed := or(_ERC1155_MASTER_SLOT_SEED, shl(96, from))
            let toSlotSeed := or(_ERC1155_MASTER_SLOT_SEED, shl(96, to))
            mstore(0x20, fromSlotSeed)
            // Clear the upper 96 bits.
            from := shr(96, fromSlotSeed)
            to := shr(96, toSlotSeed)
            // Revert if `to` is the zero address.
            if iszero(to) {
                mstore(0x00, 0xea553b34) // `TransferToZeroAddress()`.
                revert(0x1c, 0x04)
            }
            // If the caller is not `from`, do the authorization check.
            if iszero(eq(caller(), from)) {
                mstore(0x00, caller())
                if iszero(sload(keccak256(0x0c, 0x34))) {
                    mstore(0x00, 0x4b6e7f18) // `NotOwnerNorApproved()`.
                    revert(0x1c, 0x04)
                }
            }
            // Loop through all the `ids` and update the balances.
            {
                for { let i := shl(5, ids.length) } i { } {
                    i := sub(i, 0x20)
                    let amount := calldataload(add(amounts.offset, i))
                    // Subtract and store the updated balance of `from`.
                    {
                        mstore(0x20, fromSlotSeed)
                        mstore(0x00, calldataload(add(ids.offset, i)))
                        let fromBalanceSlot := keccak256(0x00, 0x40)
                        let fromBalance := sload(fromBalanceSlot)
                        if gt(amount, fromBalance) {
                            mstore(0x00, 0xf4d678b8) // `InsufficientBalance()`.
                            revert(0x1c, 0x04)
                        }
                        sstore(fromBalanceSlot, sub(fromBalance, amount))
                    }
                    // Increase and store the updated balance of `to`.
                    {
                        mstore(0x20, toSlotSeed)
                        let toBalanceSlot := keccak256(0x00, 0x40)
                        let toBalanceBefore := sload(toBalanceSlot)
                        let toBalanceAfter := add(toBalanceBefore, amount)
                        if lt(toBalanceAfter, toBalanceBefore) {
                            mstore(0x00, 0x01336cea) // `AccountBalanceOverflow()`.
                            revert(0x1c, 0x04)
                        }
                        sstore(toBalanceSlot, toBalanceAfter)
                    }
                }
            }
            // Emit a {TransferBatch} event.
            {
                let m := mload(0x40)
                // Copy the `ids`.
                mstore(m, 0x40)
                let n := shl(5, ids.length)
                mstore(add(m, 0x40), ids.length)
                calldatacopy(add(m, 0x60), ids.offset, n)
                // Copy the `amounts`.
                mstore(add(m, 0x20), add(0x60, n))
                let o := add(add(m, n), 0x60)
                mstore(o, ids.length)
                calldatacopy(add(o, 0x20), amounts.offset, n)
                // Do the emit.
                // forgefmt: disable-next-line
                log4(m, add(add(n, n), 0x80), 0x4a39dc06d4c0dbc64b70af90fd698a233a518aa5d07e595d983b8c0526c8f7fb, caller(), from, to)
            }
        }
    }

    /*--------------------------------------------------------------
                               ONLY ADMIN
    --------------------------------------------------------------*/

    /// @notice Register a module by its self-reported ID
    /// @param _module The module address
    function addModule(address _module) external onlyAdmin {
        uint256 moduleId = BaseModule(_module).moduleId();
        require(moduleId != 0, InvalidModuleId());
        require(moduleById[moduleId] == address(0), ModuleAlreadyRegistered());

        moduleById[moduleId] = _module;

        emit ModuleAdded(moduleId, _module);
    }

    /// @notice Unregister a module
    /// @param _moduleId The module ID to remove
    function removeModule(uint256 _moduleId) external onlyAdmin {
        address module = moduleById[_moduleId];
        require(module != address(0), ModuleNotRegistered());

        delete moduleById[_moduleId];
        if (crossModuleAuth[module]) {
            delete crossModuleAuth[module];
            emit CrossModuleAuthSet(module, false);
        }

        emit ModuleRemoved(_moduleId, module);
    }

    /// @notice Set cross-module mint/burn authorization for a module
    /// @dev Restricts authorization to addresses already registered as modules under their
    ///      self-reported `moduleId`. Prevents an admin from granting cross-module mint/burn
    ///      to an arbitrary EOA or unrelated contract.
    /// @param _module The module address to authorize or deauthorize
    /// @param _authorized Whether the module is authorized
    function setCrossModuleAuth(address _module, bool _authorized) external onlyAdmin {
        uint256 moduleId = BaseModule(_module).moduleId();
        require(moduleById[moduleId] == _module, ModuleNotRegistered());

        crossModuleAuth[_module] = _authorized;
        emit CrossModuleAuthSet(_module, _authorized);
    }

    /*--------------------------------------------------------------
                          UUPS UPGRADE AUTHORIZATION
    --------------------------------------------------------------*/

    /// @dev Authorizes an upgrade to a new implementation.
    /// @dev Only the owner can authorize upgrades.
    /// @param newImplementation The address of the new implementation contract.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner { }
}
