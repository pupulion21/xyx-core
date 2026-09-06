// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {AgentRegistry} from "../src/core/AgentRegistry.sol";
import {TaskLifecycle} from "../src/core/TaskLifecycle.sol";
import {DisputeResolver} from "../src/core/DisputeResolver.sol";
import {ExecutionEngine} from "../src/core/ExecutionEngine.sol";
import {BFT} from "../src/libraries/BFT.sol";
import {TaskStateLib} from "../src/libraries/TaskStateLib.sol";
import {XYXConstants} from "../src/libraries/XYXConstants.sol";

/// @title IntegrationTest
/// @notice End-to-end test of the full XYX protocol: registration → task creation → execution →
///         dispute → BFT voting → slash + reward distribution + reputation updates.
/// @dev This is the "acceptance test" of the system — all 4 core contracts wired together, no
///      mocks. The flow mirrors what a real user would do on Monad testnet.
contract IntegrationTest is Test {
    // ============================================================================
    //                                 ACTORS
    // ============================================================================

    address alice = address(0xA11CE); // task initiator
    address bob = address(0xB0B);     // task participant (the agent whose work is disputed)
    address carol = address(0xCA02); // juror
    address dave = address(0xDA02);  // juror
    address eve = address(0xE1E);    // juror
    address frank = address(0xF2A);  // juror
    address grace = address(0x67A);  // juror
    address treasury = address(0x7E45);

    // ============================================================================
    //                                 CONTRACTS
    // ============================================================================

    AgentRegistry public registry;
    TaskLifecycle public tasks;
    DisputeResolver public resolver;
    ExecutionEngine public engine;

    // ============================================================================
    //                                 STATE
    // ============================================================================

    uint256 aliceAgentId;
    uint256 bobAgentId;
    uint256 taskId;
    uint256 disputeId;
    address[] public jurors;

    // ============================================================================
    //                                 SETUP
    // ============================================================================

    function setUp() public {
        // 1. Deploy core contracts. Engine is the owner of all 3.
        registry = new AgentRegistry(address(this));
        tasks = new TaskLifecycle(address(this), address(registry));
        engine = new ExecutionEngine(
            address(this),
            address(registry),
            address(tasks),
            treasury
        );
        resolver = new DisputeResolver(address(this), address(registry), address(tasks));

        // 2. 2-step ownership transfers (tasks → engine, registry → engine)
        tasks.transferOwnership(address(engine));
        vm.prank(address(engine));
        tasks.acceptOwnership();

        registry.transferOwnership(address(engine));
        vm.prank(address(engine));
        registry.acceptOwnership();

        // 3. Wire engine ↔ resolver (BEFORE transferring resolver ownership)
        engine.setDisputeResolver(address(resolver));
        resolver.setExecutionEngine(address(engine));

        // 4. 2-step ownership: resolver → engine
        resolver.transferOwnership(address(engine));
        vm.prank(address(engine));
        resolver.acceptOwnership();

        // 5. Fund all actors
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(dave, 100 ether);
        vm.deal(eve, 100 ether);
        vm.deal(frank, 100 ether);
        vm.deal(grace, 100 ether);
        vm.deal(treasury, 100 ether);

        // 6. Register Alice and Bob as agents, Carol/Dave/Eve/Frank/Grace as jurors
        aliceAgentId = _registerAgent(alice, "data-analysis");
        bobAgentId = _registerAgent(bob, "data-analysis");
        _registerJuror(carol);
        _registerJuror(dave);
        _registerJuror(eve);
        _registerJuror(frank);
        _registerJuror(grace);
    }

    // ============================================================================
    //                                 HELPERS
    // ============================================================================

    function _registerAgent(address who, string memory cap) internal returns (uint256) {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256(bytes(cap));
        vm.prank(who);
        return registry.registerAgent{value: XYXConstants.MIN_AGENT_STAKE + XYXConstants.REGISTRATION_FEE}(
            string(abi.encodePacked("https://", who)), caps
        );
    }

    function _registerJuror(address who) internal {
        vm.prank(who);
        registry.registerJuror{value: XYXConstants.MIN_JUROR_STAKE + XYXConstants.REGISTRATION_FEE}(
            string(abi.encodePacked("https://", who))
        );
    }

    function _createAndAdvanceTask() internal {
        // Alice creates a task with Bob as the agent, attaching 1 MON reward
        address[] memory participants = new address[](1);
        participants[0] = bob;
        vm.prank(alice);
        taskId = tasks.createTask{value: 1 ether}(keccak256("spec"), participants);

        // Bob does the work and submits a message (moves task to Working)
        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("bob-final-answer"), "ipfs://bob-final");
    }

    // ============================================================================
    //                  FLOW 1: FRIVOLOUS DISPUTE — AGENT WINS
    // ============================================================================
    // Alice tries to dispute Bob's correct answer. Jurors vote Against (Bob is right).
    // Result: Alice is slashed 15%, Bob receives no extra reward (he already got the
    // task reward), jurors split 60% of slash, treasury gets 10%, Bob's reputation
    // is unchanged, Alice's reputation drops, honest jurors get +1 reputation.

    function test_fullFlow_frivolousDisputeAgentWins() public {
        // 1. Create task: Alice initiates, Bob executes
        _createAndAdvanceTask();

        // Snapshot pre-dispute state
        uint256 aliceStakeBefore = registry.stakeOf(aliceAgentId);
        uint256 bobStakeBefore = registry.stakeOf(bobAgentId);
        uint256 aliceRepBefore = registry.getReputation(aliceAgentId);
        uint256 bobRepBefore = registry.getReputation(bobAgentId);
        uint256 treasuryBalanceBefore = engine.treasuryBalance();

        // 2. Alice (frivolously) disputes Bob's answer
        vm.prank(alice);
        disputeId = resolver.triggerDispute{value: XYXConstants.DISPUTE_FEE}(
            taskId, keccak256("alice-wrong-answer")
        );
        assertEq(disputeId, 1, "First dispute ID");
        assertEq(uint256(tasks.getState(taskId)), uint256(TaskStateLib.State.Disputed), "Task disputed");

        // Dispute fee went to engine treasury
        assertEq(
            engine.treasuryBalance(),
            treasuryBalanceBefore + XYXConstants.DISPUTE_FEE,
            "Dispute fee accrued"
        );

        // 3. Warp past evidence deadline and select jurors
        vm.warp(block.timestamp + XYXConstants.EVIDENCE_DEADLINE + 1);
        resolver.selectJurors(disputeId);
        jurors = resolver.getJurors(disputeId);
        assertEq(jurors.length, 5, "5 jurors selected");

        // 4. All 5 jurors vote Against (Bob's answer is correct)
        for (uint256 i = 0; i < jurors.length; i++) {
            vm.prank(jurors[i]);
            resolver.castVote(disputeId, BFT.VoteChoice.Against, keccak256("bob-is-right"));
        }
        assertEq(resolver.getVotes(disputeId).length, 5, "All 5 voted");

        // 5. Warp past vote deadline and resolve
        vm.warp(block.timestamp + XYXConstants.VOTE_DEADLINE + 1);
        resolver.resolveDispute(disputeId);

        // 6. Verify resolution: Against wins, decisive
        BFT.Resolution memory r = resolver.getResolution(disputeId);
        assertFalse(r.winnerSupport, "Agent (Bob) wins");
        assertFalse(r.inconclusive, "Decisive");
        assertEq(uint256(resolver.getState(disputeId)), uint256(DisputeResolver.DisputeState.Resolved));

        // 7. Verify slashing: Alice (frivolous disputer) slashed 15%
        uint256 expectedAliceSlash = (aliceStakeBefore * XYXConstants.FRIVOLOUS_DISPUTE_SLASH_BPS)
            / XYXConstants.BPS_DENOMINATOR;
        assertEq(
            registry.stakeOf(aliceAgentId),
            aliceStakeBefore - expectedAliceSlash,
            "Alice slashed 15%"
        );

        // 8. Verify Bob's stake is unchanged (agent doesn't get extra reward on frivolous path)
        assertEq(registry.stakeOf(bobAgentId), bobStakeBefore, "Bob's stake unchanged");

        // 9. Verify reputation: Alice drops, Bob is winner so gets +DELTA_DISPUTE_WON (+10)
        assertLt(registry.getReputation(aliceAgentId), aliceRepBefore, "Alice rep dropped");
        assertGe(registry.getReputation(bobAgentId), bobRepBefore, "Bob rep up (winner)");

        // 10. Verify distribution: 60% juror pool + 10% treasury cut
        uint256 jurorPool = (expectedAliceSlash * XYXConstants.JUROR_REWARD_SHARE)
            / XYXConstants.REWARD_DISTRIBUTION_DENOM;
        uint256 treasuryCut = (expectedAliceSlash * XYXConstants.TREASURY_SHARE)
            / XYXConstants.REWARD_DISTRIBUTION_DENOM;

        // Total juror pending rewards (across all 5) should equal the pool (minus wei dust)
        uint256 totalJurorPending;
        for (uint256 i = 0; i < jurors.length; i++) {
            totalJurorPending += resolver.pendingJurorReward(jurors[i]);
        }
        assertApproxEqAbs(totalJurorPending, jurorPool, 5, "Juror pool distributed");

        // Treasury got 10% of slash (plus the original dispute fee)
        assertEq(
            engine.treasuryBalance(),
            treasuryBalanceBefore + XYXConstants.DISPUTE_FEE + treasuryCut,
            "Treasury got 10% + dispute fee"
        );

        // 11. Jurors can actually withdraw their rewards
        uint256 carolPending = resolver.pendingJurorReward(carol);
        if (carolPending > 0) {
            uint256 carolBalBefore = carol.balance;
            vm.prank(carol);
            resolver.withdrawJurorReward();
            assertEq(carol.balance, carolBalBefore + carolPending, "Carol withdrew reward");
        }
    }

    // ============================================================================
    //                  FLOW 2: VALID DISPUTE — DISPUTER WINS
    // ============================================================================
    // Bob gives a wrong answer. Alice disputes. Jurors vote Support (disputer wins).
    // Result: Bob (the agent) is slashed 10%, Alice (disputer) gets 30% of slash as
    // a reward, jurors split 60%, treasury gets 10%, Bob's reputation drops -10,
    // Alice's reputation goes up, honest jurors get +1 reputation.

    function test_fullFlow_validDisputeDisputerWins() public {
        _createAndAdvanceTask();

        uint256 bobStakeBefore = registry.stakeOf(bobAgentId);
        uint256 aliceRepBefore = registry.getReputation(aliceAgentId);
        uint256 bobRepBefore = registry.getReputation(bobAgentId);
        uint256 treasuryBalanceBefore = engine.treasuryBalance();

        // Alice disputes Bob's wrong answer
        vm.prank(alice);
        disputeId = resolver.triggerDispute{value: XYXConstants.DISPUTE_FEE}(
            taskId, keccak256("correct-answer")
        );

        // Snapshot balance AFTER dispute fee paid (so the assertion math is clean)
        uint256 aliceBalAfterFee = alice.balance;

        // Select jurors
        vm.warp(block.timestamp + XYXConstants.EVIDENCE_DEADLINE + 1);
        resolver.selectJurors(disputeId);
        jurors = resolver.getJurors(disputeId);

        // All 5 vote Support (Alice is right)
        for (uint256 i = 0; i < jurors.length; i++) {
            vm.prank(jurors[i]);
            resolver.castVote(disputeId, BFT.VoteChoice.Support, keccak256("alice-is-right"));
        }

        // Resolve
        vm.warp(block.timestamp + XYXConstants.VOTE_DEADLINE + 1);
        resolver.resolveDispute(disputeId);

        BFT.Resolution memory r = resolver.getResolution(disputeId);
        assertTrue(r.winnerSupport, "Disputer (Alice) wins");
        assertFalse(r.inconclusive, "Decisive");

        // Bob's stake is exactly MIN_AGENT_STAKE (registration fee is separate)
        assertEq(bobStakeBefore, XYXConstants.MIN_AGENT_STAKE, "Bob's stake is just MIN_AGENT_STAKE");

        // Bob (agent, loser) slashed 10%
        uint256 expectedBobSlash = (bobStakeBefore * XYXConstants.AGENT_SLASH_BPS)
            / XYXConstants.BPS_DENOMINATOR;
        assertEq(
            registry.stakeOf(bobAgentId),
            bobStakeBefore - expectedBobSlash,
            "Bob slashed 10%"
        );

        // Alice (disputer, winner) reputation goes up
        assertGe(registry.getReputation(aliceAgentId), aliceRepBefore, "Alice rep up");
        // Bob's reputation drops
        assertLt(registry.getReputation(bobAgentId), bobRepBefore, "Bob rep down");

        // Alice received 30% of slash as winner reward
        uint256 expectedAliceReward = (expectedBobSlash * XYXConstants.WINNER_REWARD_SHARE)
            / XYXConstants.REWARD_DISTRIBUTION_DENOM;
        assertEq(
            alice.balance,
            aliceBalAfterFee + expectedAliceReward,
            "Alice got 30% winner reward"
        );

        // Juror pool distributed
        uint256 jurorPool = (expectedBobSlash * XYXConstants.JUROR_REWARD_SHARE)
            / XYXConstants.REWARD_DISTRIBUTION_DENOM;
        uint256 totalJurorPending;
        for (uint256 i = 0; i < jurors.length; i++) {
            totalJurorPending += resolver.pendingJurorReward(jurors[i]);
        }
        assertApproxEqAbs(totalJurorPending, jurorPool, 5, "Juror pool distributed");

        // Treasury got 10% of slash + dispute fee
        uint256 treasuryCut = (expectedBobSlash * XYXConstants.TREASURY_SHARE)
            / XYXConstants.REWARD_DISTRIBUTION_DENOM;
        assertEq(
            engine.treasuryBalance(),
            treasuryBalanceBefore + XYXConstants.DISPUTE_FEE + treasuryCut,
            "Treasury accrued"
        );
    }

    // ============================================================================
    //                  FLOW 3: INCONCLUSIVE — NO SLASH, NO REWARD
    // ============================================================================
    // Jurors split 2-2-1 (tie). Resolution is inconclusive. Neither side is slashed,
    // no rewards distributed, no reputation changes from the dispute.

    function test_fullFlow_inconclusiveNoOp() public {
        _createAndAdvanceTask();

        uint256 bobStakeBefore = registry.stakeOf(bobAgentId);
        uint256 aliceRepBefore = registry.getReputation(aliceAgentId);
        uint256 bobRepBefore = registry.getReputation(bobAgentId);

        vm.prank(alice);
        disputeId = resolver.triggerDispute{value: XYXConstants.DISPUTE_FEE}(
            taskId, keccak256("alt")
        );

        vm.warp(block.timestamp + XYXConstants.EVIDENCE_DEADLINE + 1);
        resolver.selectJurors(disputeId);
        jurors = resolver.getJurors(disputeId);

        // 2 Support, 2 Against, 1 Abstain = inconclusive
        vm.prank(jurors[0]);
        resolver.castVote(disputeId, BFT.VoteChoice.Support, keccak256("r"));
        vm.prank(jurors[1]);
        resolver.castVote(disputeId, BFT.VoteChoice.Support, keccak256("r"));
        vm.prank(jurors[2]);
        resolver.castVote(disputeId, BFT.VoteChoice.Against, keccak256("r"));
        vm.prank(jurors[3]);
        resolver.castVote(disputeId, BFT.VoteChoice.Against, keccak256("r"));
        vm.prank(jurors[4]);
        resolver.castVote(disputeId, BFT.VoteChoice.Abstain, keccak256("r"));

        vm.warp(block.timestamp + XYXConstants.VOTE_DEADLINE + 1);
        resolver.resolveDispute(disputeId);

        BFT.Resolution memory r = resolver.getResolution(disputeId);
        assertTrue(r.inconclusive, "Tie makes inconclusive");

        // No slashing, no reputation change
        assertEq(registry.stakeOf(bobAgentId), bobStakeBefore, "Bob stake unchanged");
        assertEq(registry.getReputation(aliceAgentId), aliceRepBefore, "Alice rep unchanged");
        assertEq(registry.getReputation(bobAgentId), bobRepBefore, "Bob rep unchanged");

        // No juror rewards credited
        for (uint256 i = 0; i < jurors.length; i++) {
            assertEq(resolver.pendingJurorReward(jurors[i]), 0, "No rewards on inconclusive");
        }
    }

    // ============================================================================
    //                  FLOW 4: WITHDRAWAL — JURORS CLAIM REWARDS
    // ============================================================================
    // End-to-end: jurors actually pull their rewards out of the resolver. This
    // verifies the pull-payment model (D11) works under real conditions.

    function test_fullFlow_jurorsClaimRewards() public {
        _createAndAdvanceTask();

        vm.prank(alice);
        disputeId = resolver.triggerDispute{value: XYXConstants.DISPUTE_FEE}(
            taskId, keccak256("alt")
        );

        vm.warp(block.timestamp + XYXConstants.EVIDENCE_DEADLINE + 1);
        resolver.selectJurors(disputeId);
        jurors = resolver.getJurors(disputeId);

        for (uint256 i = 0; i < jurors.length; i++) {
            vm.prank(jurors[i]);
            resolver.castVote(disputeId, BFT.VoteChoice.Support, keccak256("r"));
        }

        vm.warp(block.timestamp + XYXConstants.VOTE_DEADLINE + 1);
        resolver.resolveDispute(disputeId);

        // Snapshot total pending + balances before withdrawal
        uint256 totalPending;
        for (uint256 i = 0; i < jurors.length; i++) {
            totalPending += resolver.pendingJurorReward(jurors[i]);
        }
        assertGt(totalPending, 0, "Some rewards distributed");

        uint256[] memory balBefore = new uint256[](jurors.length);
        for (uint256 i = 0; i < jurors.length; i++) {
            balBefore[i] = jurors[i].balance;
        }

        // All jurors claim
        for (uint256 i = 0; i < jurors.length; i++) {
            uint256 pending = resolver.pendingJurorReward(jurors[i]);
            if (pending > 0) {
                vm.prank(jurors[i]);
                resolver.withdrawJurorReward();
                assertEq(jurors[i].balance, balBefore[i] + pending, "Balance increased");
                assertEq(resolver.pendingJurorReward(jurors[i]), 0, "Pending zeroed");
            }
        }

        // Second withdraw should fail (no pending)
        vm.prank(jurors[0]);
        vm.expectRevert(DisputeResolver.WithdrawFailed.selector);
        resolver.withdrawJurorReward();
    }

    // ============================================================================
    //                  FLOW 5: HONEST TASK COMPLETION
    // ============================================================================
    // Happy path: Alice creates a task, Bob executes, Alice approves. No dispute.
    // The 1 MON reward is paid to Bob, plus reputation boost.

    function test_fullFlow_happyPathTaskCompletion() public {
        _createAndAdvanceTask();

        uint256 bobRepBefore = registry.getReputation(bobAgentId);

        // Bob submits the final answer
        vm.prank(bob);
        bytes32 finalAnswer = keccak256("bob-is-done");
        tasks.submitMessage(taskId, finalAnswer, "ipfs://final");

        // Alice completes the task with the final answer
        vm.prank(alice);
        tasks.completeTask(taskId, finalAnswer);

        // Task is completed
        assertEq(uint256(tasks.getState(taskId)), uint256(TaskStateLib.State.Completed));

        // Bob's reputation goes up
        assertGe(registry.getReputation(bobAgentId), bobRepBefore, "Bob rep boosted");

        // Bob can withdraw the 1 MON reward
        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        tasks.withdrawReward(taskId);
        assertEq(bob.balance, bobBalBefore + 1 ether, "Bob got 1 MON reward");
    }
}
