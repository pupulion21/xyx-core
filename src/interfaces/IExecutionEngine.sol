// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BFT} from "../libraries/BFT.sol";

/// @title IExecutionEngine
/// @notice Minimal interface for ExecutionEngine used by DisputeResolver.
/// @dev Decouples DisputeResolver from concrete ExecutionEngine. The two contracts have a circular
///      relationship: DisputeResolver calls ExecutionEngine for dispute lifecycle events
///      (notification on creation, resolution execution). Both contracts are owned by the same
///      deployer and wired at construction time.
interface IExecutionEngine {
    /// @notice Notify ExecutionEngine that a new dispute was triggered.
    /// @dev Called by DisputeResolver after creating a dispute record. ExecutionEngine is
    ///      responsible for moving the underlying task to the `Disputed` state via TaskLifecycle.
    ///      Receives the dispute fee forwarded from DisputeResolver.
    /// @param taskId The disputed task
    /// @param disputeId The new dispute ID
    function notifyDisputeCreated(uint256 taskId, uint256 disputeId) external payable;

    /// @notice Execute a BFT resolution (slash + reward distribution).
    /// @dev Called by DisputeResolver after voting closes. ExecutionEngine is the only contract
    ///      permitted to slash and update reputation. It must:
    ///      - Slash the losing party (agent on `winnerSupport=true`, disputer on `winnerSupport=false`)
    ///      - Distribute slash pool: 60% to honest jurors, 30% to winner, 10% to treasury
    ///      - Slash outlier jurors at JUROR_OUTLIER_SLASH_BPS
    ///      - Update reputations (lose for outliers, +1 for honest jurors, +/-10 for task participants)
    ///      - On `inconclusive`, do nothing
    /// @param disputeId The resolved dispute
    /// @param resolution The BFT resolution (winner, outliers, weights)
    function executeResolution(uint256 disputeId, BFT.Resolution memory resolution) external;
}
