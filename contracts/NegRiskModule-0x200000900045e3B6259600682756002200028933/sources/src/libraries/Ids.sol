// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/*--------------------------------------------------------------
                       BIT-LAYOUT CONSTANTS
--------------------------------------------------------------*/

// Canonical bytes32 / uint256 layout used by all encoders/decoders:
// [moduleId(8) | baseHash(128) | arity(16) | reserved(80) | conditionIndex(16) | outcomeIndex(8)]
//
// UDVTs are then truncated so dirty values cannot exist by construction:
//   ConditionId (bytes31) drops the outcome byte (bottom 8 bits)
//   EventId     (bytes29) drops the conditionIndex + outcome bytes (bottom 24 bits)
//   PositionId  (uint256) keeps the full layout — ERC1155 token IDs need every bit.
uint256 constant MODULE_SHIFT = 248;
uint256 constant BASE_HASH_SHIFT = 120; // 16 + 80 + 16 + 8
uint256 constant ARITY_SHIFT = 104; // 80 + 16 + 8
uint256 constant CONDITION_INDEX_SHIFT = 8;

uint256 constant BASE_HASH_BITS = 128;
uint256 constant ARITY_BITS = 16;
uint256 constant RESERVED_BITS = 80;
uint256 constant CONDITION_INDEX_BITS = 16;
uint256 constant OUTCOME_BITS = 8;

// forge-lint: disable-next-line(incorrect-shift)
uint256 constant BASE_HASH_MASK = (1 << BASE_HASH_BITS) - 1;
uint256 constant ARITY_MASK = 0xFFFF;
uint256 constant CONDITION_INDEX_MASK = 0xFFFF;
// forge-lint: disable-next-line(incorrect-shift)
uint256 constant EVENT_SUFFIX_MASK = (1 << (CONDITION_INDEX_BITS + OUTCOME_BITS)) - 1;
uint256 constant OUTCOME_MASK = 0xFF;

/*--------------------------------------------------------------
                           FREE FUNCTIONS
--------------------------------------------------------------*/

/// @notice Compute the base hash for a structured ID from a module and data blob.
/// @param _moduleId The module identifier.
/// @param _data The raw data (event-scoped or condition-scoped per module convention).
/// @return The keccak256 hash of the encoded `(moduleId, data)` pair.
function computeBaseHash(uint256 _moduleId, bytes memory _data) pure returns (bytes32) {
    return keccak256(abi.encode(_moduleId, _data));
}

/*--------------------------------------------------------------
                         TYPED IDENTIFIERS
--------------------------------------------------------------*/

/// @notice Structured V2 condition identifier. Underlying type is `bytes31` so non-canonical
///         "dirty outcome byte" values cannot exist in the type system — any conversion from
///         `bytes32` must explicitly truncate, which is byte-identical to canonicalization.
/// @dev Construct via `ConditionIdLib.from(bytes32)` (validating) or `ConditionIdLib.encode`/
///      `encodeFromData` (canonical by bit construction). `bytes32(ConditionId.unwrap(_id))`
///      re-pads to the canonical wire format (last byte zero).
type ConditionId is bytes31;

/// @notice Structured V2 event identifier. Underlying type is `bytes29` so non-canonical
///         values (any of the bottom 24 bits set) cannot exist in the type system.
/// @dev Construct via `EventIdLib.from(bytes32)` (validating) or `EventIdLib.encode`/
///      `encodeFromData` (canonical by bit construction). `bytes32(EventId.unwrap(_id))`
///      re-pads to the canonical wire format (last 3 bytes zero).
type EventId is bytes29;

/// @notice Structured V2 position identifier (ERC1155 token ID).
/// @dev `uint256` underlying — no shrinking possible because position IDs use every bit
///      (the outcome byte is a meaningful field, not a discarded suffix). The type still
///      catches `amount`/`positionId` confusion at internal call sites.
type PositionId is uint256;

using EventIdLib for EventId global;
using ConditionIdLib for ConditionId global;
using PositionIdLib for PositionId global;
using { eventEq as == } for EventId global;
using { eventNotEq as != } for EventId global;
using { conditionEq as == } for ConditionId global;
using { conditionNotEq as != } for ConditionId global;
using { positionEq as == } for PositionId global;
using { positionNotEq as != } for PositionId global;

/*--------------------------------------------------------------
                            EventIdLib
--------------------------------------------------------------*/

