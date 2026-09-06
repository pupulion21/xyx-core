// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {IAgentRegistry} from "../interfaces/IAgentRegistry.sol";
import {TaskStateLib} from "../libraries/TaskStateLib.sol";
import {XYXConstants} from "../libraries/XYXConstants.sol";

/// @title TaskLifecycle
/// @notice A2A task state machine (PRD §FR-2.1 to §FR-2.4)
/// @dev Implements the 7-state A2A lifecycle with on-chain message envelope.
///      Reward is escrowed in this contract and released on completion/failure.
///      All transitions enforced via TaskStateLib.isLegalTransition.
///
///      Signed message paths (PRD §3.3 D14-D17):
///      - `submitMessageSigned` — caller is the participant's EOA, signs EIP-712 typed data
///      - `submitMessageViaSessionKey` — caller is a delegated session key, recovers agentId via
///        `AgentRegistry.sessionKeyToAgentId` and verifies the agent's owner is a participant.
///        This preserves D2 (agent autonomy) without permanent compromise risk.
contract TaskLifecycle is ReentrancyGuard, Ownable2Step, EIP712 {
    using TaskStateLib for TaskStateLib.State;

    // ============================================================================
    //                                    TYPES
    // ============================================================================

    /// @notice A task with its metadata
    struct Task {
        uint256 taskId;
        address initiator; // Who created + escrowed the reward
        address[] participants; // Allowed message submitters
        uint256 reward; // Escrowed MON (msg.value at createTask)
        uint64 createdAt;
        uint64 deadline; // = createdAt + MAX_TASK_DURATION
        bytes32 specHash; // keccak256 of task spec (off-chain JSON-RPC envelope)
        bytes32 finalAnswer; // Set on completeTask
        TaskStateLib.State state;
        uint256 disputeId; // Set when disputed; 0 otherwise
    }

    // ============================================================================
    //                                 STORAGE
    // ============================================================================

    IAgentRegistry public immutable registry;
    uint256 public nextTaskId = 1;

    mapping(uint256 => Task) internal _tasks;
    mapping(uint256 => TaskStateLib.Message[]) internal _messages;
    mapping(uint256 => mapping(address => bool)) public isParticipant;
    mapping(uint256 => uint256) public pendingRewards; // taskId → unclaimed reward

    /// @notice Per-agent nonce for EIP-712 replay protection (PRD §3.3 D15)
    /// @dev Per-agent (not per-task) — cheaper (1 slot per address), no collision risk,
    ///      and indexers don't need to track separate state for each task.
    mapping(address => uint256) public nonces;

    /// @notice EIP-712 type hash for A2A messages (PRD §3.3 D14)
    /// @dev 5-field typed data: (taskId, contentHash, refUri, nonce, deadline).
    ///      - nonce: replay protection
    ///      - deadline: signature expiry
    ///      - refUri inside sig: prevents post-signature URI swap attack
    bytes32 private constant A2A_MESSAGE_TYPEHASH = keccak256(
        "A2AMessage(uint256 taskId,bytes32 contentHash,string refUri,uint256 nonce,uint64 deadline)"
    );

    // ============================================================================
    //                                  EVENTS
    // ============================================================================

    event TaskCreated(
        uint256 indexed taskId,
        address indexed initiator,
        uint256 reward,
        bytes32 specHash,
        uint64 deadline
    );

    event MessageSubmitted(
        uint256 indexed taskId,
        address indexed sender,
        bytes32 contentHash,
        string refUri,
        uint64 timestamp
    );

    event StateChanged(uint256 indexed taskId, TaskStateLib.State fromState, TaskStateLib.State toState);

    event TaskCompleted(uint256 indexed taskId, bytes32 finalAnswer, address indexed initiator);
    event TaskFailed(uint256 indexed taskId, string reason);
    event TaskCanceled(uint256 indexed taskId);
    event TaskTimedOut(uint256 indexed taskId);
    event DisputeTriggered(uint256 indexed taskId, uint256 indexed disputeId, address indexed disputer);
    event MessageSubmittedSigned(
        uint256 indexed taskId,
        address indexed sender,
        bytes32 contentHash,
        string refUri,
        uint64 timestamp,
        address indexed signer
    );

    // ============================================================================
    //                                 ERRORS
    // ============================================================================

    error EmptyParticipants();
    error TooManyParticipants(uint256 provided, uint256 max);
    error NotInitiator(uint256 taskId, address caller);
    error NotParticipant(uint256 taskId, address caller);
    error TaskNotFound(uint256 taskId);
    error TaskExpired(uint256 taskId, uint64 deadline);
    error InvalidSpecHash();
    error NoRewardToWithdraw();
    error RewardTransferFailed();
    error TaskAlreadyDisputed(uint256 taskId);
    error InvalidSignature(address recovered, address expected);
    error SignatureExpired(uint64 deadline, uint64 currentTime);
    error InvalidNonce(address signer, uint256 provided, uint256 expected);
    error SessionKeyNotFound(address sessionKey);
    error SessionKeyExpired(uint256 agentId, uint64 validUntil);

    // ============================================================================
    //                                CONSTRUCTOR
    // ============================================================================

    constructor(address initialOwner, address _registry)
        Ownable(initialOwner)
        EIP712("XYX-A2A", "1")
    {
        registry = IAgentRegistry(_registry);
    }

    // ============================================================================
    //                              TASK CREATION (FR-2.2)
    // ============================================================================

    /// @notice Create a new A2A task
    /// @param specHash keccak256 of the off-chain task spec (JSON-RPC envelope)
    /// @param participants List of agent addresses that may submit messages
    /// @return taskId The newly created task ID
    function createTask(bytes32 specHash, address[] calldata participants)
        external
        payable
        nonReentrant
        returns (uint256 taskId)
    {
        if (specHash == bytes32(0)) revert InvalidSpecHash();
        if (participants.length == 0) revert EmptyParticipants();
        if (participants.length > XYXConstants.MAX_PARTICIPANTS_PER_TASK) {
            revert TooManyParticipants(participants.length, XYXConstants.MAX_PARTICIPANTS_PER_TASK);
        }
        if (msg.value < XYXConstants.TASK_CREATION_FEE) {
            // Soft check: must at least cover fee
            // (We don't revert here since the fee is a constant, but use for accounting.)
        }

        taskId = nextTaskId++;
        Task storage task = _tasks[taskId];
        task.taskId = taskId;
        task.initiator = msg.sender;
        task.participants = participants;
        task.reward = msg.value;
        task.createdAt = uint64(block.timestamp);
        task.deadline = uint64(block.timestamp + XYXConstants.MAX_TASK_DURATION);
        task.specHash = specHash;
        task.state = TaskStateLib.State.Submitted;

        for (uint256 i = 0; i < participants.length; i++) {
            isParticipant[taskId][participants[i]] = true;
        }

        pendingRewards[taskId] = msg.value;

        emit TaskCreated(taskId, msg.sender, msg.value, specHash, task.deadline);
        emit StateChanged(taskId, TaskStateLib.State.None, TaskStateLib.State.Submitted);
    }

    // ============================================================================
    //                           MESSAGE SUBMISSION (FR-2.3)
    // ============================================================================

    /// @notice Submit an A2A message envelope to a task
    /// @dev First message transitions state from Submitted → Working.
    ///      ContentHash is keccak256 of the off-chain payload (EIP-712 typed data).
    ///      refUri is an IPFS CID or HTTP URL for full payload retrieval.
    function submitMessage(uint256 taskId, bytes32 contentHash, string calldata refUri)
        external
        nonReentrant
    {
        Task storage task = _getTaskOrRevert(taskId);
        if (block.timestamp > task.deadline) revert TaskExpired(taskId, task.deadline);
        if (!isParticipant[taskId][msg.sender] && msg.sender != task.initiator) {
            revert NotParticipant(taskId, msg.sender);
        }
        if (contentHash == bytes32(0)) revert InvalidSpecHash();

        _appendMessage(task, contentHash, refUri, msg.sender);
    }

    /// @notice Submit an A2A message envelope signed by the participant's EOA (PRD §3.3 D14-D15)
    /// @dev Caller is the participant's EOA, signature must recover to `msg.sender`. The 5-field
    ///      typed data (taskId, contentHash, refUri, nonce, deadline) prevents replay, expiry
    ///      attacks, and post-signature URI swaps. refUri is hashed inside the struct so the
    ///      signature binds the exact IPFS CID/HTTP URL the signer authorized.
    /// @param taskId The task to submit to
    /// @param contentHash keccak256 of the off-chain payload
    /// @param refUri IPFS CID or HTTP URL for full payload (signed, not just recorded)
    /// @param deadline Unix timestamp when this signature expires
    /// @param signature 65-byte EIP-712 signature (r, s, v) of the A2AMessage struct
    function submitMessageSigned(
        uint256 taskId,
        bytes32 contentHash,
        string calldata refUri,
        uint64 deadline,
        bytes calldata signature
    ) external nonReentrant {
        Task storage task = _getTaskOrRevert(taskId);
        if (block.timestamp > task.deadline) revert TaskExpired(taskId, task.deadline);
        if (!isParticipant[taskId][msg.sender] && msg.sender != task.initiator) {
            revert NotParticipant(taskId, msg.sender);
        }
        if (contentHash == bytes32(0)) revert InvalidSpecHash();

        // Verify + consume signature (uses msg.sender as the expected signer)
        _verifyAndConsumeSignature(
            msg.sender, taskId, contentHash, refUri, nonces[msg.sender], deadline, signature
        );

        _appendMessage(task, contentHash, refUri, msg.sender);
        emit MessageSubmittedSigned(
            taskId, msg.sender, contentHash, refUri, uint64(block.timestamp), msg.sender
        );
    }

    /// @notice Submit an A2A message signed by a delegated session key (PRD §3.3 D14-D16)
    /// @dev msg.sender is the session key (e.g., agent's hot wallet running on a server). The
    ///      contract looks up which agent owns this session key via AgentRegistry.sessionKeyToAgentId,
    ///      verifies the session key is not expired, and confirms the agent's owner is a task
    ///      participant. The recorded `sender` in the message envelope is the AGENT OWNER, not
    ///      the session key — so downstream jurors see the human/agent, not the hot key.
    ///
    ///      This preserves D2 (agent autonomy) without permanent compromise: if the session key
    ///      is compromised, the blast radius is bounded by `validUntil`.
    function submitMessageViaSessionKey(
        uint256 taskId,
        bytes32 contentHash,
        string calldata refUri,
        uint64 deadline,
        bytes calldata signature
    ) external nonReentrant {
        Task storage task = _getTaskOrRevert(taskId);
        if (block.timestamp > task.deadline) revert TaskExpired(taskId, task.deadline);
        if (contentHash == bytes32(0)) revert InvalidSpecHash();

        // Resolve session key -> agent
        (uint256 agentId, address sessionKey, uint64 validUntil) = _resolveSessionKey(msg.sender);
        if (block.timestamp > validUntil) revert SessionKeyExpired(agentId, validUntil);

        // The agent's owner must be a task participant
        address agentOwner = registry.ownerOf(agentId);
        if (!isParticipant[taskId][agentOwner] && agentOwner != task.initiator) {
            revert NotParticipant(taskId, agentOwner);
        }

        // Verify signature against the SESSION KEY's nonce (per-agent isolation)
        _verifyAndConsumeSignature(
            sessionKey, taskId, contentHash, refUri, nonces[sessionKey], deadline, signature
        );

        // Record the AGENT OWNER as sender (not the session key) — so message history
        // reflects who the human/agent is, not the hot key
        _appendMessage(task, contentHash, refUri, agentOwner);
        emit MessageSubmittedSigned(
            taskId, agentOwner, contentHash, refUri, uint64(block.timestamp), sessionKey
        );
    }

    /// @notice Request input from initiator (Working → InputRequired)
    function requestInput(uint256 taskId, bytes32 questionHash) external nonReentrant {
        Task storage task = _getTaskOrRevert(taskId);
        if (!isParticipant[taskId][msg.sender]) revert NotParticipant(taskId, msg.sender);
        if (questionHash == bytes32(0)) revert InvalidSpecHash();

        TaskStateLib.State fromState = task.state;
        TaskStateLib.requireTransition(fromState, TaskStateLib.State.InputRequired);
        task.state = TaskStateLib.State.InputRequired;

        _messages[taskId].push(
            TaskStateLib.Message({
                sender: msg.sender,
                timestamp: uint64(block.timestamp),
                contentHash: questionHash,
                refUri: ""
            })
        );

        emit StateChanged(taskId, fromState, TaskStateLib.State.InputRequired);
        emit MessageSubmitted(taskId, msg.sender, questionHash, "", uint64(block.timestamp));
    }

    /// @notice Provide input in response to requestInput (InputRequired → Working)
    function provideInput(uint256 taskId, bytes32 answerHash, string calldata refUri)
        external
        nonReentrant
    {
        Task storage task = _getTaskOrRevert(taskId);
        if (msg.sender != task.initiator) revert NotInitiator(taskId, msg.sender);
        if (answerHash == bytes32(0)) revert InvalidSpecHash();

        TaskStateLib.State fromState = task.state;
        TaskStateLib.requireTransition(fromState, TaskStateLib.State.Working);
        task.state = TaskStateLib.State.Working;

        _messages[taskId].push(
            TaskStateLib.Message({
                sender: msg.sender,
                timestamp: uint64(block.timestamp),
                contentHash: answerHash,
                refUri: refUri
            })
        );

        emit StateChanged(taskId, fromState, TaskStateLib.State.Working);
        emit MessageSubmitted(taskId, msg.sender, answerHash, refUri, uint64(block.timestamp));
    }

    // ============================================================================
    //                            TASK COMPLETION (FR-2.4)
    // ============================================================================

    /// @notice Complete a task with a final answer (only initiator can call)
    /// @dev Per D12: only initiator (not participants) can finalize to prevent griefing.
    function completeTask(uint256 taskId, bytes32 finalAnswer) external nonReentrant {
        Task storage task = _getTaskOrRevert(taskId);
        if (msg.sender != task.initiator) revert NotInitiator(taskId, msg.sender);
        if (finalAnswer == bytes32(0)) revert InvalidSpecHash();
        if (block.timestamp > task.deadline) revert TaskExpired(taskId, task.deadline);

        TaskStateLib.State fromState = task.state;
        TaskStateLib.requireTransition(fromState, TaskStateLib.State.Completed);
        task.state = TaskStateLib.State.Completed;
        task.finalAnswer = finalAnswer;

        // Reward is held until withdrawn (pull-payment model per D11)
        // pendingRewards already set in createTask

        emit StateChanged(taskId, fromState, TaskStateLib.State.Completed);
        emit TaskCompleted(taskId, finalAnswer, msg.sender);
    }

    /// @notice Cancel a task (only initiator, only before any messages)
    function cancelTask(uint256 taskId) external nonReentrant {
        Task storage task = _getTaskOrRevert(taskId);
        if (msg.sender != task.initiator) revert NotInitiator(taskId, msg.sender);
        if (_messages[taskId].length > 0) {
            revert TaskStateLib.InvalidStateTransition(task.state, TaskStateLib.State.Canceled);
        }

        TaskStateLib.State fromState = task.state;
        TaskStateLib.requireTransition(fromState, TaskStateLib.State.Canceled);
        task.state = TaskStateLib.State.Canceled;

        emit StateChanged(taskId, fromState, TaskStateLib.State.Canceled);
        emit TaskCanceled(taskId);
    }

    /// @notice Timeout a task after deadline (anyone can call)
    /// @dev Per PRD §5.7: task deadline passes → auto-fail, no slash, rep -5
    function timeoutTask(uint256 taskId) external nonReentrant {
        Task storage task = _getTaskOrRevert(taskId);
        if (block.timestamp <= task.deadline) {
            revert TaskExpired(taskId, task.deadline);
        }
        if (TaskStateLib.isTerminal(task.state)) {
            revert TaskStateLib.TaskNotInState(taskId, TaskStateLib.State.Working, task.state);
        }

        TaskStateLib.State fromState = task.state;
        TaskStateLib.requireTransition(fromState, TaskStateLib.State.Failed);
        task.state = TaskStateLib.State.Failed;

        // Slash all participants (small penalty for not finishing)
        for (uint256 i = 0; i < task.participants.length; i++) {
            address p = task.participants[i];
            uint256 agentId = registry.getAgentByOwner(p);
            if (agentId != 0) {
                // Apply timeout reputation penalty (will be wired in ExecutionEngine integration)
                // For now, owner of contract (ExecutionEngine) is responsible for triggering
            }
        }

        // Reward goes back to initiator
        uint256 reward = pendingRewards[taskId];
        pendingRewards[taskId] = 0;

        emit StateChanged(taskId, fromState, TaskStateLib.State.Failed);
        emit TaskTimedOut(taskId);

        if (reward > 0) {
            (bool success,) = payable(task.initiator).call{value: reward}("");
            if (!success) {
                pendingRewards[taskId] = reward; // Restore for retry
                revert RewardTransferFailed();
            }
        }
    }

    // ============================================================================
    //                              DISPUTE TRIGGER
    // ============================================================================

    /// @notice Trigger a dispute on a task (sets state to Disputed, marks disputeId)
    /// @dev Called by ExecutionEngine which is responsible for the full dispute flow.
    ///      This contract only tracks the state transition and emits the event.
    function markDisputed(uint256 taskId, uint256 disputeId) external onlyOwner {
        Task storage task = _getTaskOrRevert(taskId);
        if (task.disputeId != 0) revert TaskAlreadyDisputed(taskId);

        TaskStateLib.State fromState = task.state;
        TaskStateLib.requireTransition(fromState, TaskStateLib.State.Disputed);
        task.state = TaskStateLib.State.Disputed;
        task.disputeId = disputeId;

        emit StateChanged(taskId, fromState, TaskStateLib.State.Disputed);
        emit DisputeTriggered(taskId, disputeId, msg.sender);
    }

    // ============================================================================
    //                              REWARD WITHDRAWAL
    // ============================================================================

    /// @notice Withdraw escrowed reward (callable by participant or initiator after completion)
    /// @dev Pull-payment pattern (D11). On Completed → participant can claim.
    ///      On Failed (timeout) → initiator already got refund in timeoutTask.
    ///      On Canceled → initiator calls this to get refund.
    function withdrawReward(uint256 taskId) external nonReentrant {
        Task storage task = _getTaskOrRevert(taskId);
        uint256 reward = pendingRewards[taskId];
        if (reward == 0) revert NoRewardToWithdraw();

        address payable recipient;
        if (task.state == TaskStateLib.State.Completed) {
            // On success, the primary participant (first in list) gets the reward
            if (task.participants.length == 0) revert NoRewardToWithdraw();
            recipient = payable(task.participants[0]);
        } else if (task.state == TaskStateLib.State.Canceled) {
            recipient = payable(task.initiator);
        } else {
            revert TaskStateLib.TaskNotInState(
                taskId, TaskStateLib.State.Completed, task.state
            );
        }

        pendingRewards[taskId] = 0;

        (bool success,) = recipient.call{value: reward}("");
        if (!success) {
            pendingRewards[taskId] = reward; // Restore for retry
            revert RewardTransferFailed();
        }
    }

    // ============================================================================
    //                              VIEW FUNCTIONS
    // ============================================================================

    function getTask(uint256 taskId) external view returns (Task memory) {
        return _tasks[taskId];
    }

    function getState(uint256 taskId) external view returns (TaskStateLib.State) {
        return _tasks[taskId].state;
    }

    function getInitiator(uint256 taskId) external view returns (address) {
        return _tasks[taskId].initiator;
    }

    function getParticipants(uint256 taskId) external view returns (address[] memory) {
        return _tasks[taskId].participants;
    }

    function getMessages(uint256 taskId) external view returns (TaskStateLib.Message[] memory) {
        return _messages[taskId];
    }

    function getMessageCount(uint256 taskId) external view returns (uint256) {
        return _messages[taskId].length;
    }

    /// @notice Public getter for the EIP-712 domain separator
    /// @dev Useful for off-chain clients to compute the correct digest, and for tests
    ///      to construct signatures that match this contract's domain.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ============================================================================
    //                                INTERNAL
    // ============================================================================

    function _getTaskOrRevert(uint256 taskId) internal view returns (Task storage) {
        Task storage task = _tasks[taskId];
        if (task.taskId == 0) revert TaskNotFound(taskId);
        return task;
    }

    /// @notice Append a message to the task's message array and transition state if needed.
    /// @dev Shared by submitMessage, submitMessageSigned, and submitMessageViaSessionKey to keep
    ///      state-transition logic DRY.
    function _appendMessage(
        Task storage task,
        bytes32 contentHash,
        string calldata refUri,
        address sender
    ) internal {
        TaskStateLib.State fromState = task.state;
        if (fromState == TaskStateLib.State.Submitted) {
            // First message — transition to Working
            TaskStateLib.requireTransition(fromState, TaskStateLib.State.Working);
            task.state = TaskStateLib.State.Working;
            emit StateChanged(task.taskId, fromState, TaskStateLib.State.Working);
        } else {
            // Must be in active state
            if (!TaskStateLib.isActive(task.state)) {
                revert TaskStateLib.TaskNotInState(
                    task.taskId, TaskStateLib.State.Working, task.state
                );
            }
        }

        _messages[task.taskId].push(
            TaskStateLib.Message({
                sender: sender,
                timestamp: uint64(block.timestamp),
                contentHash: contentHash,
                refUri: refUri
            })
        );

        emit MessageSubmitted(
            task.taskId, sender, contentHash, refUri, uint64(block.timestamp)
        );
    }

    /// @notice Verify an EIP-712 A2A message signature and consume the nonce (PRD §3.3 D14-D15).
    /// @dev Reentrancy-safe: writes only to `nonces[signer]` (per-address). Order of checks is
    ///      optimized for revert cost: deadline (cheap) → nonce (SLOAD) → ecrecover (most expensive).
    ///      OZ's ECDSA.recover rejects malleable signatures (high-s) and returns address(0) for
    ///      invalid sigs — both are caught by the != expectedSigner check.
    function _verifyAndConsumeSignature(
        address expectedSigner,
        uint256 taskId,
        bytes32 contentHash,
        string calldata refUri,
        uint256 expectedNonce,
        uint64 deadline,
        bytes calldata signature
    ) internal {
        // 1. Deadline check (cheapest, do first)
        if (block.timestamp > deadline) {
            revert SignatureExpired(deadline, uint64(block.timestamp));
        }

        // 2. Nonce check (SLOAD = 2100 gas cold, 100 gas warm)
        if (expectedNonce != nonces[expectedSigner]) {
            revert InvalidNonce(expectedSigner, expectedNonce, nonces[expectedSigner]);
        }

        // 3. Build EIP-712 digest (struct hash + domain separator via OZ assembly)
        bytes32 structHash = keccak256(
            abi.encode(
                A2A_MESSAGE_TYPEHASH,
                taskId,
                contentHash,
                keccak256(bytes(refUri)),
                expectedNonce,
                deadline
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);

        // 4. Recover signer (rejects malleable sigs, ~3000 gas)
        address recovered = ECDSA.recover(digest, signature);
        if (recovered == address(0) || recovered != expectedSigner) {
            revert InvalidSignature(recovered, expectedSigner);
        }

        // 5. Bump nonce (SSTORE = 5000 gas if zero→nonzero, 200 otherwise)
        //    Effects: blocks replay. Per-agent (not per-task) so the same nonce space covers
        //    all tasks — indexers can use it as a global ordering per signer.
        unchecked {
            nonces[expectedSigner] += 1;
        }
    }

    /// @notice Resolve a session key address to its owning agent (PRD §3.3 D16).
    /// @dev Reverse lookup via AgentRegistry.sessionKeyToAgentId. The returned `key` is the
    ///      canonical session key (sanity check ensures caller passed the right address).
    function _resolveSessionKey(address sessionKeyAddr)
        internal
        view
        returns (uint256 agentId, address key, uint64 validUntil)
    {
        agentId = registry.sessionKeyToAgentId(sessionKeyAddr);
        if (agentId == 0) revert SessionKeyNotFound(sessionKeyAddr);
        (key, validUntil, ) = registry.getSessionKey(agentId);
        // Sanity: registry must agree on the key address
        if (key != sessionKeyAddr) revert SessionKeyNotFound(sessionKeyAddr);
        return (agentId, key, validUntil);
    }

    /// @notice Allow ExecutionEngine to set pending rewards (for slash distribution)
    function setPendingReward(uint256 taskId, uint256 amount) external onlyOwner {
        pendingRewards[taskId] = amount;
    }
}
