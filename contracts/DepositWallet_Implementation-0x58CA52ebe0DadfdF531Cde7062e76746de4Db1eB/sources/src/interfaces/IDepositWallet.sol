// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {Batch} from "@deposit-wallet/src/libraries/WalletLib.sol";

/// @title IDepositWallet
/// @author Polymarket
/// @notice Interface for the DepositWallet proxy contract.
interface IDepositWallet {
    /*--------------------------------------------------------------
                             INITIALIZER
    --------------------------------------------------------------*/

    /// @notice Initializes the wallet with a designated owner.
    /// @param _owner The address to set as the wallet owner.
    function initialize(address _owner) external;

    /*--------------------------------------------------------------
                                  VIEW
    --------------------------------------------------------------*/

    /// @notice Returns the wallet's current execution nonce.
    /// @return The current nonce.
    function nonce() external view returns (uint256);

    /// @notice Returns the timestamp at which the wallet was paused.
    /// @return The paused timestamp, or zero if not paused.
    function paused() external view returns (uint256);

    /// @notice Returns the timestamp until which a session signer is authorized.
    /// @param _signer The session signer address to query.
    /// @return The authorization expiry timestamp, or zero if not authorized.
    function sessionSignerAuthorizedUntil(address _signer) external view returns (uint256);

    /// @notice Returns the unique identifier assigned to this wallet at deployment.
    /// @return The wallet ID decoded from the ERC-1967 immutable args.
    function id() external view returns (bytes32);

    /// @notice Returns the factory contract that deployed this wallet.
    /// @return The factory address decoded from the ERC-1967 immutable args.
    function factory() external view returns (address);

    /// @notice Returns the current owner of the wallet.
    /// @return The owner address.
    function owner() external view returns (address);

    /// @notice Returns the pending owner awaiting handover completion.
    /// @return The pending owner address, or `address(0)` if none.
    function pendingOwner() external view returns (address);

    /*--------------------------------------------------------------
                             ONLY FACTORY
    --------------------------------------------------------------*/

    /// @notice Executes a signed batch of calls through the factory.
    /// @dev Validates the batch (non-empty, correct wallet, nonce, deadline), verifies the EIP-712
    ///      signature against the owner or an authorized session signer, then executes each call
    ///      sequentially. Session signers are prevented from calling the wallet itself.
    /// @param _batch The batch containing the target wallet, nonce, deadline, and calls.
    /// @param _signature The EIP-712 signature authorizing the batch (owner or session signer).
    function execute(Batch calldata _batch, bytes calldata _signature) external;

    /*--------------------------------------------------------------
                               ONLY SELF
    --------------------------------------------------------------*/

    /// @notice Authorizes a session signer until the specified timestamp.
    /// @dev Can only be invoked via batch execution (self-call).
    /// @param _sessionSigner The address to authorize as a session signer.
    /// @param _validUntil The timestamp until which the session signer is valid.
    function authorizeSessionSigner(address _sessionSigner, uint256 _validUntil) external;

    /// @notice Revokes a session signer's authorization.
    /// @dev Can only be invoked via batch execution (self-call).
    /// @param _sessionSigner The session signer address to revoke.
    function revokeSessionSigner(address _sessionSigner) external;

    /// @notice Initiates a two-step ownership transfer to a new owner.
    /// @dev Can only be invoked via batch execution (self-call).
    /// @param _newOwner The proposed new owner address.
    function transferOwnership(address _newOwner) external;

    /// @notice Cancels any pending ownership handover.
    /// @dev Can only be invoked via batch execution (self-call).
    function cancelOwnershipHandover() external;

    /// @notice Upgrades the wallet implementation via UUPS.
    /// @dev Can only be invoked via batch execution (self-call).
    ///      The new implementation must be authorized by the factory.
    /// @param _implementation The address of the new implementation contract.
    /// @param _data Optional calldata to execute on the new implementation after upgrade.
    function upgrade(address _implementation, bytes calldata _data) external;

    /*--------------------------------------------------------------
                           OWNERSHIP HANDOVER
    --------------------------------------------------------------*/

    /// @notice Completes a pending ownership transfer.
    /// @dev Permissionless — anyone may submit, but the pending owner must have signed
    ///      an EIP-712 `OwnershipHandover` message.
    /// @param _deadline The deadline timestamp included in the signed message.
    /// @param _signature The EIP-712 signature from the pending owner.
    function completeOwnershipHandover(uint256 _deadline, bytes calldata _signature) external;

    /*--------------------------------------------------------------
                               ONLY OWNER
    --------------------------------------------------------------*/

    /// @notice Pauses the wallet, recording the current timestamp.
    /// @dev After pausing, the owner must wait for the timelock delay before calling
    ///      paused-only functions (e.g., withdrawals, revocations).
    function pause() external;

    /// @notice Unpauses the wallet.
    /// @dev Requires the wallet to be paused and the timelock delay to have elapsed.
    function unpause() external;

    /// @notice Withdraws ERC-20 tokens from the wallet.
    /// @dev Requires the wallet to be paused and the timelock delay to have elapsed.
    /// @param _token The ERC-20 token address.
    /// @param _to The recipient address.
    /// @param _amount The amount of tokens to withdraw.
    function withdrawERC20(address _token, address _to, uint256 _amount) external;

    /// @notice Batch-withdraws ERC-1155 tokens from the wallet.
    /// @dev Requires the wallet to be paused and the timelock delay to have elapsed.
    /// @param _token The ERC-1155 token address.
    /// @param _to The recipient address.
    /// @param _ids The token IDs to withdraw.
    /// @param _amounts The amounts for each token ID.
    function withdrawERC1155(
        address _token,
        address _to,
        uint256[] calldata _ids,
        uint256[] calldata _amounts
    ) external;

    /// @notice Revokes an ERC-20 allowance by setting it to zero.
    /// @dev Requires the wallet to be paused and the timelock delay to have elapsed.
    /// @param _token The ERC-20 token address.
    /// @param _spender The spender whose allowance is revoked.
    function revokeAllowance(address _token, address _spender) external;

    /// @notice Revokes an ERC-1155 operator approval.
    /// @dev Requires the wallet to be paused and the timelock delay to have elapsed.
    /// @param _token The ERC-1155 token address.
    /// @param _operator The operator whose approval is revoked.
    function revokeApprovalForAll(address _token, address _operator) external;

    /// @notice Emergency revocation of a session signer by the owner.
    /// @dev Requires the wallet to be paused and the timelock delay to have elapsed.
    /// @param _sessionSigner The session signer to revoke.
    function revokeSessionSignerEmergency(address _sessionSigner) external;

    /*--------------------------------------------------------------
                                ERC1271
    --------------------------------------------------------------*/

    /// @notice Validates a signature against the wallet owner or an authorized session signer.
    /// @param _hash The hash that was signed.
    /// @param _signature The signature to validate (may contain a session signer wrapper).
    /// @return result `ERC1271_MAGIC_VALUE` if the signature is valid.
    function isValidSignature(bytes32 _hash, bytes calldata _signature)
        external
        view
        returns (bytes4 result);
}