/// @title EventIdLib
/// @author Polymarket
/// @notice Validating constructor, encoders, and typed views for `EventId`.
library EventIdLib {
    /// @notice Thrown when a `bytes32` cannot be canonicalised as an `EventId`.
    /// @param value The non-canonical bytes32 value (any of the bottom 24 bits set).
    error NonCanonicalEventId(bytes32 value);

    /// @notice Wrap a raw `bytes32` into a validated `EventId`.
    /// @dev Reverts `NonCanonicalEventId` if any of the bottom 24 bits are set, then truncates
    ///      to bytes29 (drops the now-validated zero suffix).
    /// @param _raw The candidate bytes32 value.
    /// @return The validated event identifier.
    function from(bytes32 _raw) internal pure returns (EventId) {
        if (uint256(_raw) & EVENT_SUFFIX_MASK != 0) revert NonCanonicalEventId(_raw);
        return EventId.wrap(bytes29(_raw));
    }

    /// @notice Encode an event ID from a pre-computed base hash.
    /// @dev `conditionIndex` is always 0 for event IDs; the outcome byte is also zero.
    /// @param _moduleId Module identifier.
    /// @param _baseHash Pre-computed base hash.
    /// @param _arity Number of conditions in the event.
    /// @return The encoded event ID.
    function encode(uint256 _moduleId, bytes32 _baseHash, uint256 _arity) internal pure returns (EventId) {
        return EventId.wrap(
            bytes29(
                bytes32(
                    // forgefmt: disable-start
                    (_moduleId << MODULE_SHIFT)
                        | ((uint256(_baseHash) & BASE_HASH_MASK) << BASE_HASH_SHIFT)
                        | ((_arity & ARITY_MASK) << ARITY_SHIFT)
                    // forgefmt: disable-end
                )
            )
        );
    }

    /// @notice Encode an event ID by hashing `_data` into the base hash.
    /// @dev Module-agnostic: callers pass `ModuleIds.NEGRISK` for neg-risk events. Binary
    ///      modules do not construct EventIds directly from data — their condition IDs and
    ///      event IDs are bit-equivalent (see `ConditionIdLib.eventId`).
    /// @param _moduleId Module identifier.
    /// @param _arity Number of conditions in the event.
    /// @param _data Raw event data to hash into the base hash.
    /// @return The encoded event ID.
    function encodeFromData(uint256 _moduleId, uint256 _arity, bytes memory _data) internal pure returns (EventId) {
        return encode(_moduleId, computeBaseHash(_moduleId, _data), _arity);
    }

    /// @notice Extract the module ID from an event ID.
    /// @param _id The event identifier.
    /// @return The module ID (top 8 bits).
    function moduleId(EventId _id) internal pure returns (uint256) {
        return uint256(bytes32(EventId.unwrap(_id))) >> MODULE_SHIFT;
    }

    /// @notice Extract the encoded arity from an event ID.
    /// @param _id The event identifier.
    /// @return The encoded arity.
    function arity(EventId _id) internal pure returns (uint256) {
        return (uint256(bytes32(EventId.unwrap(_id))) >> ARITY_SHIFT) & ARITY_MASK;
    }

    /// @notice Reinterpret an `EventId` as the equivalent `ConditionId`.
    /// @dev Every `EventId` is also a structurally valid `ConditionId` (outcome byte and
    ///      conditionIndex region are both zero). Used where binary/atomic markets resolve at
    ///      the event level but address the result through the condition-id surface.
    ///      bytes29 → bytes32 (right-pads 3 zero bytes) → bytes31 (drops the bottom zero byte).
    /// @param _id The event identifier.
    /// @return The same bytes reinterpreted as a condition identifier (last 2 bytes zero).
    function asCondition(EventId _id) internal pure returns (ConditionId) {
        return ConditionId.wrap(bytes31(bytes32(EventId.unwrap(_id))));
    }

    /// @notice Derive the conditionId for a given condition index within this event.
    /// @dev ORs `conditionIndex` into the event identity bits. Named with the `compute*`
    ///      prefix because it derives a new typed ID from a positional argument rather than
    ///      projecting a field. For the no-argument reinterpret (event addressed as a
    ///      condition) see `asCondition`.
    /// @param _id The event identifier.
    /// @param _conditionIndex The condition index.
    /// @return The derived condition ID.
    function computeConditionId(EventId _id, uint256 _conditionIndex) internal pure returns (ConditionId) {
        return ConditionId.wrap(
            bytes31(
                bytes32(
                    uint256(bytes32(EventId.unwrap(_id)))
                        | ((_conditionIndex & CONDITION_INDEX_MASK) << CONDITION_INDEX_SHIFT)
                )
            )
        );
    }
}

/*--------------------------------------------------------------
                          ConditionIdLib
--------------------------------------------------------------*/

