// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

/// @title Events
/// @author Polymarket
/// @notice Events emitted by DepositWallet contracts.
abstract contract Events {
    /// @notice Emitted when ownership is transferred.
    /// @param oldOwner The address of the previous owner.
    /// @param newOwner The address of the new owner.
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    /// @notice Emitted when a two-step ownership handover is initiated.
    /// @param pendingOwner The address of the proposed new owner.
    event OwnershipHandoverRequested(address indexed pendingOwner);

    /// @notice Emitted when a two-step ownership handover is completed.
    /// @param previousOwner The address of the outgoing owner.
    /// @param newOwner The address of the incoming owner.
    event OwnershipHandoverCompleted(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when a pending ownership handover is canceled.
    /// @param pendingOwner The address of the canceled pending owner.
    event OwnershipHandoverCanceled(address indexed pendingOwner);

    /// @notice Emitted when ERC-20 tokens are withdrawn from the wallet by the owner.
    /// @param token The address of the ERC-20 token.
    /// @param to The recipient address.
    /// @param amount The amount of tokens withdrawn.
    event ERC20Withdrawal(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when ERC-1155 tokens are batch-withdrawn from the wallet by the owner.
    /// @param token The address of the ERC-1155 token.
    /// @param to The recipient address.
    /// @param ids The token IDs withdrawn.
    /// @param amounts The amounts withdrawn for each token ID.
    event ERC1155BatchWithdrawal(
        address indexed token, address indexed to, uint256[] ids, uint256[] amounts
    );

    /// @notice Emitted for each individual call executed within a batch.
    /// @param target The address called.
    /// @param value The ETH value sent with the call.
    /// @param data The calldata sent to the target.
    /// @param result The return data from the call.
    event Execution(address indexed target, uint256 value, bytes data, bytes result);

    /// @notice Emitted after a batch of calls has been successfully executed.
    /// @param nonce The nonce of the executed batch.
    event BatchExecuted(uint256 indexed nonce);

    /// @notice Emitted when a session signer is authorized.
    /// @param sessionSigner The address of the authorized session signer.
    /// @param validUntil The timestamp until which the session signer is valid.
    event SessionSignerAuthorized(address indexed sessionSigner, uint256 validUntil);

    /// @notice Emitted when a session signer is revoked via a self-call.
    /// @param sessionSigner The address of the revoked session signer.
    event SessionSignerRevoked(address indexed sessionSigner);

    /// @notice Emitted when the wallet is paused.
    /// @param timestamp The block timestamp at which the wallet was paused.
    event Paused(uint256 timestamp);

    /// @notice Emitted when the wallet is unpaused.
    /// @param timestamp The block timestamp at which the wallet was unpaused.
    event Unpaused(uint256 timestamp);

    /// @notice Emitted when an ERC-20 allowance is revoked by the owner.
    /// @param token The address of the ERC-20 token.
    /// @param spender The address whose allowance was revoked.
    event AllowanceRevoked(address indexed token, address indexed spender);

    /// @notice Emitted when an ERC-1155 operator approval is revoked by the owner.
    /// @param token The address of the ERC-1155 token.
    /// @param operator The address whose approval was revoked.
    event ApprovalForAllRevoked(address indexed token, address indexed operator);

    /// @notice Emitted when a session signer is emergency-revoked by the owner while paused.
    /// @param sessionSigner The address of the revoked session signer.
    event SessionSignerRevokedEmergency(address indexed sessionSigner);
}
