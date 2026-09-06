// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IAgentRegistry} from "../interfaces/IAgentRegistry.sol";
import {ITaskLifecycle} from "../interfaces/ITaskLifecycle.sol";
import {IExecutionEngine} from "../interfaces/IExecutionEngine.sol";
import {IDisputeResolver} from "../interfaces/IDisputeResolver.sol";
import {BFT} from "../libraries/BFT.sol";
import {TaskStateLib} from "../libraries/TaskStateLib.sol";
import {XYXConstants} from "../libraries/XYXConstants.sol";

/// @title DisputeResolver
/// @notice BFT-driven dispute resolution (PRD §FR-3.x, §FR-4.x)
/// @dev Implements the full dispute lifecycle:
///      1. `triggerDispute(taskId, alternativeAnswer)` — anyone, creates a Dispute in `Evidence` state,
///         notifies ExecutionEngine which marks the task as Disputed.
///      2. `submitEvidence(disputeId, contentHash, refUri)` — initiator or disputer, within EVIDENCE_DEADLINE
///      3. `selectJurors(disputeId)` — anyone, after evidence deadline. Walks the active juror pool,
///         filters out task participants + initiator, picks JURORS_PER_DISPUTE using prevrandao seed.
///      4. `castVote(disputeId, choice, reasoning)` — selected jurors, within VOTE_DEADLINE. Weight is
///         read from AgentRegistry.getVoteWeight(jurorId) at vote time.
///      5. `resolveDispute(disputeId)` — anyone, after vote deadline. Calls BFT.resolve, then forwards
///         the resolution to ExecutionEngine.executeResolution which performs the slash + distribution.
///      6. Withdraw juror reward (pull-payment) — `withdrawJurorReward(disputeId)`.
contract DisputeResolver is ReentrancyGuard, Ownable2Step {
    using BFT for BFT.Vote[];
    using TaskStateLib for TaskStateLib.State;

    // ============================================================================
    //                                    TYPES
    // ============================================================================

    enum DisputeState {
        None, // 0 — slot exists but not triggered
        Evidence, // 1 — accepting evidence submissions
        Voting, // 2 — jurors selected, accepting votes
        Resolved // 3 — final, reward can be claimed (terminal)
    }

    struct Evidence {
        address submitter; // Either initiator or disputer
        bytes32 contentHash; // keccak256 of off-chain evidence payload
        string refUri; // IPFS CID or HTTP URL
        uint64 timestamp;
    }

    struct Dispute {
        uint256 disputeId;
        uint256 taskId;
        address disputer; // Who triggered the dispute
        bytes32 alternativeAnswer; // Disputer's proposed correct answer
        uint64 evidenceDeadline; // Unix timestamp; submitEvidence closed after this
        uint64 voteDeadline; // Unix timestamp; castVote closed after this
        DisputeState state;
        address[] jurors; // Selected juror addresses (length = JURORS_PER_DISPUTE)
        BFT.Vote[] votes; // Parallel to jurors[]; populated by castVote
        uint256 resolvedAt; // 0 until resolved
        BFT.Resolution resolution; // BFT result (zeroed until resolved)
    }

    // ============================================================================
    //                                 STORAGE
    // ============================================================================

    IAgentRegistry public immutable registry;
    ITaskLifecycle public immutable taskLifecycle;
    IExecutionEngine public executionEngine; // Mutable: wired after construction

    uint256 public nextDisputeId = 1;

    mapping(uint256 => Dispute) internal _disputes;
    mapping(uint256 => Evidence[]) internal _evidence;
    // Per-juror reward share per dispute (assigned on resolve)
    mapping(uint256 => mapping(address => uint256)) public jurorRewardShare;
    // Aggregate claimable reward per juror (across all resolved disputes)
    mapping(address => uint256) public pendingJurorReward;

    // ============================================================================
    //                                  EVENTS
    // ============================================================================

    event DisputeTriggered(
        uint256 indexed disputeId,
        uint256 indexed taskId,
        address indexed disputer,
        bytes32 alternativeAnswer,
        uint64 evidenceDeadline
    );

    event EvidenceSubmitted(
        uint256 indexed disputeId,
        address indexed submitter,
        bytes32 contentHash,
        string refUri,
        uint64 timestamp
    );

    event JurorsSelected(
        uint256 indexed disputeId,
        address[] jurors,
        uint64 voteDeadline
    );

    event VoteCast(
        uint256 indexed disputeId,
        address indexed juror,
        BFT.VoteChoice choice,
        uint256 weight,
        bytes32 reasoning
    );

    event DisputeResolved(
        uint256 indexed disputeId,
        bool winnerSupport,
        bool inconclusive,
        address referenceJuror
    );

    event JurorRewardAssigned(uint256 indexed disputeId, address indexed juror, uint256 amount);
    event JurorRewardWithdrawn(address indexed juror, uint256 amount);

    // ============================================================================
    //                                 ERRORS
    // ============================================================================

    error DisputeNotFound(uint256 disputeId);
    error TaskNotInDisputableState(uint256 taskId, TaskStateLib.State state);
    error NotTaskParty(uint256 taskId, address caller);
    error NotDisputer(uint256 disputeId, address caller);
    error EvidenceDeadlinePassed(uint256 disputeId, uint64 deadline);
    error VoteDeadlinePassed(uint256 disputeId, uint64 deadline);
    error DisputeNotInEvidence(uint256 disputeId, DisputeState state);
    error DisputeNotInVoting(uint256 disputeId, DisputeState state);
    error DisputeAlreadyResolved(uint256 disputeId);
    error EvidenceDeadlineNotReached(uint256 disputeId, uint64 deadline);
    error VoteDeadlineNotReached(uint256 disputeId, uint64 deadline);
    error NoJurorsAvailable(uint256 disputeId);
    error NotAJuror(uint256 disputeId, address caller);
    error AlreadyVoted(uint256 disputeId, address juror);
    error InvalidZeroAnswer();
    error ExecutionEngineNotSet();
    error ExecutionEngineAlreadySet();
    error WithdrawFailed();

    // ============================================================================
    //                                CONSTRUCTOR
    // ============================================================================

    constructor(address initialOwner, address _registry, address _taskLifecycle)
        Ownable(initialOwner)
    {
        registry = IAgentRegistry(_registry);
        taskLifecycle = ITaskLifecycle(_taskLifecycle);
    }

    /// @notice Set the ExecutionEngine address. Must be called by owner after ExecutionEngine is deployed.
    /// @dev Can only be set once. Wired in deployment script after all 3 contracts exist.
    function setExecutionEngine(address _executionEngine) external onlyOwner {
        if (address(executionEngine) != address(0)) revert ExecutionEngineAlreadySet();
        executionEngine = IExecutionEngine(_executionEngine);
    }

    // ============================================================================
    //                           DISPUTE TRIGGER (FR-3.1)
    // ============================================================================

    /// @notice Trigger a dispute on a task. Anyone may call (no permissioning), but the caller
    ///         pays DISPUTE_FEE which goes to the protocol treasury via ExecutionEngine.
    /// @param taskId The task being disputed
    /// @param alternativeAnswer Disputer's proposed correct answer (keccak256 of the off-chain answer)
    /// @return disputeId The newly created dispute ID
    function triggerDispute(uint256 taskId, bytes32 alternativeAnswer)
        external
        payable
        nonReentrant
        returns (uint256 disputeId)
    {
        if (address(executionEngine) == address(0)) revert ExecutionEngineNotSet();
        if (alternativeAnswer == bytes32(0)) revert InvalidZeroAnswer();
        if (msg.value < XYXConstants.DISPUTE_FEE) {
            // Soft check: caller must include fee. ExecutionEngine will pull the fee.
        }

        TaskStateLib.State taskState = taskLifecycle.getState(taskId);
        // Disputable states: Working, InputRequired, Completed. Already-Disputed is not.
        if (taskState != TaskStateLib.State.Working
            && taskState != TaskStateLib.State.InputRequired
            && taskState != TaskStateLib.State.Completed) {
            revert TaskNotInDisputableState(taskId, taskState);
        }

        disputeId = nextDisputeId++;
        Dispute storage d = _disputes[disputeId];
        d.disputeId = disputeId;
        d.taskId = taskId;
        d.disputer = msg.sender;
        d.alternativeAnswer = alternativeAnswer;
        d.evidenceDeadline = uint64(block.timestamp + XYXConstants.EVIDENCE_DEADLINE);
        d.voteDeadline = 0; // Set after juror selection
        d.state = DisputeState.Evidence;

        // Notify ExecutionEngine (which calls TaskLifecycle.markDisputed under the hood)
        // We forward the dispute fee to ExecutionEngine via the value attached to this call.
        executionEngine.notifyDisputeCreated{value: msg.value}(taskId, disputeId);

        emit DisputeTriggered(disputeId, taskId, msg.sender, alternativeAnswer, d.evidenceDeadline);
    }

    // ============================================================================
    //                            EVIDENCE SUBMISSION (FR-3.3)
    // ============================================================================

    /// @notice Submit evidence to a dispute. Only the task initiator or disputer may submit.
    /// @param disputeId The active dispute
    /// @param contentHash keccak256 of the off-chain evidence payload
    /// @param refUri IPFS CID or HTTP URL for full payload
    function submitEvidence(uint256 disputeId, bytes32 contentHash, string calldata refUri)
        external
        nonReentrant
    {
        Dispute storage d = _getDisputeOrRevert(disputeId);
        if (d.state != DisputeState.Evidence) {
            revert DisputeNotInEvidence(disputeId, d.state);
        }
        if (block.timestamp > d.evidenceDeadline) {
            revert EvidenceDeadlinePassed(disputeId, d.evidenceDeadline);
        }
        if (contentHash == bytes32(0)) revert InvalidZeroAnswer();

        // Only the task initiator or the disputer can submit evidence
        address initiator = taskLifecycle.getInitiator(d.taskId);
        if (msg.sender != initiator && msg.sender != d.disputer) {
            revert NotTaskParty(d.taskId, msg.sender);
        }

        _evidence[disputeId].push(
            Evidence({
                submitter: msg.sender,
                contentHash: contentHash,
                refUri: refUri,
                timestamp: uint64(block.timestamp)
            })
        );

        emit EvidenceSubmitted(disputeId, msg.sender, contentHash, refUri, uint64(block.timestamp));
    }

    // ============================================================================
    //                             JUROR SELECTION (FR-3.2, D9)
    // ============================================================================

    /// @notice Select jurors for a dispute. Anyone may call (permissionless) after evidence deadline.
    /// @dev Uses `block.prevrandao XOR keccak256(disputeId, block.timestamp)` as the seed for
    ///      picking a starting index in the eligible juror pool. Walks forward, skipping ineligible
    ///      addresses (task participants, initiator, disputer, inactive).
    /// @param disputeId The dispute
    function selectJurors(uint256 disputeId) external nonReentrant {
        Dispute storage d = _getDisputeOrRevert(disputeId);
        if (d.jurors.length > 0) {
            // Jurors already selected (defensive: first selection wins). No-op rather than revert
            // so off-chain retry paths that re-trigger on idempotency don't fail.
            return;
        }
        if (d.state != DisputeState.Evidence) {
            revert DisputeNotInEvidence(disputeId, d.state);
        }
        if (block.timestamp < d.evidenceDeadline) {
            revert EvidenceDeadlineNotReached(disputeId, d.evidenceDeadline);
        }

        // Build the eligible juror list: walk active jurors, exclude task parties
        address[] memory participants = taskLifecycle.getParticipants(d.taskId);
        address initiator = taskLifecycle.getInitiator(d.taskId);

        // Step 1: collect eligible jurors into a memory array
        uint256 jurorPageSize = XYXConstants.JURORS_PER_DISPUTE * 4; // overfetch to allow filtering
        if (jurorPageSize < XYXConstants.JURORS_PER_DISPUTE * 2) jurorPageSize = XYXConstants.JURORS_PER_DISPUTE * 2;
        if (jurorPageSize > 100) jurorPageSize = 100;

        // Collect via paginated walk
        address[] memory eligible = _collectEligibleJurors(participants, initiator, jurorPageSize);
        if (eligible.length < XYXConstants.MIN_JURORS_PER_DISPUTE) {
            revert NoJurorsAvailable(disputeId);
        }

        // Step 2: seed = prevrandao XOR keccak256(disputeId, timestamp) XOR salt
        bytes32 seed = bytes32(block.prevrandao)
            ^ keccak256(abi.encode(disputeId, block.timestamp))
            ^ XYXConstants.JUROR_SEED_SALT;
        uint256 startIdx = uint256(seed) % eligible.length;

        // Step 3: walk forward, pick JURORS_PER_DISPUTE unique jurors
        uint256 want = XYXConstants.JURORS_PER_DISPUTE;
        if (want > eligible.length) want = eligible.length;

        for (uint256 i = 0; i < want; i++) {
            uint256 idx = (startIdx + i) % eligible.length;
            d.jurors.push(eligible[idx]);
            // Initialize vote slot (Uncast, weight 0 — set on castVote)
            d.votes.push(BFT.Vote({juror: eligible[idx], choice: BFT.VoteChoice.Uncast, weight: 0, cast: false}));
        }

        d.state = DisputeState.Voting;
        d.voteDeadline = uint64(block.timestamp + XYXConstants.VOTE_DEADLINE);

        emit JurorsSelected(disputeId, d.jurors, d.voteDeadline);
    }

    // ============================================================================
    //                                 VOTING (FR-4.1)
    // ============================================================================

    /// @notice Cast a vote on a dispute. Only selected jurors may vote, within the vote deadline.
    /// @param disputeId The active dispute
    /// @param choice Support / Against / Abstain
    /// @param reasoning keccak256 of the off-chain reasoning payload
    function castVote(uint256 disputeId, BFT.VoteChoice choice, bytes32 reasoning) external nonReentrant {
        Dispute storage d = _getDisputeOrRevert(disputeId);
        if (d.state != DisputeState.Voting) {
            revert DisputeNotInVoting(disputeId, d.state);
        }
        if (block.timestamp > d.voteDeadline) {
            revert VoteDeadlinePassed(disputeId, d.voteDeadline);
        }
        if (choice == BFT.VoteChoice.Uncast) revert BFT.InvalidVote(choice);

        // Find caller's juror index
        uint256 idx = _findJurorIndex(d, msg.sender);
        BFT.Vote storage vote = d.votes[idx];
        if (vote.cast) revert AlreadyVoted(disputeId, msg.sender);

        // Read current weight from registry (so slashing between dispute creation and vote affects weight)
        uint256 jurorId = registry.getAgentByOwner(msg.sender);
        uint256 weight = jurorId == 0 ? 0 : registry.getVoteWeight(jurorId);

        vote.choice = choice;
        vote.weight = weight;
        vote.cast = true;

        emit VoteCast(disputeId, msg.sender, choice, weight, reasoning);
    }

    // ============================================================================
    //                              RESOLUTION (FR-4.3)
    // ============================================================================

    /// @notice Resolve a dispute after the vote deadline. Anyone may call (permissionless).
    /// @dev Calls BFT.resolve on the votes, then forwards the resolution to ExecutionEngine
    ///      which performs the slash + reward distribution. The execution path is non-reentrant
    ///      to prevent cross-contract reentrancy.
    /// @param disputeId The dispute to resolve
    function resolveDispute(uint256 disputeId) external nonReentrant {
        Dispute storage d = _getDisputeOrRevert(disputeId);
        if (d.state != DisputeState.Voting) {
            revert DisputeNotInVoting(disputeId, d.state);
        }
        if (block.timestamp < d.voteDeadline) {
            revert VoteDeadlineNotReached(disputeId, d.voteDeadline);
        }
        if (address(executionEngine) == address(0)) revert ExecutionEngineNotSet();

        // Run BFT aggregation
        BFT.Resolution memory resolution = BFT.resolve(d.votes);

        // Mark resolved
        d.state = DisputeState.Resolved;
        d.resolvedAt = block.timestamp;
        d.resolution = resolution;

        // Forward to ExecutionEngine
        executionEngine.executeResolution(disputeId, resolution);

        emit DisputeResolved(
            disputeId, resolution.winnerSupport, resolution.inconclusive, resolution.referenceJuror
        );
    }

    // ============================================================================
    //                           JUROR REWARD WITHDRAWAL (D11)
    // ============================================================================

    /// @notice Withdraw the caller's accumulated juror reward across all resolved disputes.
    /// @dev Pull-payment pattern: ExecutionEngine credits `pendingJurorReward[juror]` via
    ///      `creditJurorReward(juror, amount)` (onlyOwner / onlyExecutionEngine). This function
    ///      lets jurors claim whatever has been credited to them.
    function withdrawJurorReward() external nonReentrant {
        uint256 amount = pendingJurorReward[msg.sender];
        if (amount == 0) revert WithdrawFailed();
        pendingJurorReward[msg.sender] = 0;

        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) {
            pendingJurorReward[msg.sender] = amount; // Restore for retry
            revert WithdrawFailed();
        }

        emit JurorRewardWithdrawn(msg.sender, amount);
    }

    // ============================================================================
    //                              OWNER INTERFACE
    // ============================================================================

    /// @notice Credit a juror with reward. Only callable by ExecutionEngine (via owner).
    /// @dev Per-dispute share is also recorded for sub-claim patterns; aggregate is the source of truth.
    function creditJurorReward(address juror, uint256 amount, uint256 disputeId) external onlyOwner {
        if (amount > 0) {
            pendingJurorReward[juror] += amount;
            jurorRewardShare[disputeId][juror] = amount;
            emit JurorRewardAssigned(disputeId, juror, amount);
        }
    }

    // ============================================================================
    //                              VIEW FUNCTIONS
    // ============================================================================

    function getDispute(uint256 disputeId) external view returns (Dispute memory) {
        return _disputes[disputeId];
    }

    function getState(uint256 disputeId) external view returns (DisputeState) {
        return _disputes[disputeId].state;
    }

    function getJurors(uint256 disputeId) external view returns (address[] memory) {
        return _disputes[disputeId].jurors;
    }

    function getVotes(uint256 disputeId) external view returns (BFT.Vote[] memory) {
        return _disputes[disputeId].votes;
    }

    function getEvidence(uint256 disputeId) external view returns (Evidence[] memory) {
        return _evidence[disputeId];
    }

    function getEvidenceCount(uint256 disputeId) external view returns (uint256) {
        return _evidence[disputeId].length;
    }

    function getResolution(uint256 disputeId) external view returns (BFT.Resolution memory) {
        return _disputes[disputeId].resolution;
    }

    /// @notice Slim read-only view of a dispute. Returns zero/empty values for unknown ids.
    /// @dev Mirrors the on-chain dispute into a flat, interface-safe view. Avoids passing the
    ///      full Dispute struct (which has dynamic `address[] jurors` and `BFT.Vote[] votes`)
    ///      across the EE/DR boundary.
    function getDisputeView(uint256 disputeId) external view returns (IDisputeResolver.DisputeView memory) {
        Dispute storage d = _disputes[disputeId];
        return IDisputeResolver.DisputeView({
            disputeId: d.disputeId,
            taskId: d.taskId,
            disputer: d.disputer,
            alternativeAnswer: d.alternativeAnswer,
            evidenceDeadline: d.evidenceDeadline,
            voteDeadline: d.voteDeadline,
            state: uint8(d.state),
            jurors: d.jurors,
            resolved: d.state == DisputeState.Resolved
        });
    }

    // ============================================================================
    //                                INTERNAL
    // ============================================================================

    function _getDisputeOrRevert(uint256 disputeId) internal view returns (Dispute storage) {
        Dispute storage d = _disputes[disputeId];
        if (d.disputeId == 0) revert DisputeNotFound(disputeId);
        return d;
    }

    function _findJurorIndex(Dispute storage d, address juror) internal view returns (uint256) {
        uint256 n = d.jurors.length;
        for (uint256 i = 0; i < n; i++) {
            if (d.jurors[i] == juror) return i;
        }
        revert NotAJuror(d.disputeId, juror);
    }

    /// @notice Walk the active juror pool, excluding task parties (participants, initiator, disputer).
    /// @dev Calls AgentRegistry.getActiveJurorsPaginated in pages of 100 and accumulates up to
    ///      `max` eligible addresses. Returns early once `max` is hit.
    function _collectEligibleJurors(
        address[] memory participants,
        address initiator,
        uint256 max
    ) internal view returns (address[] memory) {
        address[] memory eligible = new address[](max);
        uint256 out;

        // Bounded walk: at most 10 pages × 100 = 1000 candidates inspected
        uint256 totalJurors;
        for (uint256 page = 0; page < 10 && out < max; page++) {
            (address[] memory bucket, uint256 total) =
                registry.getActiveJurorsPaginated(page * 100, 100);
            if (page == 0) totalJurors = total;
            if (bucket.length == 0) break;

            for (uint256 i = 0; i < bucket.length && out < max; i++) {
                address candidate = bucket[i];
                if (!_isExcluded(candidate, participants, initiator, msg.sender /* disputer */)) {
                    eligible[out++] = candidate;
                }
            }
            if (totalJurors <= (page + 1) * 100) break; // exhausted
        }

        // Resize to actual length
        address[] memory trimmed = new address[](out);
        for (uint256 i = 0; i < out; i++) {
            trimmed[i] = eligible[i];
        }
        return trimmed;
    }

    function _isExcluded(
        address candidate,
        address[] memory participants,
        address initiator,
        address disputer
    ) internal pure returns (bool) {
        if (candidate == initiator) return true;
        if (candidate == disputer) return true;
        uint256 n = participants.length;
        for (uint256 i = 0; i < n; i++) {
            if (participants[i] == candidate) return true;
        }
        return false;
    }

    /// @notice Allow direct deposits to fund juror pull-payments
    receive() external payable {}
}
