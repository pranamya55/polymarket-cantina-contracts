// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {ECDSA} from "@solady/src/utils/ECDSA.sol";
import {EIP712} from "@solady/src/utils/EIP712.sol";

import {Errors} from "@deposit-wallet/src/Errors.sol";
import {Events} from "@deposit-wallet/src/Events.sol";

/// @title Ownable
/// @author Polymarket
/// @notice Two-step ownership management with EIP-712 signature-based handover.
/// @dev Ownership transfers require the new owner to sign an `OwnershipHandover` EIP-712 message.
///      This prevents accidental transfers to addresses that cannot interact with the wallet.
///      Storage uses custom slots to avoid collisions in proxy-based deployments.
abstract contract Ownable is EIP712, Errors, Events {
    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @dev Storage slot for the owner address. keccak256("DepositWallet.owner") - 1
    bytes32 internal constant _OWNER_SLOT = bytes32(uint256(keccak256("DepositWallet.owner")) - 1);

    /// @dev Storage slot for the pending owner address. keccak256("DepositWallet.pendingOwner") - 1
    bytes32 internal constant _PENDING_OWNER_SLOT =
        bytes32(uint256(keccak256("DepositWallet.pendingOwner")) - 1);

    /// @dev EIP-712 typehash for the `OwnershipHandover` struct.
    bytes32 private constant _OWNERSHIP_HANDOVER_TYPEHASH =
        keccak256("OwnershipHandover(address newOwner,uint256 deadline)");

    /*--------------------------------------------------------------
                                  VIEW
    --------------------------------------------------------------*/

    /// @notice Returns the current owner of the wallet.
    /// @return result The owner address.
    function owner() public view virtual returns (address result) {
        bytes32 slot = _OWNER_SLOT;
        assembly {
            result := sload(slot)
        }
    }

    /// @notice Returns the pending owner awaiting handover completion.
    /// @return result The pending owner address, or `address(0)` if none.
    function pendingOwner() public view virtual returns (address result) {
        bytes32 slot = _PENDING_OWNER_SLOT;
        assembly {
            result := sload(slot)
        }
    }

    /*--------------------------------------------------------------
                              INTERNAL
    --------------------------------------------------------------*/

    /// @notice Sets the initial owner of the wallet.
    /// @dev Should only be called once during initialization.
    /// @param _newOwner The address to set as the initial owner.
    function _initializeOwner(address _newOwner) internal virtual {
        require(_newOwner != address(0), InvalidOwner());

        bytes32 slot = _OWNER_SLOT;

        assembly {
            sstore(slot, _newOwner)
        }

        emit OwnershipTransferred(address(0), _newOwner);
    }

    /// @notice Replaces the current owner with a new address.
    /// @param _newOwner The address of the new owner.
    function _setOwner(address _newOwner) internal virtual {
        address oldOwner = owner();
        bytes32 slot = _OWNER_SLOT;

        assembly {
            sstore(slot, _newOwner)
        }

        emit OwnershipTransferred(oldOwner, _newOwner);
    }

    /// @notice Stores a new pending owner address.
    /// @param _pendingOwner The address to set as the pending owner.
    function _setPendingOwner(address _pendingOwner) internal virtual {
        bytes32 slot = _PENDING_OWNER_SLOT;

        assembly {
            sstore(slot, _pendingOwner)
        }
    }

    /// @notice Reverts if `msg.sender` is not the current owner.
    function _checkOwner() internal view virtual {
        require(msg.sender == owner(), Unauthorized());
    }

    /*--------------------------------------------------------------
                           OWNERSHIP HANDOVER
    --------------------------------------------------------------*/

    /// @notice Initiates a two-step ownership transfer to `_newOwner`.
    /// @dev Sets the pending owner and emits {OwnershipHandoverRequested}.
    ///      The transfer must be completed by calling `completeOwnershipHandover` with
    ///      a valid EIP-712 signature from `_newOwner`.
    /// @param _newOwner The proposed new owner (must not be `address(0)`).
    function _transferOwnership(address _newOwner) internal virtual {
        require(_newOwner != address(0), InvalidOwner());

        _setPendingOwner(_newOwner);

        emit OwnershipHandoverRequested(_newOwner);
    }

    /// @notice Cancels any pending ownership handover.
    /// @dev Reverts if there is no pending owner.
    function _cancelOwnershipHandover() internal virtual {
        address pending = pendingOwner();

        require(pending != address(0), NoPendingOwner());

        _setPendingOwner(address(0));

        emit OwnershipHandoverCanceled(pending);
    }

    /// @notice Completes a two-step ownership handover using an EIP-712 signature from the pending
    /// owner. @dev Validates the signature against the `OwnershipHandover` typehash and transfers
    /// ownership.
    /// @param _deadline The deadline timestamp included in the signed message.
    /// @param _signature The EIP-712 signature from the pending owner.
    function _completeOwnershipHandover(uint256 _deadline, bytes calldata _signature)
        internal
        virtual
    {
        // ensure _signature is still valid
        require(block.timestamp <= _deadline, Expired());

        address pending = pendingOwner();

        // ensure there is a pending owner
        require(pending != address(0), NoPendingOwner());

        bytes32 structHash = keccak256(abi.encode(_OWNERSHIP_HANDOVER_TYPEHASH, pending, _deadline));
        bytes32 digest = _hashTypedData(structHash);

        // validate signature
        require(ECDSA.recoverCalldata(digest, _signature) == pending, InvalidSignature());

        address previousOwner = owner();

        // update state
        _setPendingOwner(address(0));
        _setOwner(pending);

        emit OwnershipHandoverCompleted(previousOwner, pending);
    }
}
