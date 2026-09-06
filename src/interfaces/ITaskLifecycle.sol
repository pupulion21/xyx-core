// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TaskStateLib} from "../libraries/TaskStateLib.sol";

/// @title ITaskLifecycle
/// @notice Minimal interface for TaskLifecycle used by DisputeResolver.
/// @dev Decouples DisputeResolver from concrete TaskLifecycle (which has dynamic `address[] participants`
///      and `Message[] messages` arrays in its Task struct). Callers needing full task data should
///      call TaskLifecycle.getTask(uint256) directly.
interface ITaskLifecycle {
    // ============================================================================
    //                              OWNER INTERFACE
    // ============================================================================

    /// @notice Mark a task as disputed (only callable by owner / ExecutionEngine).
    /// @dev Transitions the task state to `Disputed` and records the disputeId.
    function markDisputed(uint256 taskId, uint256 disputeId) external;

    // ============================================================================
    //                              VIEW INTERFACE
    // ============================================================================

    function getState(uint256 taskId) external view returns (TaskStateLib.State);

    function getInitiator(uint256 taskId) external view returns (address);

    function getParticipants(uint256 taskId) external view returns (address[] memory);
}
