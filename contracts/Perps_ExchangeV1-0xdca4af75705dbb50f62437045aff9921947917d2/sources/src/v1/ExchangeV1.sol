// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {StorageV1} from "./StorageV1.sol";

/// @title ExchangeV1
/// @notice Onchain contract that commits Merkle state roots and emits hashes of the state
///         transition data via events. An offchain engine processes trades, incorporates
///         deposits, and periodically commits state roots. Withdrawals are processed by a
///         keeper who submits an EIP-712 signature from the account owner along with a
///         Merkle proof against the last committed state root.
/// @dev    Supported tokens must not be fee-on-transfer, rebasing, or have transfer hooks (e.g. ERC-777).
contract ExchangeV1 is Initializable, EIP712Upgradeable, UUPSUpgradeable, ReentrancyGuardTransient, StorageV1 {
    using SafeERC20 for IERC20;

    bytes32 public constant WITHDRAW_TYPEHASH = keccak256(
        "Withdraw(address account,address token,uint256 amount,uint256 fee,address to,uint64 salt,uint64 ts)"
    );

    /*//////////////////////////////////////////////////////////////
                             MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    /// @dev Reverts if caller is not the contract owner.
    function _onlyOwner() internal view {
        if (msg.sender != owner) revert Unauthorized();
    }

    modifier onlyOperator() {
        _onlyOperator();
        _;
    }

    /// @dev Reverts if caller is not a registered operator.
    function _onlyOperator() internal view {
        if (!operators[msg.sender]) revert Unauthorized();
    }

    modifier onlyKeeper() {
        _onlyKeeper();
        _;
    }

    /// @dev Reverts if caller is not a registered keeper.
    function _onlyKeeper() internal view {
        if (!keepers[msg.sender]) revert Unauthorized();
    }

    /*//////////////////////////////////////////////////////////////
                           INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Contract initializer.
    function initialize(string calldata _name, string calldata _version, address _owner) external virtual initializer {
        _initExchangeV1(_name, _version, _owner);
    }

    /// @dev Initializer body: sets EIP-712 domain and contract owner.
    function _initExchangeV1(string calldata _name, string calldata _version, address _owner)
        internal
        onlyInitializing
    {
        if (_owner == address(0)) revert ZeroAddress();
        __EIP712_init(_name, _version);
        owner = _owner;
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev UUPS upgrade authorization hook; restricted to the contract owner.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @dev Validates an EIP-712 withdrawal signature: rejects signatures dated ahead of the
    ///      current block or older than 1 hour, computes the typed-data digest, and verifies
    ///      the signature against `account`. Supports both EOAs (via ECDSA) and smart
    ///      contract wallets (via ERC-1271 `isValidSignature`). Returns the typed-data digest.
    function _verifyWithdrawal(
        address account,
        address token,
        uint256 amount,
        uint256 fee,
        address to,
        uint64 salt,
        uint64 ts,
        bytes calldata signature
    ) internal view returns (bytes32 digest) {
        if (ts > block.timestamp || block.timestamp - ts > 1 hours) {
            revert SignatureExpired();
        }

        bytes32 typeHash = WITHDRAW_TYPEHASH;
        bytes32 structHash;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, typeHash)
            mstore(add(ptr, 0x20), account)
            mstore(add(ptr, 0x40), token)
            mstore(add(ptr, 0x60), amount)
            mstore(add(ptr, 0x80), fee)
            mstore(add(ptr, 0xa0), to)
            mstore(add(ptr, 0xc0), salt)
            mstore(add(ptr, 0xe0), ts)
            structHash := keccak256(ptr, 0x100)
        }
        digest = _hashTypedDataV4(structHash);

        if (!SignatureChecker.isValidSignatureNowCalldata(account, digest, signature)) {
            revert InvalidSignature();
        }
    }

    /// @dev Verifies a Merkle inclusion proof for the given (account, token, balance) leaf
    ///      against the provided root. Reverts with `InvalidProof` on failure.
    function _verifyProof(bytes32 root, address account, address token, int256 bal, bytes32[] calldata proof)
        internal
        pure
    {
        bytes32 leaf;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, account)
            mstore(add(ptr, 0x20), token)
            mstore(add(ptr, 0x40), bal)
            mstore(ptr, keccak256(ptr, 0x60))
            leaf := keccak256(ptr, 0x20)
        }
        if (!MerkleProof.verifyCalldata(proof, root, leaf)) revert InvalidProof();
    }

    /// @dev Returns the remaining withdrawable amount for (epoch, token, account).
    ///      Returns (0, alreadyWithdrawn) when the proven balance is non-positive; the call
    ///      site decides how to surface that (e.g. via `amount > remaining`).
    function _remainingWithdrawable(uint256 _epoch, address account, address token, int256 balance)
        internal
        view
        returns (uint256 remaining, uint256 alreadyWithdrawn)
    {
        alreadyWithdrawn = withdrawn[_epoch][token][account];
        if (balance <= 0) return (0, alreadyWithdrawn);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 provenBalance = uint256(balance);
        if (alreadyWithdrawn >= provenBalance) return (0, alreadyWithdrawn);
        remaining = provenBalance - alreadyWithdrawn;
    }

    /// @dev Validates deposit parameters, transfers tokens from the caller, and emits a
    ///      {Deposit} event with the observed balance delta — i.e. the amount actually
    ///      received by the contract rather than the requested `amount`.
    function _deposit(address token, uint256 amount, address to) internal {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        uint256 minimum = supportedAssets[token];
        if (minimum == 0) revert AssetNotSupported();

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received < minimum) revert DepositBelowMinimum();

        emit Deposit(msg.sender, token, received, to);
    }

    /// @dev Writes the cumulative `withdrawn` ledger, transfers the net amount to the recipient,
    ///      and emits {WithdrawalCompleted}.
    function _settleWithdrawal(
        uint256 _epoch,
        address account,
        address token,
        uint256 amount,
        uint256 fee,
        address to,
        bytes32 digest,
        uint256 alreadyWithdrawn
    ) internal {
        withdrawn[_epoch][token][account] = alreadyWithdrawn + amount;
        IERC20(token).safeTransfer(to, amount - fee);
        emit WithdrawalCompleted(account, token, amount, fee, to, digest);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Initiates a two-step ownership transfer by nominating a new owner.
    ///         The nominated address must call `acceptOwnership()` to finalize.
    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        pendingOwner = _newOwner;
        emit OwnershipTransferStarted(owner, _newOwner);
    }

    /// @notice Finalizes the ownership transfer. Must be called by the pending owner.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Cancels a pending ownership transfer.
    function cancelPendingTransfer() external onlyOwner {
        address oldPendingOwner = pendingOwner;
        if (oldPendingOwner == address(0)) revert NoPendingTransfer();
        pendingOwner = address(0);
        emit OwnershipTransferCancelled(owner, oldPendingOwner);
    }

    /// @notice Grants or revokes operator privileges for an address. An address cannot hold
    ///         both operator and keeper roles at the same time.
    function setOperator(address _operator, bool _enabled) external onlyOwner {
        if (_enabled && keepers[_operator]) revert RoleConflict();
        operators[_operator] = _enabled;
        emit OperatorModified(_operator, _enabled);
    }

    /// @notice Grants or revokes keeper privileges for an address. Keepers run offchain-signed
    ///         withdrawal processing via `processWithdrawal`. An address cannot hold both
    ///         operator and keeper roles at the same time.
    function setKeeper(address _keeper, bool _enabled) external onlyOwner {
        if (_enabled && operators[_keeper]) revert RoleConflict();
        keepers[_keeper] = _enabled;
        emit KeeperModified(_keeper, _enabled);
    }

    /// @notice Adds or removes an ERC-20 token from the supported deposit list and sets its minimum deposit.
    /// @dev    Token must not be fee-on-transfer, rebasing, or have transfer hooks (e.g. ERC-777).
    ///         A non-zero `_minAmount` enables the asset; zero disables it.
    function setAsset(address _token, uint256 _minAmount) external onlyOwner {
        if (_token == address(0)) revert ZeroAddress();
        supportedAssets[_token] = _minAmount;
        emit SupportedAssetModified(_token, _minAmount != 0, _minAmount);
    }

    /*//////////////////////////////////////////////////////////////
                             OPERATOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Operator commits a new Merkle state root and transition data hash.
    ///         The state root is a Merkle tree over all (account, token, balance) tuples,
    ///         computed by replaying state transitions from genesis. The hash identifies
    ///         the blob for retrieving the full state transition data.
    function commitStateRoot(bytes32 _stateRoot, bytes32 _hash) external virtual onlyOperator {
        if (_stateRoot == bytes32(0)) revert ZeroValue();

        stateRoot = _stateRoot;
        unchecked {
            ++epoch;
        }

        emit StateRootCommitted(epoch, _stateRoot, _hash);
    }

    /// @notice Keeper processes a withdrawal requested through the offchain system.
    ///         Requires an EIP-712 signature from the account owner and a Merkle proof
    ///         that the account's balance in the last committed state root covers the amount.
    function processWithdrawal(
        address account,
        address token,
        uint256 amount,
        uint256 fee,
        address to,
        uint64 salt,
        uint64 timestamp,
        bytes calldata signature,
        int256 balance,
        bytes32[] calldata proof
    ) external virtual onlyKeeper nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (fee >= amount) revert FeeTooHigh();
        if (to == address(0)) revert ZeroAddress();
        bytes32 root = stateRoot;
        if (root == bytes32(0)) revert NoStateRoot();

        _verifyProof(root, account, token, balance, proof);
        (uint256 remaining, uint256 alreadyWithdrawn) = _remainingWithdrawable(epoch, account, token, balance);
        if (amount > remaining) revert InsufficientBalance();

        bytes32 digest = _verifyWithdrawal(account, token, amount, fee, to, salt, timestamp, signature);

        if (usedDigests[digest]) revert DigestAlreadyUsed();
        usedDigests[digest] = true;

        _settleWithdrawal(epoch, account, token, amount, fee, to, digest, alreadyWithdrawn);
    }

    /*//////////////////////////////////////////////////////////////
                               USER
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit ERC-20 tokens into the exchange. Tokens are held by the contract
    ///         and the deposit is picked up by the offchain engine via the emitted event.
    ///         The next committed state root will reflect this deposit.
    /// @param token The ERC-20 token address to deposit.
    /// @param amount The amount of tokens to deposit.
    /// @param to The account to credit the deposit to.
    function deposit(address token, uint256 amount, address to) external virtual nonReentrant {
        _deposit(token, amount, to);
    }

    /// @notice Deposit with ERC-2612 permit — approve and deposit in a single tx.
    /// @param token The ERC-20 token address to deposit (must support ERC-2612).
    /// @param amount The amount of tokens to deposit.
    /// @param to The account to credit the deposit to.
    /// @param deadline Timestamp after which the permit signature expires.
    /// @param v Recovery byte of the permit signature.
    /// @param r First 32 bytes of the permit signature.
    /// @param s Second 32 bytes of the permit signature.
    function depositWithPermit(
        address token,
        uint256 amount,
        address to,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual nonReentrant {
        // Skip permit if allowance already covers it — sidesteps signature front-running and
        // lets real permit reverts surface instead of getting masked as insufficient allowance.
        if (IERC20(token).allowance(msg.sender, address(this)) < amount) {
            IERC20Permit(token).permit(msg.sender, address(this), amount, deadline, v, r, s);
        }
        _deposit(token, amount, to);
    }
}
