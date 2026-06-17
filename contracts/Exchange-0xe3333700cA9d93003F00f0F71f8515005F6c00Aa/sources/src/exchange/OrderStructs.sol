// SPDX-License-Identifier: BUSL-1.1
pragma solidity <0.9.0;

import { PositionId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @dev EIP-712 typehash for the Order struct
/// @dev WIRE SCHEMA — the literal type names in the source string below are the on-the-wire
///      EIP-712 schema. UDVTs are encoded as their underlying types.
bytes32 constant ORDER_TYPEHASH = 0xbb86318a2138f5fa8ae32fbe8e659f8fcf13cc6ae4014a707893055433818589;

// keccak256(
//     "Order(uint256 salt,address maker,address signer,uint256 tokenId,uint256 makerAmount,uint256 takerAmount,uint8
// side,uint8 signatureType,uint256 timestamp,bytes32 metadata,bytes32 builder)"
// );

/// @notice Represents a signed order on the Polymarket exchange
struct Order {
    /// @dev Unique salt to ensure entropy
    uint256 salt;
    /// @dev Maker of the order, i.e. the source of funds
    address maker;
    /// @dev Signer of the order. Must equal maker for EOA and 1271 orders.
    address signer;
    /// @dev Token ID of the CTF ERC1155 asset to be bought or sold.
    ///      If BUY, this is the tokenId of the asset to be bought.
    ///      If SELL, this is the tokenId of the asset to be sold.
    ///      Stored as `PositionId` (UDVT over uint256) so internal call sites are typed;
    ///      ABI / EIP-712 wire encoding is identical to the underlying uint256.
    PositionId tokenId;
    /// @dev Maximum amount of tokens to be sold by the maker
    uint256 makerAmount;
    /// @dev Target quantity of taker-side tokens at the limit price
    uint256 takerAmount;
    /// @dev The side of the order: BUY or SELL
    Side side;
    /// @dev Signature type: EOA, POLY_PROXY, POLY_GNOSIS_SAFE, or POLY_1271
    SignatureType signatureType;
    /// @dev Unix timestamp at which the order was created
    uint256 timestamp;
    /// @dev Hashed metadata associated with the order
    bytes32 metadata;
    /// @dev Builder code indicating the order's origin
    bytes32 builder;
    /// @dev The cryptographic signature over the EIP-712 order hash
    bytes signature;
}

/// @notice The type of signature used to authenticate an order
enum SignatureType {
    /// @dev 0: ECDSA EIP-712 signatures signed directly by EOAs
    EOA,
    /// @dev 1: EIP-712 signatures signed by Polymarket Proxy wallet owners
    POLY_PROXY,
    /// @dev 2: EIP-712 signatures signed by Polymarket Gnosis Safe owners
    POLY_GNOSIS_SAFE,
    /// @dev 3: EIP-1271 signatures signed by smart contracts
    POLY_1271
}

/// @notice The side of an order
enum Side {
    /// @dev 0: Buy side
    BUY,
    /// @dev 1: Sell side
    SELL
}

/// @notice Tracks the fill state of an order
struct OrderStatus {
    /// @dev Whether the order has been fully filled
    bool filled;
    /// @dev Remaining fillable amount (packed with filled in one slot)
    uint248 remaining;
}
