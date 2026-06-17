// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { ERC20 } from "@solady/src/tokens/ERC20.sol";
import { SafeTransferLib } from "@solady/src/utils/SafeTransferLib.sol";

import { IConditionalTokens } from "@polymarket-v2/src/legacy/interfaces/IConditionalTokens.sol";
import { CTHelpers } from "@polymarket-v2/src/legacy/libraries/CTHelpers.sol";
import { CTFHelpers } from "@polymarket-v2/src/legacy/libraries/CTFHelpers.sol";
import { ConditionId, ConditionIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { BaseModule } from "@polymarket-v2/src/modules/abstract/BaseModule.sol";

/// @title IWrappedCollateral
/// @notice Interface for wrapped collateral tokens used during legacy migration
interface IWrappedCollateral {
    /// @notice Unwrap wrapped collateral and send underlying to recipient
    /// @param _to Recipient of the underlying token
    /// @param _amount Amount to unwrap
    function unwrap(address _to, uint256 _amount) external;
}

/// @title MigrationEvents
/// @notice Events emitted during legacy position migration
abstract contract MigrationEvents {
    /// @notice Emitted when a legacy position is migrated to the new system
    /// @param from The address migrating positions
    /// @param conditionId The structured condition ID
    /// @param positionId The new position ID
    /// @param outcomeIndex The outcome index (0 or 1)
    /// @param amount The amount migrated
    event PositionMigrated(
        address indexed from,
        ConditionId indexed conditionId,
        PositionId indexed positionId,
        uint256 outcomeIndex,
        uint256 amount
    );

    /// @notice Emitted when a legacy condition is registered for migration.
    /// @dev Binary mixins emit once per `prepareMigrationCondition`. Neg-risk mixins emit once
    ///      per condition inside `prepareMigrationEvent`.
    /// @param v2ConditionId The structured V2 condition ID.
    /// @param legacyConditionId The linked legacy CTF condition ID.
    event MigrationConditionRegistered(ConditionId indexed v2ConditionId, bytes32 indexed legacyConditionId);

    /// @notice Emitted when a migration condition is resolved from legacy CTF payouts.
    /// @dev Fires from `_resolveMigrationCondition` after the structured result has been stored.
    ///      Carries both the raw legacy payout numerators (denominator = legacyPayout0 +
    ///      legacyPayout1) and the normalized V2 result so indexers can audit the rounding.
    /// @param conditionId The structured V2 condition ID.
    /// @param legacyConditionId The legacy CTF condition ID the result was read from.
    /// @param legacyPayout0 Raw YES payout numerator from the legacy CTF.
    /// @param legacyPayout1 Raw NO payout numerator from the legacy CTF.
    /// @param result0 Normalized YES payout (sums with result1 to RESULT_DENOMINATOR).
    /// @param result1 Normalized NO payout.
    event MigrationResolved(
        ConditionId indexed conditionId,
        bytes32 indexed legacyConditionId,
        uint256 legacyPayout0,
        uint256 legacyPayout1,
        uint256 result0,
        uint256 result1
    );

    /// @notice Emitted each time legacy collateral held by the module is settled to the vault.
    /// @dev Fires once per non-empty branch of `_settleLegacyCollateralToVault` (USDC.e direct
    ///      transfer; wrapped legacy collateral unwrap). Either or both may fire per call.
    /// @param legacyToken The token transferred to (or unwrapped into) the vault.
    /// @param vault The collateral vault address that received the funds.
    /// @param amount Amount settled.
    event LegacyCollateralSettled(address indexed legacyToken, address indexed vault, uint256 amount);
}

/// @title MigrationErrors
/// @notice Custom errors for migration operations
abstract contract MigrationErrors {
    /// @notice Thrown when a migration condition has already been registered
    error MigrationAlreadyRegistered();
    /// @notice Thrown when a condition has not been registered for migration
    error MigrationNotRegistered();
}

/// @title BaseMigrationMixin
/// @author Polymarket
/// @notice Shared migration logic for transferring legacy CTF positions into the new system.
/// @dev Concrete migration mixins must implement the virtual hooks that supply legacy contract
///      references, ID translation, migration registration checks, and legacy redemption.
///      Modules may also override `_finalizeMigrationResolution` to enforce aggregate invariants.
abstract contract BaseMigrationMixin is BaseModule, MigrationEvents, MigrationErrors {
    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @dev Reserved storage gap for future base upgrades.
    uint256[50] private __gap;

    /*--------------------------------------------------------------
                          LEGACY MIGRATION
    --------------------------------------------------------------*/

    /// @notice Migrate legacy CTF positions to new positions
    /// @param _legacyConditionIds Array of legacy CTF condition IDs to migrate
    /// @param _outcomeIndices Array of outcome indices (0 or 1) for each condition
    /// @param _amounts Array of amounts for each position
    function migratePositions(
        bytes32[] calldata _legacyConditionIds,
        uint256[] calldata _outcomeIndices,
        uint256[] calldata _amounts
    ) external {
        _migratePositions(msg.sender, _legacyConditionIds, _outcomeIndices, _amounts);
    }

    /// @notice Allows operator to migrate positions on behalf
    /// @dev onlyOperator
    /// @param _from Address to migrate from
    /// @param _legacyConditionIds Array of legacy CTF condition IDs to migrate
    /// @param _outcomeIndices Array of outcome indices (0 or 1) for each condition
    /// @param _amounts Array of amounts for each position
    function migratePositions(
        address _from,
        bytes32[] calldata _legacyConditionIds,
        uint256[] calldata _outcomeIndices,
        uint256[] calldata _amounts
    ) external onlyOperator {
        _migratePositions(_from, _legacyConditionIds, _outcomeIndices, _amounts);
    }

    /// @notice Resolve a migration condition based on legacy CTF payouts.
    /// @dev Validates canonical input then delegates to `_resolveMigrationCondition`. The
    ///      canonicality check at the entry blocks alias-key state corruption before any
    ///      state read.
    /// @param _conditionId The structured conditionId (NOT legacy)
    function resolveMigrationCondition(bytes32 _conditionId) external {
        _resolveMigrationCondition(ConditionIdLib.from(_conditionId));
    }

    /// @dev Reads payouts from the legacy CTF, stores a normalised result, redeems the
    ///      module's legacy positions into the vault, and delegates aggregate bookkeeping
    ///      to `_finalizeMigrationResolution`. Respects the admin `resolutionPausedAt`
    ///      kill switch. Reused by callers that already hold a canonical `ConditionId`
    ///      (e.g. `NegRiskModule.resolveConditionToNo` routing migrated losers through
    ///      this path so legacy redemption is not skipped).
    /// @param _conditionId The structured condition being resolved
    function _resolveMigrationCondition(ConditionId _conditionId) internal {
        require(result[_conditionId].length == 0, ConditionAlreadyResolved());
        require(resolutionPausedAt[_conditionId] == 0, ResolutionIsPaused());

        bytes32 legacyConditionId_ = _getLegacyConditionIdForResolve(_conditionId);

        uint256 legacyPayout0 = _legacyConditionalTokens().payoutNumerators(legacyConditionId_, 0);
        uint256 legacyPayout1 = _legacyConditionalTokens().payoutNumerators(legacyConditionId_, 1);
        uint256 payoutDenominator = legacyPayout0 + legacyPayout1;

        require(payoutDenominator > 0, ConditionNotResolved());

        uint256[] memory result_ = new uint256[](2);
        result_[0] = legacyPayout0 * RESULT_DENOMINATOR / payoutDenominator;
        result_[1] = RESULT_DENOMINATOR - result_[0];

        _finalizeMigrationResolution(_conditionId, result_);

        emit MigrationResolved(_conditionId, legacyConditionId_, legacyPayout0, legacyPayout1, result_[0], result_[1]);

        _redeemLegacyPositions(legacyConditionId_);
        _settleLegacyCollateralToVault();
    }

    /*--------------------------------------------------------------
                          INTERNAL FUNCTIONS
    --------------------------------------------------------------*/

    /// @notice Returns the legacy CTF contract used for migration
    function _legacyConditionalTokens() internal view virtual returns (IConditionalTokens);

    /// @notice Returns the collateral token used by the legacy CTF
    function _legacyCollateralToken() internal view virtual returns (address);

    /// @notice Translates a legacy CTF condition ID into a structured condition ID
    function _legacyConditionIdToConditionId(bytes32 _legacyConditionId) internal view virtual returns (ConditionId);

    /// @notice Returns the USDC.e token address for vault deposits
    function _usdce() internal view virtual returns (address);

    /// @notice Checks if a condition has been registered for migration
    function _isMigrationCondition(ConditionId _conditionId) internal view virtual returns (bool);

    /// @notice Returns the legacy CTF condition ID used to resolve a structured condition.
    /// @param _conditionId The structured condition ID being resolved
    /// @return The legacy CTF condition ID used to read payout numerators
    function _getLegacyConditionIdForResolve(ConditionId _conditionId) internal view virtual returns (bytes32);

    /// @notice Redeems the module's legacy positions against the legacy CTF.
    /// @dev Implemented by concrete mixins to supply the correct collateral token.
    /// @param _legacyConditionId The legacy condition ID whose positions are being redeemed
    function _redeemLegacyPositions(bytes32 _legacyConditionId) internal virtual;

    /// @notice Finalise a migration-path resolution.
    /// @dev Default implementation mirrors the simple store+emit flow used by binary migration.
    ///      Modules that track aggregate invariants (e.g. neg-risk) override this to update
    ///      their counters and enforce the same checks applied on the `reportResult` path.
    /// @param _conditionId The structured condition being resolved
    /// @param _result The normalised payout vector (length 2, summing to RESULT_DENOMINATOR)
    function _finalizeMigrationResolution(ConditionId _conditionId, uint256[] memory _result) internal virtual {
        _storeResult(_conditionId, _result);

        emit ResultReported(address(this), _conditionId, _result);
    }

    /// @dev Migrate legacy positions to new format
    function _migratePositions(
        address _from,
        bytes32[] calldata _legacyConditionIds,
        uint256[] calldata _outcomeIndices,
        uint256[] calldata _amounts
    ) internal {
        require(_legacyConditionIds.length == _outcomeIndices.length, InvalidArrayLength());
        require(_legacyConditionIds.length == _amounts.length, InvalidArrayLength());
        require(_from != address(this), InvalidFromAddress());

        PositionId[] memory positionIds = _buildTransferAndMint(_from, _legacyConditionIds, _outcomeIndices, _amounts);

        _mergeComplementaryAndEmit(_legacyConditionIds, _outcomeIndices, _amounts, positionIds, _from);

        _settleLegacyCollateralToVault();
    }

    /// @dev Builds position ID arrays, transfers legacy positions in, and mints new positions.
    ///      Isolated into its own frame to keep `_migratePositions` stack depth under the EVM
    ///      limit. `PositionManager.batchMint` does not invoke `onERC1155BatchReceived` on
    ///      `_from`.
    /// @return positionIds The newly-minted position IDs
    function _buildTransferAndMint(
        address _from,
        bytes32[] calldata _legacyConditionIds,
        uint256[] calldata _outcomeIndices,
        uint256[] calldata _amounts
    ) private returns (PositionId[] memory positionIds) {
        uint256 length = _legacyConditionIds.length;
        uint256[] memory legacyPositionIds = new uint256[](length);
        positionIds = new PositionId[](length);
        address legacyCollateral_ = _legacyCollateralToken();

        for (uint256 i = 0; i < length; ++i) {
            bytes32 legacyConditionId_ = _legacyConditionIds[i];
            uint256 outcomeIndex = _outcomeIndices[i];
            require(outcomeIndex < 2, InvalidOutcomeIndex());

            ConditionId conditionId = _legacyConditionIdToConditionId(legacyConditionId_);
            require(_isMigrationCondition(conditionId), MigrationNotRegistered());
            require(result[conditionId].length == 0, ConditionAlreadyResolved());

            positionIds[i] = conditionId.computePositionId(outcomeIndex);
            legacyPositionIds[i] = CTHelpers.getPositionId(
                legacyCollateral_, CTHelpers.getCollectionId(bytes32(0), legacyConditionId_, outcomeIndex + 1)
            );
        }

        _legacyConditionalTokens().safeBatchTransferFrom(_from, address(this), legacyPositionIds, _amounts, "");
        POSITION_MANAGER.batchMint(_from, positionIds, _amounts);
    }

    /// @dev Merges complementary legacy positions held by the module and emits
    ///      PositionMigrated for each migrated position.
    function _mergeComplementaryAndEmit(
        bytes32[] calldata _legacyConditionIds,
        uint256[] calldata _outcomeIndices,
        uint256[] calldata _amounts,
        PositionId[] memory _positionIds,
        address _from
    ) internal {
        uint256[] memory partition_ = CTFHelpers.partition();
        uint256 length = _legacyConditionIds.length;
        address legacyCollateral_ = _legacyCollateralToken();
        IConditionalTokens legacyCT_ = _legacyConditionalTokens();

        for (uint256 i = 0; i < length; ++i) {
            uint256 amount = _amounts[i];
            if (amount != 0) {
                bytes32 legacyConditionId_ = _legacyConditionIds[i];
                uint256 outcomeIndex_ = _outcomeIndices[i];
                _mergeComplementaryLegacyPositions(
                    legacyCT_, legacyCollateral_, legacyConditionId_, outcomeIndex_, partition_
                );

                emit PositionMigrated(_from, _positionIds[i].conditionId(), _positionIds[i], outcomeIndex_, amount);
            }
        }
    }

    function _mergeComplementaryLegacyPositions(
        IConditionalTokens _legacyCT,
        address _legacyCollateral,
        bytes32 _legacyConditionId,
        uint256 _outcomeIndex,
        uint256[] memory _partition
    ) private {
        uint256 complementaryAmount = _legacyCT.balanceOf(
            address(this),
            CTHelpers.getPositionId(
                _legacyCollateral, CTHelpers.getCollectionId(bytes32(0), _legacyConditionId, 2 - _outcomeIndex)
            )
        );
        if (complementaryAmount == 0) return;

        uint256 amountToMerge = _legacyCT.balanceOf(
            address(this),
            CTHelpers.getPositionId(
                _legacyCollateral, CTHelpers.getCollectionId(bytes32(0), _legacyConditionId, _outcomeIndex + 1)
            )
        );
        if (amountToMerge > complementaryAmount) amountToMerge = complementaryAmount;
        if (amountToMerge == 0) return;

        // forgefmt: disable-next-item
        _legacyCT.mergePositions({
            collateralToken: _legacyCollateral,
            parentCollectionId: bytes32(0),
            conditionId: _legacyConditionId,
            partition: _partition,
            amount: amountToMerge
        });
    }

    /// @dev Settle legacy collateral into the collateral vault (unwrap if needed).
    function _settleLegacyCollateralToVault() internal {
        address usdce_ = _usdce();
        address vault_ = COLLATERAL_TOKEN.VAULT();

        if (usdce_ != address(0)) {
            uint256 usdceAmount = ERC20(usdce_).balanceOf(address(this));
            if (usdceAmount > 0) {
                SafeTransferLib.safeTransfer(usdce_, vault_, usdceAmount);
                emit LegacyCollateralSettled(usdce_, vault_, usdceAmount);
            }
        }

        address legacyCollateralToken_ = _legacyCollateralToken();
        if (legacyCollateralToken_ != address(0) && legacyCollateralToken_ != usdce_) {
            uint256 legacyAmount = ERC20(legacyCollateralToken_).balanceOf(address(this));
            if (legacyAmount > 0) {
                IWrappedCollateral(legacyCollateralToken_).unwrap(vault_, legacyAmount);
                emit LegacyCollateralSettled(legacyCollateralToken_, vault_, legacyAmount);
            }
        }
    }
}
