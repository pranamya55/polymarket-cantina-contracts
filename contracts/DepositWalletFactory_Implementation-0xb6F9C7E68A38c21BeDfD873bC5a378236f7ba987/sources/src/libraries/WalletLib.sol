// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

/// @dev ERC-1271 magic value returned on successful signature validation.
/// bytes4(keccak256("isValidSignature(bytes32,bytes)"))
bytes4 constant ERC1271_MAGIC_VALUE = 0x1626ba7e;

/// @dev EIP-712 typehash for the `Call` struct.
bytes32 constant CALL_TYPEHASH = keccak256("Call(address target,uint256 value,bytes data)");

/// @dev EIP-712 type name for the `Batch` struct, used in ERC-1271 nested signatures.
string constant BATCH_CONTENTS_NAME = "Batch";

/// @dev EIP-712 type string for the `Batch` struct, including the nested `Call` type.
string constant BATCH_CONTENTS_TYPE =
    "Batch(address wallet,uint256 nonce,uint256 deadline,Call[] calls)Call(address target,uint256 value,bytes data)";

/// @dev EIP-712 typehash for the `Batch` struct.
bytes32 constant BATCH_TYPEHASH = keccak256(bytes(BATCH_CONTENTS_TYPE));

/// @notice A batch of calls to be executed by a DepositWallet.
/// @dev Signed by the wallet owner or an authorized session signer using EIP-712.
struct Batch {
    /// @dev The address of the wallet that will execute this batch.
    address wallet;
    /// @dev Replay-protection nonce; must equal the wallet's current nonce.
    uint256 nonce;
    /// @dev Timestamp after which the batch signature is no longer valid.
    uint256 deadline;
    /// @dev The ordered list of calls to execute.
    Call[] calls;
}

/// @notice A single call within a batch.
struct Call {
    /// @dev The target address to call.
    address target;
    /// @dev The ETH value to send with the call.
    uint256 value;
    /// @dev The calldata to send to the target.
    bytes data;
}

/// @title WalletLib
/// @author Polymarket
/// @notice EIP-712 hashing utilities for `Batch` and `Call` structs.
library WalletLib {
    /// @notice Computes the EIP-712 struct hash of a batch.
    /// @param _batch The batch to hash.
    /// @return The EIP-712 struct hash.
    function hash(Batch memory _batch) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                BATCH_TYPEHASH, _batch.wallet, _batch.nonce, _batch.deadline, hash(_batch.calls)
            )
        );
    }

    /// @notice Computes the EIP-712 array hash of an array of calls.
    /// @param _calls The calls to hash.
    /// @return The keccak256 hash of the concatenated individual call hashes.
    function hash(Call[] memory _calls) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](_calls.length);
        for (uint256 i; i < _calls.length; i++) {
            hashes[i] = hash(_calls[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }

    /// @notice Computes the EIP-712 struct hash of a single call.
    /// @param _call The call to hash.
    /// @return The EIP-712 struct hash.
    function hash(Call memory _call) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                CALL_TYPEHASH,
                _call.target,
                _call.value,
                keccak256(_call.data) // bytes fields must be hashed
            )
        );
    }
}
