// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BFT} from "../libraries/BFT.sol";

/// @title IDisputeResolver
/// @notice Minimal interface for DisputeResolver used by ExecutionEngine.
/// @dev Decouples EE from concrete DisputeResolver. The full Dispute struct contains dynamic
///      arrays (jurors[], votes[]) so we expose only what EE needs.
interface IDisputeResolver {
    struct DisputeView {
        uint256 disputeId;
        uint256 taskId;
        address disputer;
        bytes32 alternativeAnswer;
        uint64 evidenceDeadline;
        uint64 voteDeadline;
        uint8 state; // DisputeResolver.DisputeState (None=0..Resolved=3)
        address[] jurors;
        bool resolved;
    }

    /// @notice Slim read-only view of a dispute. Returns zero/empty values for unknown ids.
    function getDisputeView(uint256 disputeId) external view returns (DisputeView memory);

    /// @notice Credit a juror with a reward share. Only callable by ExecutionEngine (owner).
    function creditJurorReward(address juror, uint256 amount, uint256 disputeId) external;
}
