// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {ERC1271} from "@solady/src/accounts/ERC1271.sol";
import {Receiver} from "@solady/src/accounts/Receiver.sol";
import {ERC1155} from "@solady/src/tokens/ERC1155.sol";
import {ECDSA} from "@solady/src/utils/ECDSA.sol";
import {Initializable} from "@solady/src/utils/Initializable.sol";
import {LibClone} from "@solady/src/utils/LibClone.sol";
import {SafeTransferLib} from "@solady/src/utils/SafeTransferLib.sol";
import {UUPSUpgradeable} from "@solady/src/utils/UUPSUpgradeable.sol";

import {DepositWalletFactory} from "@deposit-wallet/src/DepositWalletFactory.sol";
import {Ownable} from "@deposit-wallet/src/libraries/Ownable.sol";
import {SessionSignerLib} from "@deposit-wallet/src/libraries/SessionSignerLib.sol";
import {
    Batch,
    Call,
    WalletLib,
    ERC1271_MAGIC_VALUE
} from "@deposit-wallet/src/libraries/WalletLib.sol";

/// @title DepositWallet
/// @author Polymarket
/// @notice Minimal, upgradeable smart-contract wallet for deposit operations.
/// @dev Deployed as an ERC-1967 proxy via {DepositWalletFactory}. Supports batch execution
///      of arbitrary calls signed by the owner or an authorized session signer, ERC-1271
///      signature validation, two-step ownership transfers, and an owner-controlled pause
///      mechanism with a timelock for emergency asset recovery.
contract DepositWallet is UUPSUpgradeable, Initializable, Receiver, ERC1271, Ownable {
    using LibClone for address;
    using SafeTransferLib for address;
    using SessionSignerLib for bytes;
    using WalletLib for Batch;

    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @dev Memory slot used to pass the resolved signer from `isValidSignature` to
    /// `_erc1271Signer`. Chosen at 0x80 (first allocatable slot). Before the super call we advance
    /// the free memory
    /// pointer to 0xa0 so the parent and all callees allocate above this slot and do not overwrite.
    uint256 private constant _ERC1271_SIGNER_MEM_SLOT = 0x80;

    /// @dev Storage slot for the replay-protection nonce. keccak256("DepositWallet.nonce") - 1
    bytes32 private constant _NONCE_SLOT = bytes32(uint256(keccak256("DepositWallet.nonce")) - 1);

    /// @dev Storage slot for the paused timestamp. keccak256("DepositWallet.paused") - 1
    bytes32 private constant _PAUSED_SLOT = bytes32(uint256(keccak256("DepositWallet.paused")) - 1);

    /// @dev Base storage slot for the session signer mapping.
    /// keccak256("DepositWallet.sessionSignerAuthorizedUntil") - 1
    bytes32 private constant _SESSION_SIGNER_SLOT =
        bytes32(uint256(keccak256("DepositWallet.sessionSignerAuthorizedUntil")) - 1);

    /*--------------------------------------------------------------
                               MODIFIERS
    --------------------------------------------------------------*/

    /// @dev Restricts access to the factory contract.
    modifier onlyFactory() {
        require(msg.sender == factory(), OnlyFactory());
        _;
    }

    /// @dev Restricts access to calls originating from the wallet itself (i.e., via batch
    /// execution).
    modifier onlySelf() {
        require(msg.sender == address(this), OnlySelf());
        _;
    }

    /// @dev Enforces that the contract is paused and the timelock delay has elapsed.
    modifier onlyPaused() {
        require(paused() != 0, NotPaused());
        require(
            block.timestamp > paused() + DepositWalletFactory(factory()).timelockDelay(),
            TimelockInsufficientDelay()
        );
        _;
    }

    /// @dev Restricts access to the wallet owner.
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @dev Disables initializers on the implementation contract to prevent misuse.
    constructor() {
        _disableInitializers();
    }

    /*--------------------------------------------------------------
                             INITIALIZER
    --------------------------------------------------------------*/

    /// @notice Initializes the wallet with a designated owner.
    /// @dev This replaces the constructor for upgradeable contracts.
    /// @param _owner The address to set as the wallet owner.
    function initialize(address _owner) external initializer {
        _initializeOwner(_owner);
    }

    /*--------------------------------------------------------------
                                  VIEW
    --------------------------------------------------------------*/

    /// @notice Returns the wallet's current execution nonce.
    /// @return nonce_ The current nonce.
    function nonce() public view returns (uint256 nonce_) {
        bytes32 slot = _NONCE_SLOT;
        assembly ("memory-safe") {
            nonce_ := sload(slot)
        }
    }

    /// @notice Returns the timestamp at which the wallet was paused.
    /// @return paused_ The paused timestamp, or zero if not paused.
    function paused() public view returns (uint256 paused_) {
        bytes32 slot = _PAUSED_SLOT;
        assembly ("memory-safe") {
            paused_ := sload(slot)
        }
    }

    /// @notice Returns the timestamp until which a session signer is authorized.
    /// @param _signer The session signer address to query.
    /// @return validUntil_ The authorization expiry timestamp, or zero if not authorized.
    function sessionSignerAuthorizedUntil(address _signer)
        public
        view
        returns (uint256 validUntil_)
    {
        bytes32 slot = _SESSION_SIGNER_SLOT;
        assembly ("memory-safe") {
            mstore(0x00, _signer)
            mstore(0x20, slot)
            validUntil_ := sload(keccak256(0x00, 0x40))
        }
    }

    /// @notice Returns the unique identifier assigned to this wallet at deployment.
    /// @return The wallet ID decoded from the ERC-1967 immutable args.
    function id() public view returns (bytes32) {
        (, bytes32 id_) = abi.decode(address(this).argsOnERC1967(), (address, bytes32));
        return id_;
    }

    /// @notice Returns the factory contract that deployed this wallet.
    /// @return The factory address decoded from the ERC-1967 immutable args.
    function factory() public view returns (address) {
        (address factory_,) = abi.decode(address(this).argsOnERC1967(), (address, bytes32));
        return factory_;
    }

    /*--------------------------------------------------------------
                             ONLY FACTORY
    --------------------------------------------------------------*/

    /// @notice Executes a signed batch of calls through the factory.
    /// @dev Validates the batch (non-empty, correct wallet, nonce, deadline), verifies the EIP-712
    ///      signature against the owner or an authorized session signer, then executes each call
    ///      sequentially. Session signers are prevented from calling the wallet itself.
    /// @param _batch The batch containing the target wallet, nonce, deadline, and calls.
    /// @param _signature The EIP-712 signature authorizing the batch (owner or session signer).
    function execute(Batch calldata _batch, bytes calldata _signature) external onlyFactory {
        require(_batch.calls.length > 0, EmptyBatch());
        require(_batch.wallet == address(this), InvalidWallet());
        uint256 executedNonce;
        bytes32 nonceSlot = _NONCE_SLOT;
        assembly ("memory-safe") {
            executedNonce := sload(nonceSlot)
            sstore(nonceSlot, add(executedNonce, 1))
        }
        require(_batch.nonce == executedNonce, InvalidNonce());
        require(block.timestamp <= _batch.deadline, Expired());

        bytes32 batchHash = _batch.hash();
        bytes32 batchDigest = _hashTypedData(batchHash);

        require(
            isValidSignature(batchDigest, _signature) == ERC1271_MAGIC_VALUE, InvalidSignature()
        );

        bool isSessionSigner = _signature.extractSessionSigner() != address(0);

        uint256 i;
        for (; i < _batch.calls.length;) {
            require(
                !isSessionSigner || _batch.calls[i].target != address(this),
                SessionSignerSelfCallNotAllowed()
            );

            (bool success, bytes memory result) =
                _batch.calls[i].target.call{value: _batch.calls[i].value}(_batch.calls[i].data);

            require(success, CallFailed());

            emit Execution(
                _batch.calls[i].target, _batch.calls[i].value, _batch.calls[i].data, result
            );

            unchecked {
                ++i;
            }
        }

        emit BatchExecuted(executedNonce);
    }

    /*--------------------------------------------------------------
                               ONLY SELF
    --------------------------------------------------------------*/

    /// @notice Authorizes a session signer until the specified timestamp.
    /// @dev Can only be invoked via batch execution (self-call).
    /// @param _sessionSigner The address to authorize as a session signer.
    /// @param _validUntil The timestamp until which the session signer is valid.
    function authorizeSessionSigner(address _sessionSigner, uint256 _validUntil) external onlySelf {
        _setSessionSigner(_sessionSigner, _validUntil);

        emit SessionSignerAuthorized(_sessionSigner, _validUntil);
    }

    /// @notice Revokes a session signer's authorization.
    /// @dev Can only be invoked via batch execution (self-call).
    /// @param _sessionSigner The session signer address to revoke.
    function revokeSessionSigner(address _sessionSigner) external onlySelf {
        _setSessionSigner(_sessionSigner, 0);

        emit SessionSignerRevoked(_sessionSigner);
    }

    /// @notice Initiates a two-step ownership transfer to a new owner.
    /// @dev Can only be invoked via batch execution (self-call).
    /// @param _newOwner The proposed new owner address.
    function transferOwnership(address _newOwner) external onlySelf {
        _transferOwnership(_newOwner);
    }

    /// @notice Cancels any pending ownership handover.
    /// @dev Can only be invoked via batch execution (self-call).
    function cancelOwnershipHandover() external onlySelf {
        _cancelOwnershipHandover();
    }

    /// @notice Upgrades the wallet implementation via UUPS.
    /// @dev Can only be invoked via batch execution (self-call).
    ///      The new implementation must be authorized by the factory.
    /// @param _implementation The address of the new implementation contract.
    /// @param _data Optional calldata to execute on the new implementation after upgrade.
    function upgrade(address _implementation, bytes calldata _data) external onlySelf {
        upgradeToAndCall(_implementation, _data);
    }

    /*--------------------------------------------------------------
                           OWNERSHIP HANDOVER
    --------------------------------------------------------------*/

    /// @notice Completes a pending ownership transfer.
    /// @dev Permissionless — anyone may submit, but the pending owner must have signed
    ///      an EIP-712 `OwnershipHandover` message.
    /// @param _deadline The deadline timestamp included in the signed message.
    /// @param _signature The EIP-712 signature from the pending owner.
    function completeOwnershipHandover(uint256 _deadline, bytes calldata _signature) external {
        _completeOwnershipHandover(_deadline, _signature);
    }

    /*--------------------------------------------------------------
                               ONLY OWNER
    --------------------------------------------------------------*/

    /// @notice Pauses the wallet, recording the current timestamp.
    /// @dev After pausing, the owner must wait for the timelock delay before calling
    ///      paused-only functions (e.g., withdrawals, revocations).
    function pause() external onlyOwner {
        bytes32 slot = _PAUSED_SLOT;
        assembly ("memory-safe") {
            sstore(slot, timestamp())
        }

        emit Paused(block.timestamp);
    }

    /// @notice Unpauses the wallet.
    /// @dev Requires the wallet to be paused and the timelock delay to have elapsed.
    function unpause() external onlyPaused onlyOwner {
        bytes32 slot = _PAUSED_SLOT;
        assembly ("memory-safe") {
            sstore(slot, 0)
        }

        emit Unpaused(block.timestamp);
    }

    /// @notice Withdraws ERC-20 tokens from the wallet.
    /// @dev Requires the wallet to be paused and the timelock delay to have elapsed.
    /// @param _token The ERC-20 token address.
    /// @param _to The recipient address.
    /// @param _amount The amount of tokens to withdraw.
    function withdrawERC20(address _token, address _to, uint256 _amount)
        external
        onlyPaused
        onlyOwner
    {
        _token.safeTransfer(_to, _amount);

        emit ERC20Withdrawal(_token, _to, _amount);
    }

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
    ) external onlyPaused onlyOwner {
        ERC1155(_token).safeBatchTransferFrom(address(this), _to, _ids, _amounts, "");

        emit ERC1155BatchWithdrawal(_token, _to, _ids, _amounts);
    }

    /// @notice Revokes an ERC-20 allowance by setting it to zero.
    /// @dev Requires the wallet to be paused and the timelock delay to have elapsed.
    /// @param _token The ERC-20 token address.
    /// @param _spender The spender whose allowance is revoked.
    function revokeAllowance(address _token, address _spender) external onlyPaused onlyOwner {
        _token.safeApprove(_spender, 0);

        emit AllowanceRevoked(_token, _spender);
    }

    /// @notice Revokes an ERC-1155 operator approval.
    /// @dev Requires the wallet to be paused and the timelock delay to have elapsed.
    /// @param _token The ERC-1155 token address.
    /// @param _operator The operator whose approval is revoked.
    function revokeApprovalForAll(address _token, address _operator) external onlyPaused onlyOwner {
        ERC1155(_token).setApprovalForAll(_operator, false);

        emit ApprovalForAllRevoked(_token, _operator);
    }

    /// @notice Emergency revocation of a session signer by the owner.
    /// @dev Requires the wallet to be paused and the timelock delay to have elapsed.
    /// @param _sessionSigner The session signer to revoke.
    function revokeSessionSignerEmergency(address _sessionSigner) external onlyPaused onlyOwner {
        _setSessionSigner(_sessionSigner, 0);

        emit SessionSignerRevokedEmergency(_sessionSigner);
    }

    /*--------------------------------------------------------------
                       UUPS UPGRADE AUTHORIZATION
    --------------------------------------------------------------*/

    /// @dev Authorizes a UUPS upgrade to `_implementation`.
    ///      Reverts unless the implementation is authorized by the factory.
    /// @param _implementation The address of the new implementation contract.
    function _authorizeUpgrade(address _implementation) internal view override onlySelf {
        require(
            DepositWalletFactory(factory()).authorizedImplementation(_implementation),
            InvalidImplementation()
        );
    }

    /// @notice Stores the authorization expiry for a session signer.
    /// @param _signer The session signer address.
    /// @param _validUntil The expiry timestamp (zero to revoke).
    function _setSessionSigner(address _signer, uint256 _validUntil) internal {
        bytes32 slot = _SESSION_SIGNER_SLOT;
        assembly ("memory-safe") {
            mstore(0x00, _signer)
            mstore(0x20, slot)
            sstore(keccak256(0x00, 0x40), _validUntil)
        }
    }

    /*--------------------------------------------------------------
                                ERC1271
    --------------------------------------------------------------*/

    /// @notice Validates a signature against the wallet owner or an authorized session signer.
    /// @dev Overrides Solady's ERC-1271 implementation to support session signer signatures.
    ///      The resolved signer is stored in memory at `_ERC1271_SIGNER_MEM_SLOT` so that
    ///      `_erc1271Signer` can return it to the parent verification logic.
    /// @param _hash The hash that was signed.
    /// @param _signature The signature to validate (may contain a session signer wrapper).
    /// @return result `ERC1271_MAGIC_VALUE` if the signature is valid, otherwise reverts or returns
    /// failure.
    function isValidSignature(bytes32 _hash, bytes calldata _signature)
        public
        view
        override
        returns (bytes4 result)
    {
        address signer = _signature.extractSessionSigner();

        if (signer == address(0)) {
            signer = owner();
        } else {
            require(
                block.timestamp < sessionSignerAuthorizedUntil(signer), SessionSignerUnauthorized()
            );
        }

        assembly {
            mstore(_ERC1271_SIGNER_MEM_SLOT, signer)
            mstore(0x40, add(mload(0x40), 0x20))
        }

        return super.isValidSignature(_hash, _signature);
    }

    /// @dev Returns the signer address previously stored by `isValidSignature`.
    function _erc1271Signer() internal view virtual override returns (address signer) {
        assembly {
            signer := mload(_ERC1271_SIGNER_MEM_SLOT)
        }
    }

    /// @dev Factory calls use the safe caller path (direct ECDSA verification);
    ///      external callers go through the nested EIP-712 workflow.
    function _erc1271CallerIsSafe() internal view virtual override returns (bool) {
        return msg.sender == factory();
    }

    /// @dev Performs ECDSA signature verification against the resolved signer.
    /// @param hash The digest to verify.
    /// @param signature The ECDSA signature bytes.
    /// @return True if the signature is valid for the current signer.
    function _erc1271IsValidSignatureNowCalldata(bytes32 hash, bytes calldata signature)
        internal
        view
        override
        returns (bool)
    {
        address signer = _erc1271Signer();
        // always ECDSA, regardless of signer.code.length
        return (signer != address(0)) && (ECDSA.tryRecoverCalldata(hash, signature) == signer);
    }

    /*--------------------------------------------------------------
                                 EIP712
    --------------------------------------------------------------*/

    /// @dev Returns the EIP-712 domain name and version for this wallet.
    function _domainNameAndVersion()
        internal
        view
        virtual
        override
        returns (string memory name, string memory version)
    {
        name = "DepositWallet";
        version = "1";
    }
}
