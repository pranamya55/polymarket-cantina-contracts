// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title ModuleErrors
/// @author Polymarket
/// @notice Custom errors shared across market modules.
abstract contract ModuleErrors {
    /// @notice Thrown when attempting to resolve an already-resolved condition.
    error ConditionAlreadyResolved();
    /// @notice Thrown when the condition has not been resolved yet.
    error ConditionNotResolved();
    /// @notice Thrown when array lengths do not match.
    error InvalidArrayLength();
    /// @notice Thrown when the outcome index is out of range for the condition.
    error InvalidOutcomeIndex();
    /// @notice Thrown when the result array is invalid (wrong length or values).
    error InvalidResults();
    /// @notice Thrown when an invalid index set is provided.
    error InvalidIndexSet();
    /// @notice Thrown when the event has not been prepared yet.
    error EventNotPrepared();
    /// @notice Thrown when attempting to prepare an already-prepared event.
    error EventAlreadyPrepared();
    /// @notice Thrown when the condition index is out of range for the event.
    error InvalidConditionIndex();
    /// @notice Thrown when the condition count is invalid (zero or exceeds maximum).
    error InvalidConditionCount();
    /// @notice Thrown when the event ID does not match the expected value.
    error InvalidEventId();
    /// @notice Thrown when legacy migration is not supported for this condition/event.
    error MigrationNotSupported();
    /// @notice Thrown when the from address is invalid
    error InvalidFromAddress();
    /// @notice Thrown when a UUPS upgrade targets an incompatible implementation.
    error IncompatibleImplementation();
}
