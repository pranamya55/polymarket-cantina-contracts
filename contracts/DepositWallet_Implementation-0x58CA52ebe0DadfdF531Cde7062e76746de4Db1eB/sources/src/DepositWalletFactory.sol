// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {OwnableRoles} from "@solady/src/auth/OwnableRoles.sol";
import {Initializable} from "@solady/src/utils/Initializable.sol";
import {LibClone} from "@solady/src/utils/LibClone.sol";
import {UUPSUpgradeable} from "@solady/src/utils/UUPSUpgradeable.sol";

import {IDepositWallet, Batch} from "@deposit-wallet/src/interfaces/IDepositWallet.sol";

/// @title DepositWalletFactoryErrors
/// @author Polymarket
/// @notice Custom errors for {DepositWalletFactory}.
abstract contract DepositWalletFactoryErrors {
    /// @notice Thrown when the caller does not have the admin role.
    error OnlyAdmin();

    /// @notice Thrown when the caller does not have the operator role.
    error OnlyOperator();

    /// @notice Thrown when paired input arrays have mismatched lengths.
    error ArrayLengthMismatch();

    /// @notice Thrown when the zero address is provided where a valid address is required.
    error ZeroAddress();

    /// @notice Thrown when an implementation has not been authorized.
    error ImplementationNotAuthorized();

    /// @notice Thrown when the provided timelock delay is zero or exceeds the maximum.
    error InvalidTimelockDelay();
}

/// @title DepositWalletFactoryEvents
/// @author Polymarket
/// @notice Events emitted by {DepositWalletFactory}.
abstract contract DepositWalletFactoryEvents {
    /// @notice Emitted when a wallet implementation is added to the authorized set.
    /// @param implementation The address of the authorized implementation.
    event ImplementationAuthorized(address indexed implementation);

    /// @notice Emitted when the default wallet implementation is updated.
    /// @param Implementation The address of the new default implementation.
    event ImplementationSet(address Implementation);

    /// @notice Emitted when a wallet implementation is removed from the authorized set.
    /// @param implementation The address of the unauthorized implementation.
    event ImplementationUnauthorized(address indexed implementation);

    /// @notice Emitted when the timelock delay is updated.
    /// @param timelockDelay The new timelock delay in seconds.
    event TimelockDelaySet(uint256 timelockDelay);

    /// @notice Emitted when a new deposit wallet is deployed.
    /// @param wallet The address of the newly deployed wallet proxy.
    /// @param owner The initial owner of the wallet.
    /// @param id The unique identifier assigned to the wallet.
    /// @param implementation The implementation address used for the deployment.
    event WalletDeployed(
        address indexed wallet, address indexed owner, bytes32 indexed id, address implementation
    );
}

