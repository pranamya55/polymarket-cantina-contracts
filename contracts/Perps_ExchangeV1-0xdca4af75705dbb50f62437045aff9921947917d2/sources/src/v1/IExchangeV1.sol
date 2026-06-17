// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IExchangeV1
interface IExchangeV1 {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed account, address indexed token, uint256 amount, address to);
    event StateRootCommitted(uint256 indexed epoch, bytes32 indexed stateRoot, bytes32 hash);
    event WithdrawalCompleted(
        address indexed account, address indexed token, uint256 amount, uint256 fee, address to, bytes32 digest
    );
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferCancelled(address indexed previousOwner, address indexed cancelledPendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OperatorModified(address indexed operator, bool enabled);
    event KeeperModified(address indexed keeper, bool enabled);
    event SupportedAssetModified(address indexed token, bool enabled, uint256 minAmount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAmount();
    error ZeroAddress();
    error ZeroValue();
    error InsufficientBalance();
    error Unauthorized();
    error AssetNotSupported();
    error DepositBelowMinimum();
    error InvalidSignature();
    error SignatureExpired();
    error InvalidProof();
    error NoStateRoot();
    error FeeTooHigh();
    error RoleConflict();
    error DigestAlreadyUsed();
    error NoPendingTransfer();
}