/// @title ConditionIdLib
/// @author Polymarket
/// @notice Validating constructor, encoders, and typed views for `ConditionId`.
library ConditionIdLib {
    /// @notice Thrown when a `bytes32` cannot be canonicalised as a `ConditionId`.
    /// @param value The non-canonical bytes32 value (outcome byte non-zero).
    error NonCanonicalConditionId(bytes32 value);

    /// @notice Wrap a raw `bytes32` into a validated `ConditionId`.
    /// @dev Reverts `NonCanonicalConditionId` if the outcome byte is non-zero, then truncates
    ///      to bytes31. The runtime check distinguishes "caller passed a dirty value" from
    ///      "caller passed a canonical value with intended trailing zero bits"; the type-level
    ///      truncation guarantees the dirty value cannot persist beyond this constructor.
    /// @param _raw The candidate bytes32 value.
    /// @return The validated condition identifier.
    function from(bytes32 _raw) internal pure returns (ConditionId) {
        if (uint256(_raw) & OUTCOME_MASK != 0) revert NonCanonicalConditionId(_raw);
        return ConditionId.wrap(bytes31(_raw));
    }

    /// @notice Encode a condition ID from raw bit components.
    /// @dev General primitive: covers binary (arity = 0, conditionIndex = 0), neg-risk
    ///      sub-conditions (arity > 0 inherited from parent event, conditionIndex > 0), and any
    ///      future module shape. For an event-shaped output (conditionIndex = 0, arity-bearing)
    ///      prefer `EventIdLib.encode` which returns the stronger `EventId` type.
    /// @param _moduleId Module identifier.
    /// @param _baseHash Pre-computed base hash.
    /// @param _arity Neg-risk only; zero for modules that do not encode arity.
    /// @param _conditionIndex Condition index within event (0 for binary).
    /// @return The encoded condition ID.
    function encode(uint256 _moduleId, bytes32 _baseHash, uint256 _arity, uint256 _conditionIndex)
        internal
        pure
        returns (ConditionId)
    {
        return ConditionId.wrap(
            bytes31(
                bytes32(
                    // forgefmt: disable-start
                    (_moduleId << MODULE_SHIFT)
                        | ((uint256(_baseHash) & BASE_HASH_MASK) << BASE_HASH_SHIFT)
                        | ((_arity & ARITY_MASK) << ARITY_SHIFT)
                        | ((_conditionIndex & CONDITION_INDEX_MASK) << CONDITION_INDEX_SHIFT)
                    // forgefmt: disable-end
                )
            )
        );
    }

    /// @notice Encode a condition ID by hashing `_data` into the base hash, with `arity = 0`.
    /// @param _moduleId Module identifier.
    /// @param _conditionIndex Condition index within event (0 for binary).
    /// @param _data Raw data to hash into the base hash.
    /// @return The encoded condition ID.
    function encodeFromData(uint256 _moduleId, uint256 _conditionIndex, bytes memory _data)
        internal
        pure
        returns (ConditionId)
    {
        return encode(_moduleId, computeBaseHash(_moduleId, _data), 0, _conditionIndex);
    }

    /// @notice Extract the module ID from a condition ID.
    /// @param _id The condition identifier.
    /// @return The module identifier (top 8 bits).
    function moduleId(ConditionId _id) internal pure returns (uint256) {
        return uint256(bytes32(ConditionId.unwrap(_id))) >> MODULE_SHIFT;
    }

    /// @notice Extract the condition index within a multi-condition event.
    /// @param _id The condition identifier.
    /// @return The condition index.
    function conditionIndex(ConditionId _id) internal pure returns (uint256) {
        return (uint256(bytes32(ConditionId.unwrap(_id))) >> CONDITION_INDEX_SHIFT) & CONDITION_INDEX_MASK;
    }

    /// @notice Derive the parent event ID from a condition ID.
    /// @dev bytes31 → bytes29 drops the bottom 2 bytes (= the conditionIndex region).
    /// @param _id The condition identifier.
    /// @return The derived event identifier.
    function eventId(ConditionId _id) internal pure returns (EventId) {
        return EventId.wrap(bytes29(ConditionId.unwrap(_id)));
    }

    /// @notice Derive the position ID for a condition + outcome.
    /// @dev Re-pads bytes31 to bytes32 (adds the zero outcome byte back) and ORs in the
    ///      masked outcome index. The result is the ERC1155 token ID.
    /// @param _id The condition identifier.
    /// @param _outcomeIndex The outcome index (0=YES, 1=NO for binary).
    /// @return The position ID.
    function computePositionId(ConditionId _id, uint256 _outcomeIndex) internal pure returns (PositionId) {
        return PositionId.wrap(uint256(bytes32(ConditionId.unwrap(_id))) | (_outcomeIndex & OUTCOME_MASK));
    }

    function isValidEventId(ConditionId _id) internal pure returns (bool) {
        bool result;
        assembly {
            result := iszero(shl(232, _id))
        }
        return result;
    }
}

/*--------------------------------------------------------------
                          PositionIdLib
--------------------------------------------------------------*/

