// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {XYXConstants} from "../libraries/XYXConstants.sol";
import {ReputationLib} from "../libraries/ReputationLib.sol";

/// @title AgentRegistry
/// @notice Registry for AI agents and jurors in XYX protocol
/// @dev Compatible with ERC-8004 (Trustless Agents) standard structure.
///      Each address can register one agent. Jurors register separately.
contract AgentRegistry is ReentrancyGuard, Pausable, Ownable2Step {
    using ReputationLib for ReputationLib.State;

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ============================================================================
    //                                    TYPES
    // ============================================================================

    enum Role {
        None, // 0
        Agent, // 1
        Juror // 2
    }

    struct AgentCard {
        uint256 agentId;
        address owner;
        string endpoint; // A2A protocol endpoint
        bytes32[] capabilities; // Skill hashes (e.g., keccak256("data-analysis"))
        uint256 stake; // Current staked amount
        uint256 unstakeRequest; // 0 if none, else unlock timestamp
        uint256 unstakeAmount; // Amount pending withdrawal
        Role role;
        ReputationLib.State reputation;
        uint64 registeredAt;
        bool active;
    }

    // ============================================================================
    //                                 STORAGE
    // ============================================================================

    uint256 public nextAgentId = 1;
    uint256 public treasuryBalance;
    uint256 public pauseTimestamp; // 0 = not paused, else block.timestamp when paused

    mapping(uint256 => AgentCard) public agents;
    mapping(address => uint256) public ownerToAgentId; // owner => agentId
    mapping(uint256 => address[]) public agentCapabilities; // capability hash => agents

    // Rate limiting
    mapping(address => uint256) public lastActionDay;
    mapping(address => uint256) public dailyActionCount;

    /// @notice Session key delegation (PRD §3.3 D16)
    /// @dev An agent owner can delegate signing authority to a "hot" key (e.g., agent's
    ///      own wallet) for A2A message submission. Bounded by `validUntil` to limit
    ///      blast radius if the session key is compromised. Only one active session key
    ///      per agent at a time.
    struct SessionKey {
        address key; // session key address (e.g., agent's hot wallet)
        uint64 validUntil; // expiry timestamp (unix seconds)
        bool active;
    }
    mapping(uint256 => SessionKey) public sessionKeys; // agentId => SessionKey
    mapping(address => uint256) public sessionKeyToAgentId; // session key => agentId (reverse lookup)

    // ============================================================================
    //                                  EVENTS
    // ============================================================================

    event AgentRegistered(
        uint256 indexed agentId, address indexed owner, Role role, string endpoint, uint256 stake
    );

    event StakeAdded(uint256 indexed agentId, uint256 amount, uint256 newTotal);
    event UnstakeRequested(uint256 indexed agentId, uint256 amount, uint256 unlockAt);
    event UnstakeWithdrawn(uint256 indexed agentId, uint256 amount);
    event AgentDeactivated(uint256 indexed agentId, string reason);
    event AgentReactivated(uint256 indexed agentId);
    event EndpointUpdated(uint256 indexed agentId, string newEndpoint);
    event TreasuryWithdrawn(address indexed to, uint256 amount);
    event AutoUnpaused(uint256 unpausedAt);
    event SessionKeySet(uint256 indexed agentId, address indexed key, uint64 validUntil);
    event SessionKeyRevoked(uint256 indexed agentId, address indexed key);

    // ============================================================================
    //                                 ERRORS
    // ============================================================================

    error AlreadyRegistered(address owner);
    error InvalidEndpoint();
    error InsufficientStake(uint256 required, uint256 provided);
    error NotAgentOwner(uint256 agentId, address caller);
    error AgentNotActive(uint256 agentId);
    error NoUnstakePending(uint256 agentId);
    error UnbondingPeriodNotMet(uint256 currentTime, uint256 unlockAt);
    error EmptyCapabilities();
    error RateLimitExceeded(address user, uint256 limit);
    error EmptyStake();
    error TransferFailed();
    error InvalidSlashBps(uint256 provided, uint256 max);
    error BelowMinStakeAfterFee(uint256 stake, uint256 minRequired);
    error InvalidRole();
    error NotAgentOwnerForSessionKey(uint256 agentId, address caller);
    error InvalidSessionKeyDuration(uint256 provided, uint256 min, uint256 max);
    error ZeroSessionKey();
    error NoSessionKeyToRevoke(uint256 agentId);

    // ============================================================================
    //                              REGISTRATION
    // ============================================================================

    /// @notice Register a new agent
    /// @param endpoint A2A protocol endpoint URL
    /// @param capabilities Array of capability hashes
    function registerAgent(string calldata endpoint, bytes32[] calldata capabilities)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 agentId)
    {
        if (ownerToAgentId[msg.sender] != 0) revert AlreadyRegistered(msg.sender);
        if (bytes(endpoint).length == 0) revert InvalidEndpoint();
        if (capabilities.length == 0) revert EmptyCapabilities();
        _checkRateLimit(msg.sender, XYXConstants.MAX_REGISTRATIONS_PER_DAY);

        uint256 required = XYXConstants.MIN_AGENT_STAKE + XYXConstants.REGISTRATION_FEE;
        if (msg.value < required) revert InsufficientStake(required, msg.value);

        uint256 stake = msg.value - XYXConstants.REGISTRATION_FEE;
        if (stake < XYXConstants.MIN_AGENT_STAKE) {
            revert BelowMinStakeAfterFee(stake, XYXConstants.MIN_AGENT_STAKE);
        }

        agentId = _register(msg.sender, endpoint, capabilities, stake, Role.Agent);
        treasuryBalance += XYXConstants.REGISTRATION_FEE;
    }

    /// @notice Register a new juror (no capabilities required)
    function registerJuror(string calldata endpoint)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 agentId)
    {
        if (ownerToAgentId[msg.sender] != 0) revert AlreadyRegistered(msg.sender);
        if (bytes(endpoint).length == 0) revert InvalidEndpoint();
        _checkRateLimit(msg.sender, XYXConstants.MAX_REGISTRATIONS_PER_DAY);

        uint256 required = XYXConstants.MIN_JUROR_STAKE + XYXConstants.REGISTRATION_FEE;
        if (msg.value < required) revert InsufficientStake(required, msg.value);

        uint256 stake = msg.value - XYXConstants.REGISTRATION_FEE;
        if (stake < XYXConstants.MIN_JUROR_STAKE) {
            revert BelowMinStakeAfterFee(stake, XYXConstants.MIN_JUROR_STAKE);
        }

        bytes32[] memory emptyCaps = new bytes32[](0);
        agentId = _registerMem(msg.sender, endpoint, emptyCaps, stake, Role.Juror);
        treasuryBalance += XYXConstants.REGISTRATION_FEE;
    }

    function _register(
        address owner,
        string calldata endpoint,
        bytes32[] calldata capabilities,
        uint256 stake,
        Role role
    ) internal returns (uint256) {
        uint256 agentId = nextAgentId++;
        AgentCard storage agent = agents[agentId];
        agent.agentId = agentId;
        agent.owner = owner;
        agent.endpoint = endpoint;
        agent.capabilities = capabilities;
        agent.stake = stake;
        agent.role = role;
        agent.reputation = ReputationLib.initialize();
        agent.registeredAt = uint64(block.timestamp);
        agent.active = true;

        ownerToAgentId[owner] = agentId;

        // Index by capabilities (for agent search)
        for (uint256 i = 0; i < capabilities.length; i++) {
            agentCapabilities[uint256(capabilities[i])].push(owner);
        }

        emit AgentRegistered(agentId, owner, role, endpoint, stake);
        return agentId;
    }

    function _registerMem(
        address owner,
        string calldata endpoint,
        bytes32[] memory capabilities,
        uint256 stake,
        Role role
    ) internal returns (uint256) {
        bytes32[] memory capsMem = capabilities;
        uint256 agentId = nextAgentId++;
        AgentCard storage agent = agents[agentId];
        agent.agentId = agentId;
        agent.owner = owner;
        agent.endpoint = endpoint;
        agent.stake = stake;
        agent.role = role;
        agent.reputation = ReputationLib.initialize();
        agent.registeredAt = uint64(block.timestamp);
        agent.active = true;
        // Copy from memory to storage
        for (uint256 i = 0; i < capsMem.length; i++) {
            agent.capabilities.push(capsMem[i]);
            agentCapabilities[uint256(capsMem[i])].push(owner);
        }
        ownerToAgentId[owner] = agentId;
        emit AgentRegistered(agentId, owner, role, endpoint, stake);
        return agentId;
    }

    // ============================================================================
    //                                STAKE MANAGEMENT
    // ============================================================================

    /// @notice Add more stake to an existing agent. Reactivates agent if it was deactivated due to low stake.
    function addStake() external payable nonReentrant {
        uint256 agentId = ownerToAgentId[msg.sender];
        if (agentId == 0) revert AlreadyRegistered(address(0)); // Not registered
        if (msg.value == 0) revert EmptyStake();

        AgentCard storage agent = agents[agentId];
        agent.stake += msg.value;
        emit StakeAdded(agentId, msg.value, agent.stake);

        // Reactivate if previously deactivated due to low stake
        if (!agent.active && agent.stake >= _getMinStake(agent.role)) {
            agent.active = true;
            emit AgentReactivated(agentId);
        }
    }

    /// @notice Update the A2A endpoint URL for the calling agent
    /// @dev Empty string is rejected. Endpoint changes don't affect stake or reputation.
    function updateEndpoint(string calldata newEndpoint) external {
        uint256 agentId = ownerToAgentId[msg.sender];
        if (agentId == 0) revert AlreadyRegistered(address(0));
        if (bytes(newEndpoint).length == 0) revert InvalidEndpoint();

        agents[agentId].endpoint = newEndpoint;
        emit EndpointUpdated(agentId, newEndpoint);
    }

    /// @notice Request to unstake (7-day unbonding)
    function requestUnstake(uint256 amount) external nonReentrant {
        uint256 agentId = ownerToAgentId[msg.sender];
        if (agentId == 0) revert AlreadyRegistered(address(0));
        if (amount == 0) revert EmptyStake();

        AgentCard storage agent = agents[agentId];
        if (agent.stake < amount) revert EmptyStake();
        if (agent.unstakeAmount != 0) revert NoUnstakePending(0); // Already pending

        agent.stake -= amount;
        agent.unstakeAmount = amount;
        agent.unstakeRequest = uint64(block.timestamp + XYXConstants.UNBONDING_PERIOD);

        emit UnstakeRequested(agentId, amount, agent.unstakeRequest);
    }

    /// @notice Withdraw unstaked amount after unbonding period
    function withdrawUnstake() external nonReentrant {
        uint256 agentId = ownerToAgentId[msg.sender];
        if (agentId == 0) revert AlreadyRegistered(address(0));

        AgentCard storage agent = agents[agentId];
        if (agent.unstakeAmount == 0) revert NoUnstakePending(agentId);
        if (block.timestamp < agent.unstakeRequest) {
            revert UnbondingPeriodNotMet(block.timestamp, agent.unstakeRequest);
        }

        uint256 amount = agent.unstakeAmount;
        agent.unstakeAmount = 0;
        agent.unstakeRequest = 0;

        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed();

        // Check if agent is now below minimum
        if (agent.stake < _getMinStake(agent.role)) {
            agent.active = false;
            emit AgentDeactivated(agentId, "Stake below minimum after withdrawal");
        }

        emit UnstakeWithdrawn(agentId, amount);
    }

    // ============================================================================
    //                          SESSION KEY DELEGATION (D16)
    // ============================================================================
    //
    // An agent owner can delegate signing authority to a "hot" key (e.g., the agent's
    // own wallet running on a server). The session key can then sign A2A messages
    // on behalf of the agent without the owner signing every transaction. The
    // delegation is bounded by `validUntil` to limit blast radius if the session
    // key is compromised.

    /// @notice Set or rotate a session key for an agent
    /// @dev Only the agent owner can call this. Revokes any existing session key for
    ///      the agent (only one active at a time). Duration must be in
    ///      [MIN_SESSION_KEY_DURATION, MAX_SESSION_KEY_DURATION].
    /// @param agentId The agent delegating signing authority
    /// @param sessionKey The new session key address (cannot be address(0))
    /// @param validUntil Unix timestamp when the session key expires
    function setSessionKey(uint256 agentId, address sessionKey, uint64 validUntil) external {
        if (sessionKey == address(0)) revert ZeroSessionKey();
        if (agents[agentId].owner != msg.sender) {
            revert NotAgentOwnerForSessionKey(agentId, msg.sender);
        }

        uint256 duration;
        unchecked {
            duration = uint256(validUntil) - block.timestamp;
        }
        if (
            duration < XYXConstants.MIN_SESSION_KEY_DURATION ||
            duration > XYXConstants.MAX_SESSION_KEY_DURATION
        ) {
            revert InvalidSessionKeyDuration(
                duration, XYXConstants.MIN_SESSION_KEY_DURATION, XYXConstants.MAX_SESSION_KEY_DURATION
            );
        }

        // Revoke any existing session key (only one active per agent)
        address oldKey = sessionKeys[agentId].key;
        if (oldKey != address(0)) {
            delete sessionKeyToAgentId[oldKey];
        }

        sessionKeys[agentId] = SessionKey({key: sessionKey, validUntil: validUntil, active: true});
        sessionKeyToAgentId[sessionKey] = agentId;

        emit SessionKeySet(agentId, sessionKey, validUntil);
    }

    /// @notice Revoke a session key before its expiry
    /// @dev Only the agent owner can call this. No-op-safe (reverts if no session key exists).
    function revokeSessionKey(uint256 agentId) external {
        if (agents[agentId].owner != msg.sender) {
            revert NotAgentOwnerForSessionKey(agentId, msg.sender);
        }
        address key = sessionKeys[agentId].key;
        if (key == address(0)) revert NoSessionKeyToRevoke(agentId);

        delete sessionKeys[agentId];
        delete sessionKeyToAgentId[key];

        emit SessionKeyRevoked(agentId, key);
    }

    /// @notice Get session key for an agent (named getter for explicit return shape)
    /// @dev Auto-generated getter for the public `sessionKeys` mapping has a different
    ///      signature, so we expose a clean named view that matches IAgentRegistry.
    function getSessionKey(uint256 agentId)
        external
        view
        returns (address key, uint64 validUntil, bool active)
    {
        SessionKey storage sk = sessionKeys[agentId];
        return (sk.key, sk.validUntil, sk.active);
    }

    // ============================================================================
    //                              REPUTATION UPDATES
    // ============================================================================

    /// @notice Update agent reputation (only callable by other core contracts)
    function updateReputation(uint256 agentId, bool success, bool isDispute) external onlyOwner {
        AgentCard storage agent = agents[agentId];
        if (agent.agentId == 0) revert AgentNotActive(agentId);

        if (isDispute) {
            if (success) agent.reputation.onDisputeWon();
            else agent.reputation.onDisputeLost();
        } else {
            if (success) agent.reputation.onTaskSuccess();
            else agent.reputation.onTaskFailed();
        }
    }

    /// @notice Apply final strike (unregister during task) — reputation -50 + agent deactivated
    function applyFinalStrike(uint256 agentId) external onlyOwner {
        AgentCard storage agent = agents[agentId];
        if (agent.agentId == 0) revert AgentNotActive(agentId);
        agent.reputation.onFinalStrike();
        if (agent.active) {
            agent.active = false;
            emit AgentDeactivated(agentId, "Final strike (unregistered during task)");
        }
    }

    // ============================================================================
    //                            SLASHING (called by ExecutionEngine)
    // ============================================================================

    /// @notice Slash a percentage of agent's stake (only by ExecutionEngine)
    /// @param agentId Agent to slash
    /// @param percentBps Percentage in basis points (e.g., 1000 = 10%, must be <= 10000)
    /// @return slashAmount Amount actually slashed
    function slash(uint256 agentId, uint256 percentBps) external onlyOwner returns (uint256 slashAmount) {
        AgentCard storage agent = agents[agentId];
        if (agent.agentId == 0) revert AgentNotActive(agentId);
        if (percentBps > XYXConstants.BPS_DENOMINATOR) {
            revert InvalidSlashBps(percentBps, XYXConstants.BPS_DENOMINATOR);
        }

        slashAmount = (agent.stake * percentBps) / XYXConstants.BPS_DENOMINATOR;
        agent.stake -= slashAmount;
        treasuryBalance += slashAmount;

        // Deactivate if below minimum
        if (agent.stake < _getMinStake(agent.role)) {
            agent.active = false;
            emit AgentDeactivated(agentId, "Stake below minimum after slash");
        }

        return slashAmount;
    }

    /// @notice Slash a percentage of agent's stake AND forward the slashed ETH to a recipient.
    /// @dev Used by ExecutionEngine when distributing the slash pool: slash the loser's stake,
    ///      then immediately forward to EE so it can split 60/30/10 to jurors/winner/treasury.
    ///      Critical: must be called in the same tx as the recipient payout (no double-call possible
    ///      because we don't credit any internal balance).
    /// @param agentId Agent to slash
    /// @param percentBps Percentage in basis points
    /// @param recipient Address to receive the slashed ETH
    /// @return slashAmount Amount actually slashed and forwarded
    function slashAndForward(uint256 agentId, uint256 percentBps, address payable recipient)
        external
        onlyOwner
        returns (uint256 slashAmount)
    {
        AgentCard storage agent = agents[agentId];
        if (agent.agentId == 0) revert AgentNotActive(agentId);
        if (percentBps > XYXConstants.BPS_DENOMINATOR) {
            revert InvalidSlashBps(percentBps, XYXConstants.BPS_DENOMINATOR);
        }
        if (recipient == address(0)) revert TransferFailed();

        slashAmount = (agent.stake * percentBps) / XYXConstants.BPS_DENOMINATOR;
        agent.stake -= slashAmount;
        treasuryBalance += slashAmount;

        // Deactivate if below minimum
        if (agent.stake < _getMinStake(agent.role)) {
            agent.active = false;
            emit AgentDeactivated(agentId, "Stake below minimum after slash");
        }

        // Forward to recipient (must succeed for the slash to count as distributed)
        (bool success,) = recipient.call{value: slashAmount}("");
        if (!success) revert TransferFailed();

        return slashAmount;
    }

    // ============================================================================
    //                              VIEW FUNCTIONS
    // ============================================================================

    function getAgent(uint256 agentId) external view returns (AgentCard memory) {
        return agents[agentId];
    }

    function getAgentByOwner(address owner) external view returns (uint256) {
        return ownerToAgentId[owner];
    }

    // IAgentRegistry-compatible scalar views (cheaper than full struct return)

    function ownerOf(uint256 agentId) external view returns (address) {
        return agents[agentId].owner;
    }

    function stakeOf(uint256 agentId) external view returns (uint256) {
        return agents[agentId].stake;
    }

    function roleOf(uint256 agentId) external view returns (Role) {
        return agents[agentId].role;
    }

    function isActive(uint256 agentId) external view returns (bool) {
        return agents[agentId].active;
    }

    function getReputation(uint256 agentId) external view returns (uint256) {
        ReputationLib.State storage repState = agents[agentId].reputation;
        return ReputationLib.applyDecay(repState.score, repState.lastActivity);
    }

    function getTier(uint256 agentId) external view returns (ReputationLib.Tier) {
        ReputationLib.State storage repState = agents[agentId].reputation;
        uint256 decayed = ReputationLib.applyDecay(repState.score, repState.lastActivity);
        return ReputationLib.getTier(decayed);
    }

    function getVoteWeight(uint256 agentId) external view returns (uint256) {
        AgentCard storage agent = agents[agentId];
        uint256 decayed = ReputationLib.applyDecay(agent.reputation.score, agent.reputation.lastActivity);
        ReputationLib.Tier tier = ReputationLib.getTier(decayed);
        uint256 multiplier = ReputationLib.getMultiplier(tier);
        return (agent.stake * multiplier) / 100;
    }

    function findAgentsByCapability(bytes32 capability) external view returns (address[] memory) {
        return agentCapabilities[uint256(capability)];
    }

    /// @notice Paginated version to avoid OOG on capabilities with thousands of agents
    /// @param capability Capability hash
    /// @param offset Starting index in the capability bucket
    /// @param limit Maximum number of agents to return (capped at 100)
    /// @return agents_ Slice of agents with this capability
    /// @return total Total number of agents with this capability
    function findAgentsByCapabilityPaginated(bytes32 capability, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory agents_, uint256 total)
    {
        address[] storage bucket = agentCapabilities[uint256(capability)];
        total = bucket.length;
        if (limit > 100) limit = 100; // Cap to prevent OOG
        if (offset >= total) {
            return (new address[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        agents_ = new address[](end - offset);
        for (uint256 i = 0; i < agents_.length; i++) {
            agents_[i] = bucket[offset + i];
        }
    }

    /// @notice Paginated list of active jurors (for dispute panel selection).
    /// @dev Walks 1..nextAgentId-1 collecting agents that are: registered (agentId != 0),
    ///      role == Juror, and active. Skips deactivated or non-juror entries.
    ///      Note: agentId == 0 is the sentinel for "not registered" (we use 1-based ids).
    function getActiveJurorsPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory jurors_, uint256 total)
    {
        if (limit > 100) limit = 100;

        // First pass: count (O(n) but read-only)
        uint256 next = nextAgentId;
        uint256 count;
        for (uint256 i = 1; i < next; i++) {
            AgentCard storage a = agents[i];
            if (a.role == Role.Juror && a.active && a.owner != address(0)) {
                count++;
            }
        }
        total = count;

        if (offset >= count) {
            return (new address[](0), count);
        }

        // Second pass: collect the slice
        uint256 end = offset + limit;
        if (end > count) end = count;
        jurors_ = new address[](end - offset);

        uint256 seen;
        uint256 out;
        for (uint256 i = 1; i < next && out < jurors_.length; i++) {
            AgentCard storage a = agents[i];
            if (a.role == Role.Juror && a.active && a.owner != address(0)) {
                if (seen >= offset && seen < end) {
                    jurors_[out++] = a.owner;
                }
                seen++;
            }
        }
    }

    // ============================================================================
    //                                INTERNAL
    // ============================================================================

    function _getMinStake(Role role) internal pure returns (uint256) {
        if (role == Role.Juror) return XYXConstants.MIN_JUROR_STAKE;
        if (role == Role.Agent) return XYXConstants.MIN_AGENT_STAKE;
        // Role.None should never reach here — callers must guard with `agentId != 0`
        revert InvalidRole();
    }

    function _checkRateLimit(address user, uint256 limit) internal {
        uint256 today = block.timestamp / 1 days;
        if (lastActionDay[user] == today) {
            if (dailyActionCount[user] >= limit) revert RateLimitExceeded(user, limit);
            dailyActionCount[user]++;
        } else {
            lastActionDay[user] = today;
            dailyActionCount[user] = 1;
        }
    }

    // ============================================================================
    //                              ADMIN
    // ============================================================================

    function withdrawTreasury(address to) external onlyOwner {
        uint256 amount = treasuryBalance;
        treasuryBalance = 0;
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert TransferFailed();
        emit TreasuryWithdrawn(to, amount);
    }

    function pause() external onlyOwner {
        _pause();
        pauseTimestamp = block.timestamp;
    }

    /// @notice Unpause. Auto-unpause if PAUSE_DURATION_MAX has elapsed since pause.
    function unpause() external {
        if (paused() && pauseTimestamp != 0 &&
            block.timestamp >= pauseTimestamp + XYXConstants.PAUSE_DURATION_MAX) {
            _unpause();
            pauseTimestamp = 0;
            emit AutoUnpaused(block.timestamp);
        } else {
            // Manual unpause requires owner
            _checkOwner();
            _unpause();
            pauseTimestamp = 0;
        }
    }

    /// @notice Check if auto-unpause is due (anyone can call to trigger)
    function tryAutoUnpause() external {
        if (paused() && pauseTimestamp != 0 &&
            block.timestamp >= pauseTimestamp + XYXConstants.PAUSE_DURATION_MAX) {
            _unpause();
            pauseTimestamp = 0;
            emit AutoUnpaused(block.timestamp);
        }
    }
}
