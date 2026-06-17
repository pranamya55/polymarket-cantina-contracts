// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IExchangeV1} from "./IExchangeV1.sol";

/// @title StorageV1
abstract contract StorageV1 is IExchangeV1 {
    /// @notice Counter incremented on every state-root commit.
    uint256 public epoch;

    /// @notice Merkle root committing to all account balances. Each leaf is
    ///         keccak256(bytes.concat(keccak256(abi.encode(account, token, balance)))).
    bytes32 public stateRoot;

    /// @notice Contract owner. Can manage operators, keepers, tokens, transfer ownership, and authorize upgrades.
    address public owner;

    /// @notice Address nominated to become the new owner. Must call `acceptOwnership()` to finalize.
    address public pendingOwner;

    /// @notice Addresses authorized to commit state roots.
    mapping(address operator => bool enabled) public operators;

    /// @notice Addresses authorized to run offchain-signed withdrawal processing via `processWithdrawal`.
    ///         Distinct from `operators` so the two duties can be delegated independently.
    mapping(address keeper => bool enabled) public keepers;

    /// @notice Minimum deposit amount per supported ERC-20 asset, expressed in the token's
    ///         native decimals. A value of 0 means the asset is unsupported.
    mapping(address token => uint256 minAmount) public supportedAssets;

    /// @notice Tracks used withdrawal digests for replay protection.
    mapping(bytes32 digest => bool used) public usedDigests;

    /// @notice Cumulative withdrawn amount per (epoch, token, account).
    mapping(uint256 epoch => mapping(address token => mapping(address account => uint256 amount))) public withdrawn;
}
