// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TaskLifecycle} from "../src/core/TaskLifecycle.sol";
import {TaskStateLib} from "../src/libraries/TaskStateLib.sol";
import {AgentRegistry} from "../src/core/AgentRegistry.sol";
import {XYXConstants} from "../src/libraries/XYXConstants.sol";

/// @title TaskLifecycleTest
/// @notice Tests for the A2A task state machine (FR-2.1 to FR-2.4)
contract TaskLifecycleTest is Test {
    TaskLifecycle public tasks;
    AgentRegistry public registry;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA02);

    function setUp() public {
        registry = new AgentRegistry(address(this));
        tasks = new TaskLifecycle(address(this), address(registry));

        // Pre-fund agents
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);

        // Register Alice and Bob as agents, Carol as juror
        _registerAgent(alice);
        _registerAgent(bob);
    }

    function _registerAgent(address who) internal {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("data-analysis");
        vm.prank(who);
        registry.registerAgent{value: 0.1 ether + 0.001 ether}(
            string(abi.encodePacked("https://", who)), caps
        );
    }

    function _createTask(address initiator, address[] memory participants, uint256 reward)
        internal
        returns (uint256)
    {
        vm.prank(initiator);
        return tasks.createTask{value: reward}(
            keccak256("task-spec"), participants
        );
    }

    // ========================================================================
    // TaskStateLib pure functions
    // ========================================================================

    function test_stateLib_legalTransitions() public pure {
        // Submitted → Working, Canceled, Disputed
        assertTrue(TaskStateLib.isLegalTransition(
            TaskStateLib.State.Submitted, TaskStateLib.State.Working
        ));
        assertTrue(TaskStateLib.isLegalTransition(
            TaskStateLib.State.Submitted, TaskStateLib.State.Canceled
        ));
        assertTrue(TaskStateLib.isLegalTransition(
            TaskStateLib.State.Submitted, TaskStateLib.State.Disputed
        ));

        // Working → InputRequired, Completed, Failed, Disputed
        assertTrue(TaskStateLib.isLegalTransition(
            TaskStateLib.State.Working, TaskStateLib.State.InputRequired
        ));
        assertTrue(TaskStateLib.isLegalTransition(
            TaskStateLib.State.Working, TaskStateLib.State.Completed
        ));
        assertTrue(TaskStateLib.isLegalTransition(
            TaskStateLib.State.Working, TaskStateLib.State.Failed
        ));

        // InputRequired → Working, Canceled, Disputed
        assertTrue(TaskStateLib.isLegalTransition(
            TaskStateLib.State.InputRequired, TaskStateLib.State.Working
        ));

        // Illegal: Submitted → Completed (must go through Working)
        assertFalse(TaskStateLib.isLegalTransition(
            TaskStateLib.State.Submitted, TaskStateLib.State.Completed
        ));
        // Illegal: Completed → Working (terminal)
        assertFalse(TaskStateLib.isLegalTransition(
            TaskStateLib.State.Completed, TaskStateLib.State.Working
        ));
    }

    function test_stateLib_terminalAndActive() public pure {
        assertTrue(TaskStateLib.isTerminal(TaskStateLib.State.Completed));
        assertTrue(TaskStateLib.isTerminal(TaskStateLib.State.Failed));
        assertTrue(TaskStateLib.isTerminal(TaskStateLib.State.Canceled));
        assertTrue(TaskStateLib.isTerminal(TaskStateLib.State.Disputed));
        assertFalse(TaskStateLib.isTerminal(TaskStateLib.State.Working));
        assertFalse(TaskStateLib.isTerminal(TaskStateLib.State.Submitted));
        assertFalse(TaskStateLib.isTerminal(TaskStateLib.State.InputRequired));

        assertTrue(TaskStateLib.isActive(TaskStateLib.State.Submitted));
        assertTrue(TaskStateLib.isActive(TaskStateLib.State.Working));
        assertTrue(TaskStateLib.isActive(TaskStateLib.State.InputRequired));
        assertFalse(TaskStateLib.isActive(TaskStateLib.State.Completed));
    }

    // ========================================================================
    // Task Creation (FR-2.2)
    // ========================================================================

    function test_createTaskSuccess() public {
        address[] memory participants = new address[](2);
        participants[0] = alice;
        participants[1] = bob;

        uint256 taskId = _createTask(alice, participants, 1 ether);
        assertEq(taskId, 1, "First task ID");
        assertEq(uint256(tasks.getState(taskId)), uint256(TaskStateLib.State.Submitted));

        TaskLifecycle.Task memory task = tasks.getTask(taskId);
        assertEq(task.initiator, alice);
        assertEq(task.reward, 1 ether);
        assertEq(task.participants.length, 2);
        assertTrue(tasks.isParticipant(taskId, alice));
        assertTrue(tasks.isParticipant(taskId, bob));
    }

    function test_createTaskRejectsEmptyParticipants() public {
        address[] memory participants = new address[](0);
        vm.expectRevert(TaskLifecycle.EmptyParticipants.selector);
        _createTask(alice, participants, 1 ether);
    }

    function test_createTaskRejectsZeroSpecHash() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        vm.prank(alice);
        vm.expectRevert(TaskLifecycle.InvalidSpecHash.selector);
        tasks.createTask{value: 1 ether}(bytes32(0), participants);
    }

    function test_createTaskRejectsTooManyParticipants() public {
        address[] memory participants = new address[](XYXConstants.MAX_PARTICIPANTS_PER_TASK + 1);
        for (uint256 i = 0; i < participants.length; i++) {
            participants[i] = address(uint160(0x1000 + i));
        }
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                TaskLifecycle.TooManyParticipants.selector,
                XYXConstants.MAX_PARTICIPANTS_PER_TASK + 1,
                XYXConstants.MAX_PARTICIPANTS_PER_TASK
            )
        );
        tasks.createTask{value: 1 ether}(keccak256("spec"), participants);
    }

    // ========================================================================
    // Message Submission (FR-2.3) — first message transitions Submitted → Working
    // ========================================================================

    function test_submitMessageTransitionsToWorking() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("answer"), "ipfs://Qm.../msg1");

        assertEq(uint256(tasks.getState(taskId)), uint256(TaskStateLib.State.Working));
        assertEq(tasks.getMessageCount(taskId), 1);

        TaskStateLib.Message[] memory msgs = tasks.getMessages(taskId);
        assertEq(msgs[0].sender, bob);
        assertEq(msgs[0].contentHash, keccak256("answer"));
        assertEq(msgs[0].refUri, "ipfs://Qm.../msg1");
    }

    function test_submitMessageRejectsNonParticipant() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(TaskLifecycle.NotParticipant.selector, taskId, carol)
        );
        tasks.submitMessage(taskId, keccak256("x"), "");
    }

    function test_submitMessageRejectsZeroContent() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(bob);
        vm.expectRevert(TaskLifecycle.InvalidSpecHash.selector);
        tasks.submitMessage(taskId, bytes32(0), "");
    }

    function test_submitMessageRejectsAfterDeadline() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.warp(block.timestamp + XYXConstants.MAX_TASK_DURATION + 1);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                TaskLifecycle.TaskExpired.selector, taskId,
                tasks.getTask(taskId).deadline
            )
        );
        tasks.submitMessage(taskId, keccak256("x"), "");
    }

    function test_submitMultipleMessages() public {
        address[] memory participants = new address[](2);
        participants[0] = alice;
        participants[1] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(alice);
        tasks.submitMessage(taskId, keccak256("alice-msg"), "");
        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("bob-msg"), "");

        assertEq(tasks.getMessageCount(taskId), 2);
    }

    // ========================================================================
    // InputRequired transitions
    // ========================================================================

    function test_requestInputTransition() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        // First message → Working
        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("m1"), "");
        assertEq(uint256(tasks.getState(taskId)), uint256(TaskStateLib.State.Working));

        // Request input → InputRequired
        vm.prank(bob);
        tasks.requestInput(taskId, keccak256("question"));
        assertEq(uint256(tasks.getState(taskId)), uint256(TaskStateLib.State.InputRequired));
    }

    function test_provideInputReturnsToWorking() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("m1"), "");
        vm.prank(bob);
        tasks.requestInput(taskId, keccak256("q"));

        vm.prank(alice);
        tasks.provideInput(taskId, keccak256("answer"), "ipfs://...");
        assertEq(uint256(tasks.getState(taskId)), uint256(TaskStateLib.State.Working));
    }

    function test_provideInputRejectsNonInitiator() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("m1"), "");
        vm.prank(bob);
        tasks.requestInput(taskId, keccak256("q"));

        vm.prank(bob); // Bob is not initiator
        vm.expectRevert(
            abi.encodeWithSelector(TaskLifecycle.NotInitiator.selector, taskId, bob)
        );
        tasks.provideInput(taskId, keccak256("x"), "");
    }

    // ========================================================================
    // Task Completion (FR-2.4) — only initiator
    // ========================================================================

    function test_completeTaskOnlyInitiator() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("m1"), "");

        // Bob cannot complete
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(TaskLifecycle.NotInitiator.selector, taskId, bob)
        );
        tasks.completeTask(taskId, keccak256("final"));

        // Alice can
        vm.prank(alice);
        tasks.completeTask(taskId, keccak256("final"));
        assertEq(uint256(tasks.getState(taskId)), uint256(TaskStateLib.State.Completed));
    }

    function test_completeTaskRejectsZeroFinalAnswer() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(alice);
        vm.expectRevert(TaskLifecycle.InvalidSpecHash.selector);
        tasks.completeTask(taskId, bytes32(0));
    }

    // ========================================================================
    // Cancel
    // ========================================================================

    function test_cancelTaskOnlyInitiator() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(TaskLifecycle.NotInitiator.selector, taskId, bob)
        );
        tasks.cancelTask(taskId);

        vm.prank(alice);
        tasks.cancelTask(taskId);
        assertEq(uint256(tasks.getState(taskId)), uint256(TaskStateLib.State.Canceled));
    }

    function test_cancelTaskRejectsAfterMessages() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("m1"), "");

        vm.prank(alice);
        vm.expectRevert(); // InvalidStateTransition
        tasks.cancelTask(taskId);
    }

    // ========================================================================
    // Timeout
    // ========================================================================

    function test_timeoutAfterDeadline() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("m1"), "");

        vm.warp(block.timestamp + XYXConstants.MAX_TASK_DURATION + 1);

        // Anyone can call
        tasks.timeoutTask(taskId);
        assertEq(uint256(tasks.getState(taskId)), uint256(TaskStateLib.State.Failed));
    }

    function test_timeoutRejectsBeforeDeadline() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.expectRevert(); // TaskExpired
        tasks.timeoutTask(taskId);
    }

    function test_timeoutRejectsOnTerminalState() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(alice);
        tasks.cancelTask(taskId);

        vm.warp(block.timestamp + XYXConstants.MAX_TASK_DURATION + 1);
        vm.expectRevert();
        tasks.timeoutTask(taskId);
    }

    function test_timeoutRefundsInitiator() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 reward = 1 ether;
        uint256 aliceBefore = alice.balance;
        uint256 taskId = _createTask(alice, participants, reward);

        // Need to be in Working (or InputRequired) for timeout to Failed
        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("m1"), "");

        vm.warp(block.timestamp + XYXConstants.MAX_TASK_DURATION + 1);
        tasks.timeoutTask(taskId);

        assertEq(alice.balance, aliceBefore, "Initiator refunded (reward was held, then returned)");
    }

    // ========================================================================
    // Reward Withdrawal (pull-payment)
    // ========================================================================

    function test_withdrawRewardAfterCompletion() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 reward = 1 ether;
        uint256 bobBefore = bob.balance;
        uint256 taskId = _createTask(alice, participants, reward);

        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("m1"), "");

        vm.prank(alice);
        tasks.completeTask(taskId, keccak256("final"));

        vm.prank(bob);
        tasks.withdrawReward(taskId);
        assertEq(bob.balance, bobBefore + reward, "Bob got the reward");
    }

    function test_withdrawRewardAfterCancel() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 reward = 1 ether;
        uint256 aliceBefore = alice.balance;
        uint256 taskId = _createTask(alice, participants, reward);

        vm.prank(alice);
        tasks.cancelTask(taskId);

        vm.prank(alice);
        tasks.withdrawReward(taskId);
        // aliceBefore is BEFORE createTask (which took reward). After withdraw, balance should equal aliceBefore.
        assertEq(alice.balance, aliceBefore, "Alice refunded (net zero)");
    }

    function test_withdrawRewardRejectsIfNotCompletedOrCanceled() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("m1"), "");

        vm.expectRevert();
        tasks.withdrawReward(taskId);
    }

    function test_withdrawRewardRejectsDoubleClaim() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("m1"), "");
        vm.prank(alice);
        tasks.completeTask(taskId, keccak256("f"));

        vm.prank(bob);
        tasks.withdrawReward(taskId);

        vm.prank(bob);
        vm.expectRevert(TaskLifecycle.NoRewardToWithdraw.selector);
        tasks.withdrawReward(taskId);
    }

    // ========================================================================
    // Dispute marking
    // ========================================================================

    function test_markDisputedTransitions() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("m1"), "");

        tasks.markDisputed(taskId, 42);
        assertEq(uint256(tasks.getState(taskId)), uint256(TaskStateLib.State.Disputed));
        assertEq(tasks.getTask(taskId).disputeId, 42);
    }

    function test_markDisputedOnlyOwner() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("m1"), "");

        vm.prank(alice);
        vm.expectRevert();
        tasks.markDisputed(taskId, 1);
    }

    function test_markDisputedRejectsDoubleDispute() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("m1"), "");

        tasks.markDisputed(taskId, 1);
        vm.expectRevert(
            abi.encodeWithSelector(TaskLifecycle.TaskAlreadyDisputed.selector, taskId)
        );
        tasks.markDisputed(taskId, 2);
    }

    // ========================================================================
    // Misc
    // ========================================================================

    function test_getTaskNonexistent() public {
        vm.expectRevert(
            abi.encodeWithSelector(TaskLifecycle.TaskNotFound.selector, 999)
        );
        tasks.submitMessage(999, keccak256("x"), "");
    }

    function test_submitMessageAfterCancelFails() public {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        uint256 taskId = _createTask(alice, participants, 1 ether);

        vm.prank(alice);
        tasks.cancelTask(taskId);

        vm.prank(bob);
        vm.expectRevert(); // TaskNotInState
        tasks.submitMessage(taskId, keccak256("x"), "");
    }
}
