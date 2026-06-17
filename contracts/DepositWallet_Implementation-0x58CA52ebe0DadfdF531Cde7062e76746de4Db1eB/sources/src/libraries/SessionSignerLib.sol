// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

/// @dev Magic suffix bytes appended to a signature to indicate the presence of a session signer.
/// Mirrors the ERC-6492 magic value to reuse the same detection mechanism.
bytes32 constant SESSION_SIGNER_MAGIC_BYTES =
    0x6492649264926492649264926492649264926492649264926492649264926492;

/// @title SessionSignerLib
/// @author Polymarket
/// @notice Utilities for encoding and decoding session signer signatures.
/// @dev Session signer signatures wrap a standard ECDSA signature with an address prefix
///      and a trailing magic suffix, following the ERC-6492 envelope format.
library SessionSignerLib {
    /// @notice Extracts the session signer address from a signature, if present.
    /// @dev Returns `address(0)` if the signature does not contain the session signer magic suffix.
    /// @param _signature The raw signature bytes (potentially wrapped with session signer data).
    /// @return sessionSigner The extracted session signer address, or `address(0)` if none.
    function extractSessionSigner(bytes calldata _signature)
        internal
        pure
        returns (address sessionSigner)
    {
        /// @solidity memory-safe-assembly
        assembly {
            // Detects the ERC6492 wrapper if it exists.
            // See: https://eips.ethereum.org/EIPS/eip-6492
            if eq(
                calldataload(add(_signature.offset, sub(_signature.length, 0x20))),
                SESSION_SIGNER_MAGIC_BYTES
            ) {
                // the session signer is in the first 32 bytes of the signature
                sessionSigner := calldataload(_signature.offset)
            }
        }
    }

    /// @notice Creates a session signer signature by wrapping an existing signature.
    /// @dev Encodes the session signer address, a zero-bytes placeholder, the inner signature,
    ///      and the magic suffix into a single byte array.
    /// @param _sessionSigner The session signer address to encode.
    /// @param _signature The inner ECDSA signature to wrap.
    /// @return The wrapped session signer signature.
    function getSessionSignerSignature(address _sessionSigner, bytes memory _signature)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            abi.encode(bytes32(uint256(uint160(_sessionSigner))), bytes32(0), _signature),
            SESSION_SIGNER_MAGIC_BYTES
        );
    }
}
