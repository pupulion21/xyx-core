// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IAgentRegistry} from "../interfaces/IAgentRegistry.sol";
import {ITaskLifecycle} from "../interfaces/ITaskLifecycle.sol";
import {IDisputeResolver} from "../interfaces/IDisputeResolver.sol";
import {IExecutionEngine} from "../interfaces/IExecutionEngine.sol";
import {BFT} from "../libraries/BFT.sol";
import {TaskStateLib} from "../libraries/TaskStateLib.sol";
import {XYXConstants} from "../libraries/XYXConstants.sol";

/// @title ExecutionEngine
/// @notice Orchestrator that executes dispute resolutions (slash + reward distribution)
/// @dev The ExecutionEngine is the only contract permitted to call AgentRegistry.slash /
///      slashAndForward / updateReputation. This makes it the single source of truth for
///      protocol economic consequences of disputes.
///
///      Distribution model (per PRD §FR-5.1):
///      - On `winnerSupport=true` (disputer wins): slash the primary task participant at
///        AGENT_SLASH_BPS (10%). Distribute slash pool: 30% to disputer, 60% to honest jurors,
///        10% to treasury.
///      - On `winnerSupport=false` (agent wins): slash the disputer at FRIVOLOUS_DISPUTE_SLASH_BPS
///        (15%). Distribute slash pool: 60% to honest jurors, 10% to treasury, NO agent reward
///        (the agent already got the task reward).
///      - Outlier jurors: slashed at JUROR_OUTLIER_SLASH_BPS (50%), reputation -15.
///      - Honest jurors: +1 reputation, share of 60% pool.
///      - Agent on the losing side: reputation -10.
///      - Agent on the winning side: reputation +2 (or no change if disputer wins AND agent is
///        the one being punished).
///
///      Pull-payment model (D11): juror rewards are credited to `pendingJurorReward[juror]`
///      and must be claimed via `withdrawJurorReward()`. Saves gas on large juror sets.
contract ExecutionEngine is ReentrancyGuard, Ownable2Step, IExecutionEngine {
    using BFT for BFT.Vote[];
    using TaskStateLib for TaskStateLib.State;

    // ============================================================================
    //                                 STORAGE
    // ============================================================================

    IAgentRegistry public immutable registry;
    ITaskLifecycle public immutable taskLifecycle;
    IDisputeResolver public disputeResolver; // Mutable: wired after construction

    /// @notice Protocol treasury (separate from AgentRegistry.treasuryBalance which holds
    ///         registration fees + unclaimed slashes from other paths). The 10% treasury cut
    ///         from dispute distributions lands here.
    address public treasury;
    uint256 public treasuryBalance;

    /// @notice Tracks which disputeIds have been executed (prevents re-execution).
    mapping(uint256 => bool) public resolved;

    // ============================================================================
    //                                  EVENTS
    // ============================================================================

    event DisputeNotified(uint256 indexed taskId, uint256 indexed disputeId, uint256 fee);
    event DisputeExecuted(
        uint256 indexed disputeId,
        bool winnerSupport,
        bool inconclusive,
        uint256 slashAmount,
        uint256 jurorPool,
        uint256 winnerPayout,
        uint256 treasuryCut
    );
    event JurorOutlierSlashed(uint256 indexed disputeId, address indexed juror, uint256 amount);
    event LoserSlashed(uint256 indexed disputeId, address indexed loser, uint256 amount);
    event ReputationUpdated(
        uint256 indexed agentId, bool success, bool isDispute, address indexed subject
    );
    event TreasuryCut(uint256 indexed disputeId, uint256 amount);
    event WithdrawalFailed(address indexed to, uint256 amount);
    event TreasuryWithdrawn(address indexed to, uint256 amount);
    event TreasuryAddressUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ============================================================================
    //                                 ERRORS
    // ============================================================================

    error NotDisputeResolver(address caller);
    error AlreadyResolved(uint256 disputeId);
    error DisputeResolverNotSet();
    error TransferFailed();
    error NoHonestJurors();
    error InvalidTreasury();
    error EmptyVoteWeight();

    // ============================================================================
    //                                CONSTRUCTOR
    // ============================================================================

    constructor(address initialOwner, address _registry, address _taskLifecycle, address _treasury)
        Ownable(initialOwner)
    {
        if (_treasury == address(0)) revert InvalidTreasury();
        registry = IAgentRegistry(_registry);
        taskLifecycle = ITaskLifecycle(_taskLifecycle);
        treasury = _treasury;
    }

    /// @notice Set the DisputeResolver address. Must be called by owner after DisputeResolver is deployed.
    function setDisputeResolver(address _disputeResolver) external onlyOwner {
        disputeResolver = IDisputeResolver(_disputeResolver);
    }

    /// @notice Update the treasury address. Only callable by owner.
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidTreasury();
        emit TreasuryAddressUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    // ============================================================================
    //                          DISPUTE LIFECYCLE (FR-3.1)
    // ============================================================================

    /// @inheritdoc IExecutionEngine
    /// @dev Called by DisputeResolver after it creates a dispute record. Forwards the task
    ///      to TaskLifecycle.markDisputed. The dispute fee accumulates in this contract's
    ///      treasury (separate from AgentRegistry's registration-fee treasury).
    function notifyDisputeCreated(uint256 taskId, uint256 disputeId) external payable override {
        if (msg.sender != address(disputeResolver)) revert NotDisputeResolver(msg.sender);
        if (address(disputeResolver) == address(0)) revert DisputeResolverNotSet();

        // Mark the task as Disputed (onlyOwner of TaskLifecycle, which is this contract)
        taskLifecycle.markDisputed(taskId, disputeId);

        // Accrue the dispute fee to this contract's treasury
        if (msg.value > 0) {
            treasuryBalance += msg.value;
        }

        emit DisputeNotified(taskId, disputeId, msg.value);
    }

    // ============================================================================
    //                          RESOLUTION EXECUTION (FR-5.1)
    // ============================================================================

    /// @inheritdoc IExecutionEngine
    /// @dev Executes a BFT resolution. Distribution logic:
    ///      - Pulls the dispute view (taskId, disputer, jurors) from DisputeResolver.
    ///      - On inconclusive: emit event, return (no-op).
    ///      - On decisive:
    ///          1. Slash the loser (agent if winnerSupport=true, disputer if false).
    ///          2. Slash outlier jurors (JUROR_OUTLIER_SLASH_BPS, 50%).
    ///          3. Distribute slash pool: 60% to honest jurors (per weight), 30% to winner
    ///             (only when winnerSupport=true), 10% to treasury.
    ///          4. Update reputations.
    ///      ReentrancyGuard prevents cross-contract reentrancy via fallback functions.
    function executeResolution(uint256 disputeId, BFT.Resolution memory resolution) external override nonReentrant {
        if (msg.sender != address(disputeResolver)) revert NotDisputeResolver(msg.sender);
        if (address(disputeResolver) == address(0)) revert DisputeResolverNotSet();
        if (resolved[disputeId]) revert AlreadyResolved(disputeId);

        IDisputeResolver.DisputeView memory dv = disputeResolver.getDisputeView(disputeId);
        if (dv.disputeId == 0) revert AlreadyResolved(disputeId); // Unknown dispute

        resolved[disputeId] = true;

        if (resolution.inconclusive) {
            // No-op: no slash, no reward, no reputation change
            emit DisputeExecuted(disputeId, resolution.winnerSupport, true, 0, 0, 0, 0);
            return;
        }

        // Identify the losing party and the winner
        address loser;
        address winner;
        uint256 loserSlashBps;
        bool winnerGetsReward;

        if (resolution.winnerSupport) {
            // Disputer wins: the agent's answer was wrong
            address[] memory taskParts = taskLifecycle.getParticipants(dv.taskId);
            if (taskParts.length == 0) {
                // Defensive: shouldn't happen for a valid task
                emit DisputeExecuted(disputeId, true, false, 0, 0, 0, 0);
                return;
            }
            loser = taskParts[0];
            winner = dv.disputer;
            loserSlashBps = XYXConstants.AGENT_SLASH_BPS; // 10%
            winnerGetsReward = true;
        } else {
            // Agent wins: the dispute was frivolous
            loser = dv.disputer;
            address[] memory taskParts = taskLifecycle.getParticipants(dv.taskId);
            winner = taskParts.length > 0 ? taskParts[0] : address(0);
            loserSlashBps = XYXConstants.FRIVOLOUS_DISPUTE_SLASH_BPS; // 15%
            winnerGetsReward = false; // Agent already got the task reward
        }

        // Step 1: Slash the loser
        uint256 loserAgentId = registry.getAgentByOwner(loser);
        uint256 slashAmount = 0;
        if (loserAgentId != 0) {
            // slashAndForward sends the slashed ETH directly to this contract
            slashAmount = registry.slashAndForward(
                loserAgentId, loserSlashBps, payable(address(this))
            );
            emit LoserSlashed(disputeId, loser, slashAmount);
            // Update loser reputation (failed task / frivolous dispute)
            registry.updateReputation(loserAgentId, false, true);
            emit ReputationUpdated(loserAgentId, false, true, loser);
        }

        // Step 2: Slash outlier jurors
        uint256 outlierSlashTotal = 0;
        for (uint256 i = 0; i < resolution.outliers.length; i++) {
            address outlier = resolution.outliers[i];
            uint256 outlierAgentId = registry.getAgentByOwner(outlier);
            if (outlierAgentId == 0) continue;
            // Outliers are slashed at JUROR_OUTLIER_SLASH_BPS. We do NOT forward their slash
            // (it goes to AgentRegistry's internal treasury) — outliers are punished, not
            // redistributed. This protects honest jurors from penalizing the pool further.
            uint256 out = registry.slash(outlierAgentId, XYXConstants.JUROR_OUTLIER_SLASH_BPS);
            outlierSlashTotal += out;
            // Reputation -15 for voting outlier (applyFinalStrike equivalent — but we want
            // them to be able to recover, so just -15 via onDisputeLost)
            registry.updateReputation(outlierAgentId, false, true);
            emit ReputationUpdated(outlierAgentId, false, true, outlier);
            emit JurorOutlierSlashed(disputeId, outlier, out);
        }

        // Step 3: Compute distribution from the loser's slash amount
        // (outlier slashes go to AgentRegistry's treasury, NOT to the distribution pool)
        uint256 jurorPool = (slashAmount * XYXConstants.JUROR_REWARD_SHARE)
            / XYXConstants.REWARD_DISTRIBUTION_DENOM;
        uint256 winnerPayout = winnerGetsReward
            ? (slashAmount * XYXConstants.WINNER_REWARD_SHARE) / XYXConstants.REWARD_DISTRIBUTION_DENOM
            : 0;
        uint256 treasuryCut = (slashAmount * XYXConstants.TREASURY_SHARE)
            / XYXConstants.REWARD_DISTRIBUTION_DENOM;

        // Step 4: Distribute to honest jurors (per weight)
        _distributeToJurors(disputeId, dv.jurors, resolution, jurorPool);

        // Step 5: Pay the winner (if applicable)
        if (winnerGetsReward && winnerPayout > 0 && winner != address(0)) {
            (bool paid,) = payable(winner).call{value: winnerPayout}("");
            if (!paid) {
                // Refund to treasury on failure (defensive)
                treasuryBalance += winnerPayout;
                emit WithdrawalFailed(winner, winnerPayout);
            }
        }

        // Step 6: Accrue treasury cut
        if (treasuryCut > 0) {
            treasuryBalance += treasuryCut;
            emit TreasuryCut(disputeId, treasuryCut);
        }

        // Step 7: Update reputation for the winner (agent or disputer)
        if (winner != address(0)) {
            uint256 winnerAgentId = registry.getAgentByOwner(winner);
            if (winnerAgentId != 0) {
                registry.updateReputation(winnerAgentId, true, true);
                emit ReputationUpdated(winnerAgentId, true, true, winner);
            }
        }

        // Step 8: Honest jurors get +1 reputation
        _bumpHonestJurorReputation(dv.jurors, resolution);

        emit DisputeExecuted(
            disputeId, resolution.winnerSupport, false, slashAmount, jurorPool, winnerPayout, treasuryCut
        );
    }

    // ============================================================================
    //                          TREASURY MANAGEMENT
    // ============================================================================

    /// @notice Withdraw protocol treasury (the 10% cut from dispute resolutions + dispute fees).
    function withdrawTreasury() external onlyOwner {
        uint256 amount = treasuryBalance;
        treasuryBalance = 0;
        (bool success,) = payable(treasury).call{value: amount}("");
        if (!success) {
            treasuryBalance = amount;
            revert TransferFailed();
        }
        emit TreasuryWithdrawn(treasury, amount);
    }

    /// @notice Receive ETH (for distributing slash payouts and dispute fees)
    receive() external payable {
        // Allow direct deposits to fund the engine's payouts
    }

    // ============================================================================
    //                                INTERNAL
    // ============================================================================

    /// @notice Distribute `pool` to honest jurors (non-outliers) pro-rata by vote weight.
    /// @dev Uses the snapshot of juror weights from the BFT.Resolution. We use the total
    ///      weight of honest jurors to compute each juror's share.
    function _distributeToJurors(
        uint256 disputeId,
        address[] memory jurors,
        BFT.Resolution memory resolution,
        uint256 pool
    ) internal {
        if (pool == 0 || jurors.length == 0) return;

        // Compute total honest weight
        uint256 totalHonestWeight;
        for (uint256 i = 0; i < jurors.length; i++) {
            if (_isOutlier(resolution, jurors[i])) continue;
            // Read weight from registry (snapshot from BFT is in resolution.votes but BFT
            // doesn't include weight in the public Resolution struct — so re-read here).
            // To save gas, we could capture weights in Resolution, but that's a refactor.
            // For now, re-read from registry.
            uint256 jurorAgentId = registry.getAgentByOwner(jurors[i]);
            if (jurorAgentId == 0) continue;
            totalHonestWeight += registry.getVoteWeight(jurorAgentId);
        }

        if (totalHonestWeight == 0) {
            // All honest jurors got slashed to 0 weight somehow — put pool into treasury
            treasuryBalance += pool;
            return;
        }

        // Distribute pro-rata
        // Pre-fund the resolver so it can pay jurors via pull-payment (withdrawJurorReward).
        if (pool > 0) {
            (bool funded,) = payable(address(disputeResolver)).call{value: pool}("");
            require(funded, "resolver funding failed");
        }
        for (uint256 i = 0; i < jurors.length; i++) {
            if (_isOutlier(resolution, jurors[i])) continue;
            uint256 jurorAgentId = registry.getAgentByOwner(jurors[i]);
            if (jurorAgentId == 0) continue;
            uint256 weight = registry.getVoteWeight(jurorAgentId);
            if (weight == 0) continue;
            uint256 share = (pool * weight) / totalHonestWeight;
            if (share == 0) continue;
            // Credit to juror (pull-payment)
            disputeResolver.creditJurorReward(jurors[i], share, disputeId);
        }
    }

    /// @notice Bump reputation of every honest juror by +1.
    function _bumpHonestJurorReputation(
        address[] memory jurors,
        BFT.Resolution memory resolution
    ) internal {
        for (uint256 i = 0; i < jurors.length; i++) {
            if (_isOutlier(resolution, jurors[i])) continue;
            uint256 jurorAgentId = registry.getAgentByOwner(jurors[i]);
            if (jurorAgentId == 0) continue;
            registry.updateReputation(jurorAgentId, true, true);
            emit ReputationUpdated(jurorAgentId, true, true, jurors[i]);
        }
    }

    /// @notice Check if an address is in the outliers list.
    function _isOutlier(BFT.Resolution memory resolution, address who) internal pure returns (bool) {
        for (uint256 i = 0; i < resolution.outliers.length; i++) {
            if (resolution.outliers[i] == who) return true;
        }
        return false;
    }
}
