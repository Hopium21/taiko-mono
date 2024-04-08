// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../common/IAddressResolver.sol";
import "../../verifiers/IVerifier.sol";
import "../tiers/ITierProvider.sol";
import "./LibUtils.sol";

/// @title LibProving
/// @notice A library for handling block contestation and proving in the Taiko
/// protocol.
/// @custom:security-contact security@taiko.xyz
library LibProving {
    using LibMath for uint256;
    using SafeERC20 for IERC20;

    /// @notice The tier name for optimistic proofs.
    bytes32 private constant TIER_OP = bytes32("tier_optimistic");

    // Warning: Any events defined here must also be defined in TaikoEvents.sol.
    /// @notice Emitted when a transition is proved.
    /// @param blockId The block ID.
    /// @param tran The transition data.
    /// @param prover The prover's address.
    /// @param validityBond The validity bond amount.
    /// @param tier The tier of the proof.
    event TransitionProved(
        uint256 indexed blockId,
        TaikoData.Transition tran,
        address prover,
        uint96 validityBond,
        uint16 tier
    );

    /// @notice Emitted when a transition is contested.
    /// @param blockId The block ID.
    /// @param tran The transition data.
    /// @param contester The contester's address.
    /// @param contestBond The contest bond amount.
    /// @param tier The tier of the proof.
    event TransitionContested(
        uint256 indexed blockId,
        TaikoData.Transition tran,
        address contester,
        uint96 contestBond,
        uint16 tier
    );

    /// @notice Emitted when proving is paused or unpaused.
    /// @param paused The pause status.
    event ProvingPaused(bool paused);

    // Warning: Any errors defined here must also be defined in TaikoErrors.sol.
    error L1_ALREADY_CONTESTED();
    error L1_ALREADY_PROVED();
    error L1_BLOCK_MISMATCH();
    error L1_INVALID_BLOCK_ID();
    error L1_INVALID_PAUSE_STATUS();
    error L1_INVALID_TIER();
    error L1_INVALID_TRANSITION();
    error L1_MISSING_VERIFIER();
    error L1_NOT_ASSIGNED_PROVER();
    error L1_CANNOT_CONTEST();

    /// @notice Pauses or unpauses the proving process.
    /// @param _state Current TaikoData.State.
    /// @param _pause The pause status.
    function pauseProving(TaikoData.State storage _state, bool _pause) internal {
        if (_state.slotB.provingPaused == _pause) revert L1_INVALID_PAUSE_STATUS();
        _state.slotB.provingPaused = _pause;

        if (!_pause) {
            _state.slotB.lastUnpausedAt = uint64(block.timestamp);
        }
        emit ProvingPaused(_pause);
    }

    /// @dev Proves or contests a block transition.
    /// @param _state Current TaikoData.State.
    /// @param _config Actual TaikoData.Config.
    /// @param _resolver Address resolver interface.
    /// @param _meta The block's metadata.
    /// @param _tran The transition data.
    /// @param _proof The proof.
    /// @return The number of blocks to be verified with this transaction.
    function proveBlock(
        TaikoData.State storage _state,
        TaikoData.Config memory _config,
        IAddressResolver _resolver,
        TaikoData.BlockMetadata memory _meta,
        TaikoData.Transition memory _tran,
        TaikoData.TierProof memory _proof
    )
        internal
        returns (uint8)
    {
        // Make sure parentHash is not zero
        // To contest an existing transition, simply use any non-zero value as
        // the blockHash and stateRoot.
        if (_tran.parentHash == 0 || _tran.blockHash == 0 || _tran.stateRoot == 0) {
            revert L1_INVALID_TRANSITION();
        }

        // Check that the block has been proposed but has not yet been verified.
        TaikoData.SlotB memory b = _state.slotB;
        if (_meta.id <= b.lastVerifiedBlockId || _meta.id >= b.numBlocks) {
            revert L1_INVALID_BLOCK_ID();
        }

        uint64 slot = _meta.id % _config.blockRingBufferSize;
        TaikoData.Block storage blk = _state.blocks[slot];

        // Check the integrity of the block data. It's worth noting that in
        // theory, this check may be skipped, but it's included for added
        // caution.
        if (blk.blockId != _meta.id || blk.metaHash != keccak256(abi.encode(_meta))) {
            revert L1_BLOCK_MISMATCH();
        }

        // Each transition is uniquely identified by the parentHash, with the
        // blockHash and stateRoot open for later updates as higher-tier proofs
        // become available. In cases where a transition with the specified
        // parentHash does not exist, the transition ID (tid) will be set to 0.
        (uint32 tid, TaikoData.TransitionState storage ts) =
            _fetchOrCreateTransition(_state, blk, _tran, slot);

        // The new proof must meet or exceed the minimum tier required by the
        // block or the previous proof; it cannot be on a lower tier.
        if (_proof.tier == 0 || _proof.tier < _meta.minTier || _proof.tier < ts.tier) {
            revert L1_INVALID_TIER();
        }

        // Retrieve the tier configurations. If the tier is not supported, the
        // subsequent action will result in a revert.
        ITierProvider.Tier memory tier =
            ITierProvider(_resolver.resolve("tier_provider", false)).getTier(_proof.tier);

        // Checks if only the assigned prover is permissioned to prove the block.
        // The guardian prover is granted exclusive permisison to prove only the first
        // transition.
        if (
            tier.contestBond != 0 && ts.contester == address(0) && tid == 1 && ts.tier == 0
                && !LibUtils.isPostDeadline(ts.timestamp, b.lastUnpausedAt, tier.provingWindow)
        ) {
            if (msg.sender != blk.assignedProver) revert L1_NOT_ASSIGNED_PROVER();
        }

        // We must verify the proof, and any failure in proof verification will
        // result in a revert.
        //
        // It's crucial to emphasize that the proof can be assessed in two
        // potential modes: "proving mode" and "contesting mode." However, the
        // precise verification logic is defined within each tier's IVerifier
        // contract implementation. We simply specify to the verifier contract
        // which mode it should utilize - if the new tier is higher than the
        // previous tier, we employ the proving mode; otherwise, we employ the
        // contesting mode (the new tier cannot be lower than the previous tier,
        // this has been checked above).
        //
        // It's obvious that proof verification is entirely decoupled from
        // Taiko's core protocol.
        {
            address verifier = _resolver.resolve(tier.verifierName, true);

            if (verifier != address(0)) {
                bool isContesting = _proof.tier == ts.tier && tier.contestBond != 0;

                IVerifier.Context memory ctx = IVerifier.Context({
                    metaHash: blk.metaHash,
                    blobHash: _meta.blobHash,
                    // Separate msgSender to allow the prover to be any address in the future.
                    prover: msg.sender,
                    msgSender: msg.sender,
                    blockId: blk.blockId,
                    isContesting: isContesting,
                    blobUsed: _meta.blobUsed
                });

                IVerifier(verifier).verifyProof(ctx, _tran, _proof);
            } else if (tier.verifierName != TIER_OP) {
                // The verifier can be address-zero, signifying that there are no
                // proof checks for the tier. In practice, this only applies to
                // optimistic proofs.
                revert L1_MISSING_VERIFIER();
            }
        }

        IERC20 tko = IERC20(_resolver.resolve("taiko_token", false));

        bool inProvingWindow =
            !LibUtils.isPostDeadline(ts.timestamp, b.lastUnpausedAt, tier.provingWindow);

        // The guardian prover refund the liveness fund to the assign prover.
        if (tier.contestBond == 0) {
            if (blk.livenessBond != 0) {
                if (inProvingWindow) {
                    tko.safeTransfer(blk.assignedProver, blk.livenessBond);
                }
                blk.livenessBond = 0;
            }
        }

        bool sameTransition = _tran.blockHash == ts.blockHash && _tran.stateRoot == ts.stateRoot;

        if (_proof.tier > ts.tier) {
            // Handles the case when an incoming tier is higher than the current transition's tier.
            // Reverts when the incoming proof tries to prove the same transition
            // (L1_ALREADY_PROVED).

            // Higher tier proof overwriting lower tier proof
            {
                uint256 reward; // reward to the new (current) prover

                if (ts.contester != address(0)) {
                    if (sameTransition) {
                        // The contested transition is proven to be valid, contester loses the game
                        reward = _rewardAfterFriction(ts.contestBond);

                        // We return the validity bond back, but the original prover doesn't get any
                        // reward.
                        tko.safeTransfer(ts.prover, ts.validityBond);
                    } else {
                        // The contested transition is proven to be invalid, contester wins the
                        // game.
                        // Contester gets 3/4 of reward, the new prover gets 1/4.
                        reward = _rewardAfterFriction(ts.validityBond) >> 2;

                        tko.safeTransfer(ts.contester, ts.contestBond + reward * 3);
                    }
                } else {
                    if (sameTransition) revert L1_ALREADY_PROVED();

                    // The code below will be executed if
                    // - 1) the transition is proved for the fist time, or
                    // - 2) the transition is contested.
                    reward = _rewardAfterFriction(ts.validityBond);

                    if (blk.livenessBond != 0) {
                        if (blk.assignedProver == msg.sender && inProvingWindow) {
                            unchecked {
                                reward += blk.livenessBond;
                            }
                        }
                        blk.livenessBond = 0;
                    }
                }

                unchecked {
                    if (reward > tier.validityBond) {
                        tko.safeTransfer(msg.sender, reward - tier.validityBond);
                    } else if (reward < tier.validityBond) {
                        tko.safeTransferFrom(msg.sender, address(this), tier.validityBond - reward);
                    }
                }
            }

            ts.validityBond = tier.validityBond;
            ts.contestBond = 1; // to save gas
            ts.contester = address(0);
            ts.prover = msg.sender;
            ts.tier = _proof.tier;

            if (!sameTransition) {
                ts.blockHash = _tran.blockHash;
                ts.stateRoot = _tran.stateRoot;
            }

            emit TransitionProved({
                blockId: blk.blockId,
                tran: _tran,
                prover: msg.sender,
                validityBond: tier.validityBond,
                tier: _proof.tier
            });
        } else {
            // New transition and old transition on the same tier - and if this transaction tries to
            // prove the same, it reverts
            if (sameTransition) revert L1_ALREADY_PROVED();

            if (tier.contestBond == 0) {
                // The top tier prover re-proves.
                assert(tier.validityBond == 0);
                assert(ts.validityBond == 0 && ts.contester == address(0));

                ts.prover = msg.sender;
                ts.blockHash = _tran.blockHash;
                ts.stateRoot = _tran.stateRoot;

                emit TransitionProved({
                    blockId: blk.blockId,
                    tran: _tran,
                    prover: msg.sender,
                    validityBond: 0,
                    tier: _proof.tier
                });
            } else {
                // Contesting but not on the highest tier
                if (ts.contester != address(0)) revert L1_ALREADY_CONTESTED();

                // Making it a non-sliding window, relative when ts.timestamp was registered (or to
                // lastUnpaused if that one is bigger)
                if (LibUtils.isPostDeadline(ts.timestamp, b.lastUnpausedAt, tier.cooldownWindow)) {
                    revert L1_CANNOT_CONTEST();
                }

                // _checkIfContestable(/*_state,*/ tier.cooldownWindow, ts.timestamp);
                // Burn the contest bond from the prover.
                tko.safeTransferFrom(msg.sender, address(this), tier.contestBond);

                // We retain the contest bond within the transition, just in
                // case this configuration is altered to a different value
                // before the contest is resolved.
                //
                // It's worth noting that the previous value of ts.contestBond
                // doesn't have any significance.
                ts.contestBond = tier.contestBond;
                ts.contester = msg.sender;

                emit TransitionContested({
                    blockId: blk.blockId,
                    tran: _tran,
                    contester: msg.sender,
                    contestBond: tier.contestBond,
                    tier: _proof.tier
                });
            }
        }

        ts.timestamp = uint64(block.timestamp);
        return tier.maxBlocksToVerifyPerProof;
    }

    /// @dev Handle the transition initialization logic
    function _fetchOrCreateTransition(
        TaikoData.State storage _state,
        TaikoData.Block storage _blk,
        TaikoData.Transition memory _tran,
        uint64 slot
    )
        private
        returns (uint32 tid_, TaikoData.TransitionState storage ts_)
    {
        tid_ = LibUtils.getTransitionId(_state, _blk, slot, _tran.parentHash);

        if (tid_ == 0) {
            // In cases where a transition with the provided parentHash is not
            // found, we must essentially "create" one and set it to its initial
            // state. This initial state can be viewed as a special transition
            // on tier-0.
            //
            // Subsequently, we transform this tier-0 transition into a
            // non-zero-tier transition with a proof. This approach ensures that
            // the same logic is applicable for both 0-to-non-zero transition
            // updates and non-zero-to-non-zero transition updates.
            unchecked {
                // Unchecked is safe:  Not realistic 2**32 different fork choice
                // per block will be proven and none of them is valid
                tid_ = _blk.nextTransitionId++;
            }

            // Keep in mind that state.transitions are also reusable storage
            // slots, so it's necessary to reinitialize all transition fields
            // below.
            ts_ = _state.transitions[slot][tid_];
            ts_.blockHash = 0;
            ts_.stateRoot = 0;
            ts_.validityBond = 0;
            ts_.contester = address(0);
            ts_.contestBond = 1; // to save gas
            ts_.timestamp = _blk.proposedAt;
            ts_.tier = 0;
            ts_.__reserved1 = 0;

            if (tid_ == 1) {
                // This approach serves as a cost-saving technique for the
                // majority of blocks, where the first transition is expected to
                // be the correct one. Writing to `transitions` is more economical
                // since it resides in the ring buffer, whereas writing to
                // `transitionIds` is not as cost-effective.
                ts_.key = _tran.parentHash;

                // In the case of this first transition, the block's assigned
                // prover has the privilege to re-prove it, but only when the
                // assigned prover matches the previous prover. To ensure this,
                // we establish the transition's prover as the block's assigned
                // prover. Consequently, when we carry out a 0-to-non-zero
                // transition update, the previous prover will consistently be
                // the block's assigned prover.
                //
                // While alternative implementations are possible, introducing
                // such changes would require additional if-else logic.
                ts_.prover = _blk.assignedProver;
            } else {
                // In scenarios where this transition is not the first one, we
                // straightforwardly reset the transition prover to address
                // zero.
                ts_.prover = address(0);

                // Furthermore, we index the transition for future retrieval.
                // It's worth emphasizing that this mapping for indexing is not
                // reusable. However, given that the majority of blocks will
                // only possess one transition — the correct one — we don't need
                // to be concerned about the cost in this case.
                _state.transitionIds[_blk.blockId][_tran.parentHash] = tid_;

                // There is no need to initialize ts.key here because it's only used when tid == 1
            }
        } else {
            // A transition with the provided parentHash has been located.
            ts_ = _state.transitions[slot][tid_];
        }
    }

    /// @dev Returns the reward after applying 12.5% friction.
    function _rewardAfterFriction(uint256 _amount) private pure returns (uint256) {
        return _amount == 0 ? 0 : (_amount * 7) >> 3;
    }
}