/// @title PositionIdLib
/// @author Polymarket
/// @notice Encoders, decoders, and typed views for `PositionId` (ERC1155 token IDs).
/// @dev `PositionId` is a `uint256` UDVT. There is no canonicality invariant beyond the bit
///      layout produced by the encoders, so callers wrap with the built-in `PositionId.wrap`
///      directly. ERC1155 boundaries unwrap to `uint256`.
library PositionIdLib {
    /// @notice Encode a position ID from raw components.
    /// @param _moduleId Module identifier (8 bits).
    /// @param _arity Zero for modules that do not encode arity.
    /// @param _conditionIndex Condition index within event (16 bits, 0 for binary).
    /// @param _outcomeIndex Outcome index (8 bits, currently 0=YES, 1=NO for binary markets).
    /// @param _data Raw data to hash into the base hash.
    /// @return The encoded position ID.
    function encode(
        uint256 _moduleId,
        uint256 _arity,
        uint256 _conditionIndex,
        uint256 _outcomeIndex,
        bytes memory _data
    ) internal pure returns (PositionId) {
        bytes32 baseHash = computeBaseHash(_moduleId, _data);

        return PositionId.wrap(
            // forgefmt: disable-start
            (_moduleId << MODULE_SHIFT)
                | ((uint256(baseHash) & BASE_HASH_MASK) << BASE_HASH_SHIFT)
                | ((_arity & ARITY_MASK) << ARITY_SHIFT)
                | ((_conditionIndex & CONDITION_INDEX_MASK) << CONDITION_INDEX_SHIFT)
                | (_outcomeIndex & OUTCOME_MASK)
            // forgefmt: disable-end
        );
    }

    /// @notice Extract the module ID from a position ID.
    /// @param _id The position ID.
    /// @return The module identifier (top 8 bits).
    function moduleId(PositionId _id) internal pure returns (uint256) {
        return PositionId.unwrap(_id) >> MODULE_SHIFT;
    }

    /// @notice Extract the outcome index from a position ID.
    /// @param _id The position ID.
    /// @return The outcome index (bottom 8 bits).
    function outcomeIndex(PositionId _id) internal pure returns (uint256) {
        return PositionId.unwrap(_id) & OUTCOME_MASK;
    }

    /// @notice Derive the canonical `ConditionId` from a position ID by dropping the outcome byte.
    /// @dev Cast to bytes32 first (the high bits are the conditionId-bearing bytes), then
    ///      truncate to bytes31 which discards the outcome byte.
    /// @param _id The position ID.
    /// @return The condition ID.
    function conditionId(PositionId _id) internal pure returns (ConditionId) {
        return ConditionId.wrap(bytes31(bytes32(PositionId.unwrap(_id))));
    }
}

/*--------------------------------------------------------------
                       OPERATOR OVERLOAD FUNCTIONS
--------------------------------------------------------------*/

/// @notice Compare two ConditionIds for strict equality.
/// @dev Pure bitwise equality on the underlying bytes31.
/// @param _id0 The first conditionId.
/// @param _id1 The second conditionId.
function conditionEq(ConditionId _id0, ConditionId _id1) pure returns (bool) {
    return ConditionId.unwrap(_id0) == ConditionId.unwrap(_id1);
}

/// @notice Compare two ConditionIds for strict inequality.
/// @param _id0 The first conditionId.
/// @param _id1 The second conditionId.
function conditionNotEq(ConditionId _id0, ConditionId _id1) pure returns (bool) {
    return ConditionId.unwrap(_id0) != ConditionId.unwrap(_id1);
}

/// @notice Compare two EventIds for strict equality.
/// @dev Pure bitwise equality on the underlying bytes29.
/// @param _id0 The first eventId.
/// @param _id1 The second eventId.
function eventEq(EventId _id0, EventId _id1) pure returns (bool) {
    return EventId.unwrap(_id0) == EventId.unwrap(_id1);
}

/// @notice Compare two EventIds for strict inequality.
/// @param _id0 The first eventId.
/// @param _id1 The second eventId.
function eventNotEq(EventId _id0, EventId _id1) pure returns (bool) {
    return EventId.unwrap(_id0) != EventId.unwrap(_id1);
}

/// @notice Compare two PositionIds for strict equality.
/// @dev Pure bitwise equality on the underlying uint256.
/// @param _id0 The first positionId.
/// @param _id1 The second positionId.
function positionEq(PositionId _id0, PositionId _id1) pure returns (bool) {
    return PositionId.unwrap(_id0) == PositionId.unwrap(_id1);
}

/// @notice Compare two PositionIds for strict inequality.
/// @param _id0 The first positionId.
/// @param _id1 The second positionId.
function positionNotEq(PositionId _id0, PositionId _id1) pure returns (bool) {
    return PositionId.unwrap(_id0) != PositionId.unwrap(_id1);
}
