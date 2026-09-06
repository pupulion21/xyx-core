// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentRegistry
/// @notice Minimal interface for AgentRegistry, used by TaskLifecycle, DisputeResolver, and ExecutionEngine
/// @dev We expose only the functions orchestrator contracts need. The concrete `AgentRegistry.AgentCard`
///      has dynamic fields (bytes32[] capabilities, nested ReputationLib.State) that are expensive to
///      return across interfaces. Callers should query scalar fields via getReputation/getVoteWeight/etc.
interface IAgentRegistry {
    /// @notice Role enum mirror (must match AgentRegistry.Role)
    enum Role {
        None,
        Agent,
        Juror
    }

    // ============================================================================
    //                              OWNER INTERFACE
    // ============================================================================

    /// @notice Slash a percentage of agent's stake. Only callable by owner (ExecutionEngine).
    /// @return slashAmount Amount actually slashed (wei)
    function slash(uint256 agentId, uint256 percentBps) external returns (uint256 slashAmount);

    /// @notice Slash a percentage of agent's stake AND forward the slashed ETH to a recipient.
    /// @dev Used by ExecutionEngine for distribution: slashes the loser's stake and immediately
    ///      sends the ETH to a recipient address in the same transaction.
    /// @return slashAmount Amount actually slashed and forwarded
    function slashAndForward(uint256 agentId, uint256 percentBps, address payable recipient)
        external
        returns (uint256 slashAmount);

    /// @notice Update agent reputation. Only callable by owner (ExecutionEngine).
    /// @param success true = task success / dispute won, false = task failed / dispute lost
    /// @param isDispute true = dispute context, false = task context
    function updateReputation(uint256 agentId, bool success, bool isDispute) external;

    /// @notice Apply final strike (e.g., unregister during task). Only callable by owner.
    function applyFinalStrike(uint256 agentId) external;

    // ============================================================================
    //                              VIEW INTERFACE
    // ============================================================================

    /// @notice Get the owner of an agent (or address(0) if not registered)
    function ownerOf(uint256 agentId) external view returns (address);

    /// @notice Get current stake (in wei) of an agent
    function stakeOf(uint256 agentId) external view returns (uint256);

    /// @notice Get role of an agent
    function roleOf(uint256 agentId) external view returns (Role);

    /// @notice Check if agent is currently active
    function isActive(uint256 agentId) external view returns (bool);

    function getAgentByOwner(address owner) external view returns (uint256);
    function getReputation(uint256 agentId) external view returns (uint256);
    function getVoteWeight(uint256 agentId) external view returns (uint256);

    /// @notice Find agents by capability, paginated.
    function findAgentsByCapabilityPaginated(
        bytes32 capability,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory agents_, uint256 total);

    /// @notice Paginated list of active jurors (for dispute panel selection).
    /// @dev Walks agentId space, skipping non-jurors, inactive agents, or address(0) owners.
    ///      O(n) but bounded by nextAgentId. Fine for sub-10k registries.
    function getActiveJurorsPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory jurors_, uint256 total);

    function nextAgentId() external view returns (uint256);
    function treasuryBalance() external view returns (uint256);

    // ============================================================================
    //                          SESSION KEY DELEGATION
    // ============================================================================

    /// @notice Get the session key for an agent (returns address(0) if none)
    function getSessionKey(uint256 agentId)
        external
        view
        returns (address key, uint64 validUntil, bool active);

    /// @notice Reverse lookup: which agentId owns this session key (0 if none)
    function sessionKeyToAgentId(address key) external view returns (uint256 agentId);
}
