// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IExecutionEngine} from "../../src/interfaces/IExecutionEngine.sol";
import {IDisputeResolver} from "../../src/interfaces/IDisputeResolver.sol";
import {BFT} from "../../src/libraries/BFT.sol";

/// @title MockExecutionEngine
/// @notice Minimal stand-in for ExecutionEngine used in DisputeResolver unit tests.
/// @dev Implements IExecutionEngine by:
///      - `notifyDisputeCreated` — calls TaskLifecycle.markDisputed on the underlying lifecycle.
///        Forwards the dispute fee (msg.value) to a hard-coded treasury address (or absorbs it).
///      - `executeResolution` — records the (disputeId, resolution) tuple and emits an event.
///        Does NOT perform slashing or distribution; that lives in the real ExecutionEngine.
///      Tests should set `treasury` to a known address to verify fee accounting.
contract MockExecutionEngine is IExecutionEngine {
    address public immutable taskLifecycleAddr;
    address public treasury;
    address public disputeResolverAddr;

    struct RecordedResolution {
        uint256 disputeId;
        BFT.Resolution resolution;
        uint256 timestamp;
    }

    RecordedResolution[] public resolutions;
    uint256[] public notifiedDisputes; // disputeIds passed to notifyDisputeCreated
    // Stored dispute views for getDisputeView to return
    mapping(uint256 => IDisputeResolver.DisputeView) internal _views;

    event MockDisputeNotified(uint256 indexed taskId, uint256 indexed disputeId, uint256 fee);
    event MockResolutionRecorded(
        uint256 indexed disputeId,
        bool winnerSupport,
        bool inconclusive,
        address referenceJuror
    );
    event MockTreasuryUpdated(address indexed treasury);

    error NotDisputeResolver();
    error MarkDisputedFailed();

    modifier onlyDisputeResolver() {
        if (msg.sender != disputeResolverAddr) revert NotDisputeResolver();
        _;
    }

    constructor(address _taskLifecycle, address _treasury) {
        taskLifecycleAddr = _taskLifecycle;
        treasury = _treasury;
    }

    function setDisputeResolver(address _disputeResolver) external {
        disputeResolverAddr = _disputeResolver;
    }

    function setTreasury(address _treasury) external {
        treasury = _treasury;
        emit MockTreasuryUpdated(_treasury);
    }

    /// @notice Test helper: pre-populate a dispute view so getDisputeView returns non-zero.
    function setDisputeView(uint256 disputeId, IDisputeResolver.DisputeView memory v) external {
        _views[disputeId] = v;
    }

    function notifyDisputeCreated(uint256 taskId, uint256 disputeId) external payable override {
        if (msg.sender != disputeResolverAddr) revert NotDisputeResolver();

        // Call TaskLifecycle.markDisputed (TaskLifecycle is owned by this mock — we own it via setTaskLifecycleOwner)
        (bool success, bytes memory data) =
            taskLifecycleAddr.call(abi.encodeWithSignature("markDisputed(uint256,uint256)", taskId, disputeId));
        if (!success) {
            if (data.length > 0) {
                assembly {
                    let returndata_size := mload(data)
                    revert(add(32, data), returndata_size)
                }
            } else {
                revert MarkDisputedFailed();
            }
        }

        // Forward the fee to the treasury
        if (msg.value > 0) {
            (bool paid,) = payable(treasury).call{value: msg.value}("");
            require(paid, "treasury payment failed");
        }

        notifiedDisputes.push(disputeId);
        emit MockDisputeNotified(taskId, disputeId, msg.value);
    }

    function executeResolution(uint256 disputeId, BFT.Resolution memory resolution) external override {
        if (msg.sender != disputeResolverAddr) revert NotDisputeResolver();
        resolutions.push(RecordedResolution({disputeId: disputeId, resolution: resolution, timestamp: block.timestamp}));
        emit MockResolutionRecorded(disputeId, resolution.winnerSupport, resolution.inconclusive, resolution.referenceJuror);
    }

    function getResolutionCount() external view returns (uint256) {
        return resolutions.length;
    }

    function getResolution(uint256 idx) external view returns (RecordedResolution memory) {
        return resolutions[idx];
    }

    function getNotifiedDisputeCount() external view returns (uint256) {
        return notifiedDisputes.length;
    }

    /// @notice Returns the pre-set view, or a zero view if not set.
    function getDisputeView(uint256 disputeId) external view returns (IDisputeResolver.DisputeView memory) {
        return _views[disputeId];
    }
}
