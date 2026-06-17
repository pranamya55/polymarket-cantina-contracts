// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

/// @title Errors
/// @author Polymarket
/// @notice Custom errors shared across DepositWallet contracts.
abstract contract Errors {
    /// @notice Thrown when the caller is not authorized to perform the action.
    error Unauthorized();

    /// @notice Thrown when the provided owner address is invalid (e.g., zero address).
    error InvalidOwner();

    /// @notice Thrown when an ownership handover is expected but none is pending.
    error NoPendingOwner();

    /// @notice Thrown when a deadline has passed.
    error Expired();

    /// @notice Thrown when a signature fails verification.
    error InvalidSignature();

    /// @notice Thrown when the caller is not the factory contract.
    error OnlyFactory();

    /// @notice Thrown when a low-level call within a batch execution fails.
    error CallFailed();

    /// @notice Thrown when a function restricted to self-calls is invoked externally.
    error OnlySelf();

    /// @notice Thrown when a batch contains zero calls.
    error EmptyBatch();

    /// @notice Thrown when the batch nonce does not match the wallet's current nonce.
    error InvalidNonce();

    /// @notice Thrown when the batch's wallet address does not match the executing wallet.
    error InvalidWallet();

    /// @notice Thrown when a UUPS upgrade targets an unauthorized implementation.
    error InvalidImplementation();

    /// @notice Thrown when a session signer's authorization has expired or does not exist.
    error SessionSignerUnauthorized();

    /// @notice Thrown when a session signer attempts to call the wallet itself.
    error SessionSignerSelfCallNotAllowed();

    /// @notice Thrown when a paused-only function is called while the wallet is not paused.
    error NotPaused();

    /// @notice Thrown when the timelock delay has not elapsed since the wallet was paused.
    error TimelockInsufficientDelay();
}