/// @title DepositWalletFactory
/// @author Polymarket
/// @notice Factory contract for deploying and managing DepositWallet proxies.
/// @dev Uses a three-tier role model:
///      - **Owner**: can add/remove admins, manage implementations, and authorize UUPS upgrades
///                   of the factory itself.
///      - **Admin** (ROLE_0): can add/remove operators and configure the timelock delay.
///      - **Operator** (ROLE_1): can deploy wallets and proxy batch executions.
///
///      Wallets are deployed as deterministic ERC-1967 proxies via {LibClone}.
contract DepositWalletFactory is
    OwnableRoles,
    Initializable,
    UUPSUpgradeable,
    DepositWalletFactoryErrors,
    DepositWalletFactoryEvents
{
    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice The default wallet implementation used for new deployments.
    address public implementation;

    /// @notice The delay in seconds that must elapse after pausing before the owner can
    ///         execute paused-only operations on a wallet.
    uint256 public timelockDelay;

    /// @notice Tracks which implementation addresses are authorized for UUPS upgrades.
    mapping(address => bool) public authorizedImplementation;

    /*--------------------------------------------------------------
                               CONSTANTS
    --------------------------------------------------------------*/

    /// @notice The maximum allowed timelock delay (7 days).
    uint256 public constant MAX_TIMELOCK_DELAY = 7 days;

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

    /// @notice Initializes the factory with an owner, admin, implementation, and timelock delay.
    /// @param _owner The address to set as the factory owner.
    /// @param _admin The address to grant the initial admin role.
    /// @param _implementation The default wallet implementation address.
    /// @param _timelockDelay The initial timelock delay in seconds.
    function initialize(
        address _owner,
        address _admin,
        address _implementation,
        uint256 _timelockDelay
    ) external initializer {
        _initializeOwner(_owner);
        _setRoles(_admin, _ROLE_0);
        _authorizeImplementation(_implementation);
        _setImplementation(_implementation);
        _setTimelockDelay(_timelockDelay);
    }

    /*--------------------------------------------------------------
                               MODIFIERS
    --------------------------------------------------------------*/

    /// @dev Restricts access to addresses with the admin role (ROLE_0).
    modifier onlyAdmin() {
        require(hasAnyRole(msg.sender, _ROLE_0), OnlyAdmin());
        _;
    }

    /// @dev Restricts access to addresses with the operator role (ROLE_1).
    modifier onlyOperator() {
        require(hasAnyRole(msg.sender, _ROLE_1), OnlyOperator());
        _;
    }

    /*--------------------------------------------------------------
                                  VIEW
    --------------------------------------------------------------*/

    /// @notice Returns whether the given address has the admin role.
    /// @param _admin The address to check.
    /// @return True if the address is an admin.
    function isAdmin(address _admin) external view returns (bool) {
        return hasAnyRole(_admin, _ROLE_0);
    }

    /// @notice Returns whether the given address has the operator role.
    /// @param _operator The address to check.
    /// @return True if the address is an operator.
    function isOperator(address _operator) external view returns (bool) {
        return hasAnyRole(_operator, _ROLE_1);
    }

    /// @notice Predicts the deterministic address of a wallet before deployment.
    /// @param _implementation The implementation address to use for the prediction.
    /// @param _id The unique identifier for the wallet.
    /// @return The predicted wallet proxy address.
    function predictWalletAddress(address _implementation, bytes32 _id)
        external
        view
        returns (address)
    {
        bytes memory args = abi.encode(address(this), _id);

        return LibClone.predictDeterministicAddressERC1967(
            _implementation, args, keccak256(args), address(this)
        );
    }

    /*--------------------------------------------------------------
                             ONLY OPERATOR
    --------------------------------------------------------------*/

    /// @notice Deploys one or more deposit wallets with deterministic addresses.
    /// @dev It is the operator's responsibility to ensure that each `_id` is unique.
    ///      Duplicate IDs will cause the deployment to revert.
    /// @param _owners The initial owner addresses for each wallet.
    /// @param _ids The unique identifiers for each wallet.
    function deploy(address[] calldata _owners, bytes32[] calldata _ids) external onlyOperator {
        require(_owners.length == _ids.length, ArrayLengthMismatch());

        address implementation_ = implementation;
        require(authorizedImplementation[implementation_], ImplementationNotAuthorized());

        for (uint256 i; i < _owners.length; ++i) {
            bytes memory args = abi.encode(address(this), _ids[i]);

            address wallet =
                LibClone.deployDeterministicERC1967(implementation_, args, keccak256(args));

            IDepositWallet(wallet).initialize(_owners[i]);

            emit WalletDeployed(wallet, _owners[i], _ids[i], implementation_);
        }
    }

    /// @notice Proxies batch execution to one or more wallets.
    /// @dev Each batch is forwarded to its target wallet's `execute` function.
    /// @param _batches The batches to execute.
    /// @param _signatures The corresponding signatures for each batch.
    function proxy(Batch[] calldata _batches, bytes[] calldata _signatures) external onlyOperator {
        require(_batches.length == _signatures.length, ArrayLengthMismatch());
        for (uint256 i; i < _batches.length; ++i) {
            IDepositWallet(_batches[i].wallet).execute(_batches[i], _signatures[i]);
        }
    }

    /*--------------------------------------------------------------
                               ONLY ADMIN
    --------------------------------------------------------------*/

    /// @notice Grants the operator role to an address.
    /// @param _operator The address to grant the operator role.
    function addOperator(address _operator) external onlyAdmin {
        _grantRoles(_operator, _ROLE_1);
    }

    /// @notice Removes the operator role from an address.
    /// @param _operator The address to remove the operator role from.
    function removeOperator(address _operator) external onlyAdmin {
        _removeRoles(_operator, _ROLE_1);
    }

    /// @notice Sets the timelock delay for paused wallet operations.
    /// @param _timelockDelay The new timelock delay in seconds.
    function setTimelockDelay(uint256 _timelockDelay) external onlyAdmin {
        _setTimelockDelay(_timelockDelay);
    }

    /*--------------------------------------------------------------
                               ONLY OWNER
    --------------------------------------------------------------*/

    /// @notice Grants the admin role to an address.
    /// @param _admin The address to grant the admin role.
    function addAdmin(address _admin) external onlyOwner {
        _grantRoles(_admin, _ROLE_0);
    }

    /// @notice Removes the admin role from an address.
    /// @param _admin The address to remove the admin role from.
    function removeAdmin(address _admin) external onlyOwner {
        _removeRoles(_admin, _ROLE_0);
    }

    /// @notice Sets the default wallet implementation for new deployments.
    /// @param _implementation The new default implementation address.
    function setImplementation(address _implementation) external onlyOwner {
        _setImplementation(_implementation);
    }

    /// @notice Authorizes an implementation address for wallet UUPS upgrades.
    /// @param _implementation The implementation address to authorize.
    function authorizeImplementation(address _implementation) external onlyOwner {
        _authorizeImplementation(_implementation);
    }

    /// @notice Removes an implementation address from the authorized set.
    /// @param _implementation The implementation address to unauthorize.
    function unauthorizeImplementation(address _implementation) external onlyOwner {
        authorizedImplementation[_implementation] = false;

        emit ImplementationUnauthorized(_implementation);
    }

    /*--------------------------------------------------------------
                               INTERNAL
    --------------------------------------------------------------*/

    /// @dev Authorizes UUPS upgrades of the factory. Restricted to the owner.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Authorizes an implementation address and records it in the authorized set.
    /// @param _implementation The implementation address to authorize (must not be `address(0)`).
    function _authorizeImplementation(address _implementation) internal {
        require(_implementation != address(0), ZeroAddress());
        authorizedImplementation[_implementation] = true;

        emit ImplementationAuthorized(_implementation);
    }

    /// @notice Sets the default wallet implementation for new deployments.
    /// @param _implementation The new default implementation address (must be authorized).
    function _setImplementation(address _implementation) internal {
        require(authorizedImplementation[_implementation], ImplementationNotAuthorized());
        implementation = _implementation;

        emit ImplementationSet(_implementation);
    }

    /// @notice Sets the timelock delay for paused wallet operations.
    /// @param _timelockDelay The new timelock delay in seconds.
    function _setTimelockDelay(uint256 _timelockDelay) internal {
        require(_timelockDelay > 0 && _timelockDelay <= MAX_TIMELOCK_DELAY, InvalidTimelockDelay());
        timelockDelay = _timelockDelay;

        emit TimelockDelaySet(_timelockDelay);
    }
}
