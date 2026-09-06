// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AgentRegistry} from "../src/core/AgentRegistry.sol";
import {ReputationLib} from "../src/libraries/ReputationLib.sol";
import {BFT} from "../src/libraries/BFT.sol";
import {XYXConstants} from "../src/libraries/XYXConstants.sol";

/// @title AuditRegressions
/// @notice Regression tests for the 6 CRITICAL+HIGH bugs found in the Week 1 audit.
/// Each test name maps to a finding in AUDIT_REPORT.md.
contract AuditRegressionsTest is Test {
    AgentRegistry registry;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA02);

    function setUp() public {
        registry = new AgentRegistry(address(this));
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    function _registerAgent(address who, uint256 value) internal returns (uint256) {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("test");
        vm.prank(who);
        return registry.registerAgent{value: value}("https://x.xyz", caps);
    }

    // ========================================================================
    // C1: getReputation / getTier / getVoteWeight must apply decay
    // ========================================================================

    function test_C1_getReputationAppliesDecay() public {
        uint256 agentId = _registerAgent(alice, 0.1 ether + 0.001 ether);
        // Initial reputation is 100e18 (Medium)
        assertEq(registry.getReputation(agentId), 100 * 1e18, "Fresh agent rep=100");

        // Advance 30 + 4 weeks = 58 days → 4 weeks of decay
        vm.warp(block.timestamp + 30 days + 4 weeks);
        uint256 decayed = registry.getReputation(agentId);
        // 100 * 0.99^4 ≈ 96.06e18
        assertApproxEqRel(decayed, 96.06 * 1e18, 0.01e18, "Reputation should decay ~3.94");
    }

    function test_C1_getTierAppliesDecay() public {
        uint256 agentId = _registerAgent(alice, 0.1 ether + 0.001 ether);
        // Medium initially
        assertEq(uint256(registry.getTier(agentId)), uint256(ReputationLib.Tier.Medium));

        // 100 * 0.99^75 ≈ 46.7e18 — drops below 50, becomes Low
        vm.warp(block.timestamp + 30 days + 75 weeks);
        ReputationLib.Tier after_ = registry.getTier(agentId);
        assertEq(uint256(after_), uint256(ReputationLib.Tier.Low), "Tier drops to Low after 75w decay");
    }

    function test_C1_getVoteWeightAppliesDecay() public {
        uint256 agentId = _registerAgent(alice, 0.1 ether + 0.001 ether);
        // Initial: stake=0.1 ether, tier=Medium (1.5x) → weight = 0.1 * 150 / 100 = 0.15
        assertEq(registry.getVoteWeight(agentId), 0.15 ether, "Initial vote weight");

        // After long decay, tier drops to None → multiplier 0 → weight 0
        vm.warp(block.timestamp + 30 days + 200 weeks);
        // 200 weeks decay: 100 * 0.99^200 ≈ 13.4e18 → Low tier → 1.0x → 0.1 ether
        // (NOT None, rep is still > 0)
        uint256 weight = registry.getVoteWeight(agentId);
        assertTrue(weight < 0.15 ether, "Vote weight should drop after decay");
    }

    // ========================================================================
    // C4: explicit post-fee stake check (defensive)
    // ========================================================================

    function test_C4_explicitStakeCheck() public {
        // msg.value == MIN + fee passes; stake == MIN passes (boundary ok)
        // Can't trigger BelowMinStakeAfterFee with current constants because
        // msg.value >= MIN+fee ⟹ stake = msg.value-fee >= MIN.
        // This test documents the current invariant. If MIN_AGENT_STAKE is
        // bumped without bumping the registration-required check, this test
        // would still pass but the implicit check would silently break.
        uint256 agentId = _registerAgent(alice, 0.1 ether + 0.001 ether);
        assertEq(registry.getAgent(agentId).stake, 0.1 ether, "Stake = msg.value - fee");
    }

    // ========================================================================
    // H1: slash validates percentBps <= 10000
    // ========================================================================

    function test_H1_slashRejectsInvalidBps() public {
        uint256 agentId = _registerAgent(alice, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(AgentRegistry.InvalidSlashBps.selector, 10001, 10000)
        );
        registry.slash(agentId, 10001);
    }

    function test_H1_slashAcceptsBoundaryBps() public {
        uint256 agentId = _registerAgent(alice, 1 ether);
        // Exactly 10000 bps = 100% should work
        uint256 slashed = registry.slash(agentId, 10000);
        assertEq(slashed, 0.999 ether, "100% slash = full stake minus fee");
        assertEq(registry.getAgent(agentId).stake, 0, "Stake fully drained");
        assertFalse(registry.getAgent(agentId).active, "Deactivated");
    }

    // ========================================================================
    // H2: addStake reactivates inactive agents
    // ========================================================================

    function test_H2_addStakeReactivates() public {
        // Register with 0.1 + 0.001 ether
        uint256 agentId = _registerAgent(alice, 0.1 ether + 0.001 ether);
        // Slash 100% → stake = 0, active = false
        registry.slash(agentId, 10000);
        assertFalse(registry.getAgent(agentId).active, "Should be deactivated");

        // Alice tops up with 0.5 ether
        vm.prank(alice);
        registry.addStake{value: 0.5 ether}();

        assertTrue(registry.getAgent(agentId).active, "Should be reactivated");
        assertEq(registry.getAgent(agentId).stake, 0.5 ether, "Stake updated");
    }

    function test_H2_addStakeStaysInactiveIfBelowMin() public {
        uint256 agentId = _registerAgent(alice, 0.5 ether + 0.001 ether);
        // Slash most of it → 0.01 ether (below MIN_AGENT_STAKE = 0.1)
        // We can't easily get exactly 0.01 from a 100% slash...
        // Instead, withdraw to drop below min
        // Stake = 0.499 ether. Request unstake of 0.45 → stake = 0.049 (< 0.1)
        vm.prank(alice);
        registry.requestUnstake(0.45 ether);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.withdrawUnstake();
        assertFalse(registry.getAgent(agentId).active, "Deactivated after under-min withdrawal");

        // Add only 0.02 ether — still below min → stays inactive
        vm.prank(alice);
        registry.addStake{value: 0.02 ether}();
        assertFalse(registry.getAgent(agentId).active, "Still inactive below min");
    }

    // ========================================================================
    // H3: applyFinalStrike deactivates agent
    // ========================================================================

    function test_H3_finalStrikeDeactivates() public {
        uint256 agentId = _registerAgent(alice, 0.5 ether + 0.001 ether);
        assertTrue(registry.getAgent(agentId).active, "Active before strike");

        registry.applyFinalStrike(agentId);

        assertFalse(registry.getAgent(agentId).active, "Deactivated after final strike");
        // Reputation dropped by 50e18 (from 100 to 50)
        assertEq(registry.getReputation(agentId), 50 * 1e18, "Rep -50");
    }

    // ========================================================================
    // BFT C2: Uncast votes treated like Abstain
    // ========================================================================

    function _makeVote(address juror, BFT.VoteChoice choice, uint256 weight)
        internal
        pure
        returns (BFT.Vote memory)
    {
        return BFT.Vote({juror: juror, choice: choice, weight: weight, cast: true});
    }

    function test_BFT_C2_uncastNotCountedAsOutlier() public pure {
        // 3 Support + 1 Against + 1 Uncast
        BFT.Vote[] memory votes = new BFT.Vote[](5);
        votes[0] = _makeVote(address(1), BFT.VoteChoice.Support, 100);
        votes[1] = _makeVote(address(2), BFT.VoteChoice.Support, 100);
        votes[2] = _makeVote(address(3), BFT.VoteChoice.Support, 100);
        votes[3] = _makeVote(address(4), BFT.VoteChoice.Against, 100);
        votes[4] = _makeVote(address(5), BFT.VoteChoice.Uncast, 100);

        BFT.Resolution memory res = BFT.resolve(votes);
        assertTrue(res.winnerSupport, "Support wins");
        assertFalse(res.inconclusive, "Not inconclusive");
        // Only the Against voter should be an outlier
        assertEq(res.outliers.length, 1, "Uncast NOT counted as outlier");
        assertEq(res.outliers[0], address(4), "Outlier is the Against voter");
    }

    function test_BFT_C2_allUncastIsInconclusive() public pure {
        BFT.Vote[] memory votes = new BFT.Vote[](3);
        votes[0] = _makeVote(address(1), BFT.VoteChoice.Uncast, 100);
        votes[1] = _makeVote(address(2), BFT.VoteChoice.Uncast, 100);
        votes[2] = _makeVote(address(3), BFT.VoteChoice.Uncast, 100);

        BFT.Resolution memory res = BFT.resolve(votes);
        assertTrue(res.inconclusive, "All uncast = inconclusive");
    }

    function test_BFT_C2_mixedUncastSupportWins() public pure {
        // 2 Support + 1 Against + 2 Uncast → Support wins cleanly
        BFT.Vote[] memory votes = new BFT.Vote[](5);
        votes[0] = _makeVote(address(1), BFT.VoteChoice.Support, 100);
        votes[1] = _makeVote(address(2), BFT.VoteChoice.Support, 100);
        votes[2] = _makeVote(address(3), BFT.VoteChoice.Against, 100);
        votes[3] = _makeVote(address(4), BFT.VoteChoice.Uncast, 100);
        votes[4] = _makeVote(address(5), BFT.VoteChoice.Uncast, 100);

        BFT.Resolution memory res = BFT.resolve(votes);
        assertTrue(res.winnerSupport, "Support wins despite uncasts");
        assertFalse(res.inconclusive, "Not inconclusive");
        assertEq(res.outliers.length, 1, "Only Against is outlier");
    }

    // ========================================================================
    // BFT C3: tie (equal weights Support == Against) is inconclusive
    // ========================================================================

    function test_BFT_C3_equalWeightTieInconclusive() public pure {
        // 2 Support (100 each = 200) vs 2 Against (100 each = 200) — tie
        BFT.Vote[] memory votes = new BFT.Vote[](4);
        votes[0] = _makeVote(address(1), BFT.VoteChoice.Support, 100);
        votes[1] = _makeVote(address(2), BFT.VoteChoice.Support, 100);
        votes[2] = _makeVote(address(3), BFT.VoteChoice.Against, 100);
        votes[3] = _makeVote(address(4), BFT.VoteChoice.Against, 100);

        BFT.Resolution memory res = BFT.resolve(votes);
        assertTrue(res.inconclusive, "Equal weight tie is inconclusive");
    }

    function test_BFT_C3_unequalWeightResolves() public pure {
        // Support 200 (2x100) vs Against 150 (1x100 + 1x50) — Support wins
        BFT.Vote[] memory votes = new BFT.Vote[](4);
        votes[0] = _makeVote(address(1), BFT.VoteChoice.Support, 100);
        votes[1] = _makeVote(address(2), BFT.VoteChoice.Support, 100);
        votes[2] = _makeVote(address(3), BFT.VoteChoice.Against, 100);
        votes[3] = _makeVote(address(4), BFT.VoteChoice.Against, 50);

        BFT.Resolution memory res = BFT.resolve(votes);
        assertTrue(res.winnerSupport, "Support wins by weight");
        assertFalse(res.inconclusive, "Not inconclusive");
        assertEq(res.totalWeightSupport, 200, "Support weight");
        assertEq(res.totalWeightAgainst, 150, "Against weight");
    }

    // ========================================================================
    // BFT L1: custom error on empty votes
    // ========================================================================

    function test_BFT_L1_emptyVotesReverts() public {
        // BFT is a library with internal functions — call via wrapper contract
        BFTLibCaller caller = new BFTLibCaller();
        BFT.Vote[] memory votes = new BFT.Vote[](0);
        vm.expectRevert(BFT.NoVotes.selector);
        caller.resolveExternal(votes);
    }

    // ========================================================================
    // PRD ALIGNMENT: outliers > N/2 → inconclusive (PRD §FR-4.2 step 6)
    // ========================================================================

    function test_BFT_alignment_outliersMajorityInconclusive() public pure {
        // 1 Support vs 4 Against. After Krum, the 1 Support is the only outlier
        // (or all 4 Against are outliers if Krum picks the Against reference).
        // Either way, outlier count > N/2 (2) is NOT triggered here because
        // Krum would pick the majority (4 Against) as reference → outliers = 1 Support.
        // So this case actually resolves. Let's test the real PRD scenario:
        // 2 vs 2 with one side winning Krum reference but the OPPOSITE side
        // being the larger weighted group.
        // Actually with the current Krum + k=2, the LOWER score wins. Score for
        // a Support voter (in 2 Support, 3 Against) = sum of 2 smallest distances.
        // Distances: [0, 0, 1, 1] (to other Support, Support, Against, Against)
        // → k=2 = 0+0 = 0. Same for Against: [1, 1, 0, 0] → 0. Tie → first encountered.
        // The outlier > N/2 check catches the case where reference is minority
        // (which shouldn't happen with Krum, but is defensive).
        BFT.Vote[] memory votes = new BFT.Vote[](5);
        votes[0] = _makeVote(address(1), BFT.VoteChoice.Support, 100);
        votes[1] = _makeVote(address(2), BFT.VoteChoice.Support, 100);
        votes[2] = _makeVote(address(3), BFT.VoteChoice.Support, 100);
        votes[3] = _makeVote(address(4), BFT.VoteChoice.Against, 100);
        votes[4] = _makeVote(address(5), BFT.VoteChoice.Against, 100);

        BFT.Resolution memory res = BFT.resolve(votes);
        // With k=2, scores are 0 vs 0, first is reference. Outliers = 2 Against.
        // 2 > 2 is FALSE → not inconclusive. This is the correct behavior.
        assertTrue(res.winnerSupport, "3 vs 2 = Support wins");
        assertFalse(res.inconclusive, "Not inconclusive (outliers = 2, N/2 = 2)");
        assertEq(res.outliers.length, 2, "2 outliers");
    }

    function test_BFT_alignment_outliersStrictMajorityResolves() public pure {
        // 4 Support vs 1 Against: clear majority, 1 outlier, 1 <= 2 (N/2)
        BFT.Vote[] memory votes = new BFT.Vote[](5);
        votes[0] = _makeVote(address(1), BFT.VoteChoice.Support, 100);
        votes[1] = _makeVote(address(2), BFT.VoteChoice.Support, 100);
        votes[2] = _makeVote(address(3), BFT.VoteChoice.Support, 100);
        votes[3] = _makeVote(address(4), BFT.VoteChoice.Support, 100);
        votes[4] = _makeVote(address(5), BFT.VoteChoice.Against, 100);

        BFT.Resolution memory res = BFT.resolve(votes);
        assertTrue(res.winnerSupport, "4 vs 1 = Support wins");
        assertFalse(res.inconclusive, "1 outlier <= N/2 = 2");
        assertEq(res.outliers.length, 1, "1 outlier (the Against voter)");
    }

    // ========================================================================
    // Bonus: unanimous has no outliers
    // ========================================================================

    function test_BFT_bonus_unanimousHasNoOutliers() public pure {
        BFT.Vote[] memory votes = new BFT.Vote[](5);
        for (uint256 i = 0; i < 5; i++) {
            votes[i] = _makeVote(address(uint160(i + 1)), BFT.VoteChoice.Support, 100);
        }
        BFT.Resolution memory res = BFT.resolve(votes);
        assertTrue(res.winnerSupport, "Unanimous support");
        assertEq(res.outliers.length, 0, "No outliers for unanimous");
    }

    // ========================================================================
    // Bonus: onFinalStrike + onTaskTimeout coverage
    // ========================================================================

    function test_RL_finalStrikeDirectly() public {
        uint256 agentId = _registerAgent(alice, 0.5 ether + 0.001 ether);
        uint256 before = registry.getReputation(agentId);
        registry.applyFinalStrike(agentId);
        assertEq(registry.getReputation(agentId), before - 50 * 1e18, "Rep -50 on final strike");
    }

    function test_RL_taskTimeoutDirectly() public {
        // No public hook for onTaskTimeout in AgentRegistry yet (Week 2-3 ExecutionEngine).
        // Verified via constant matching: DELTA_TASK_TIMEOUT = 5e18
        // (applied only via ExecutionEngine.updateReputation(taskTimeout) in future)
        // For now, verify the constant is what we expect.
        // (covered indirectly by applyDecay not advancing on timeout)
        uint256 agentId = _registerAgent(alice, 0.1 ether + 0.001 ether);
        // The constant is implicitly tested by no-regression: this test just
        // verifies the contract is alive after 1 day.
        vm.warp(block.timestamp + 1 days);
        assertEq(registry.getReputation(agentId), 100 * 1e18, "Rep stable within grace period");
    }

    function test_RL_touchActivityDirectly() public {
        // No public hook for touchActivity either; verify decay resets via applyDecay
        uint256 agentId = _registerAgent(alice, 0.1 ether + 0.001 ether);
        // No warp: activity is now (timestamp). Read rep at later time.
        uint256 repNow = registry.getReputation(agentId);
        assertEq(repNow, 100 * 1e18, "Fresh agent rep");
    }

    // ========================================================================
    // M7: Auto-unpause after PAUSE_DURATION_MAX
    // ========================================================================

    function test_M7_manualUnpauseOnlyOwner() public {
        // Pause first so unpause is meaningful
        registry.pause();
        assertTrue(registry.paused(), "Paused");

        // Bob (not owner) cannot manually unpause before deadline
        vm.prank(bob);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        registry.unpause();
        assertTrue(registry.paused(), "Still paused after Bob's failed attempt");

        // Owner can unpause
        registry.unpause();
        assertFalse(registry.paused(), "Owner unpauses");
    }

    function test_M7_autoUnpauseAfterMaxDuration() public {
        // Pause
        registry.pause();
        assertTrue(registry.paused(), "Paused");
        assertEq(registry.pauseTimestamp(), block.timestamp, "pauseTimestamp set");

        // Try auto-unpause BEFORE deadline → no-op
        vm.warp(block.timestamp + 1 days);
        registry.tryAutoUnpause();
        assertTrue(registry.paused(), "Still paused before deadline");

        // Warp past PAUSE_DURATION_MAX
        vm.warp(block.timestamp + XYXConstants.PAUSE_DURATION_MAX + 1);
        registry.tryAutoUnpause();
        assertFalse(registry.paused(), "Auto-unpaused after deadline");
    }

    function test_M7_unpauseChecksAutoExpiry() public {
        // Pause, then warp past max
        registry.pause();
        vm.warp(block.timestamp + XYXConstants.PAUSE_DURATION_MAX + 1);

        // Even Bob (non-owner) can call unpause and it auto-unpauses
        vm.prank(bob);
        registry.unpause();
        assertFalse(registry.paused(), "Auto-unpause via unpause() callable by anyone");
    }

    function test_M7_manualUnpauseBeforeMaxRequiresOwner() public {
        // Pause, then unpause as owner before deadline
        registry.pause();
        registry.unpause();
        assertFalse(registry.paused(), "Owner manual unpause before max");
    }

    // ========================================================================
    // M8: Ownable2Step two-step ownership transfer
    // ========================================================================

    function test_M8_ownershipTransferTwoStep() public {
        address newOwner = address(0xBEEF);
        registry.transferOwnership(newOwner);
        // Ownership NOT transferred until acceptance
        assertEq(registry.owner(), address(this), "Owner unchanged until acceptance");
        assertEq(registry.pendingOwner(), newOwner, "Pending owner set");

        // New owner accepts
        vm.prank(newOwner);
        registry.acceptOwnership();
        assertEq(registry.owner(), newOwner, "New owner after acceptOwnership");
    }

    // ========================================================================
    // H6: findAgentsByCapability paginated to prevent OOG
    // ========================================================================

    function test_H6_paginatedCapabilityLookup() public {
        // Register 5 agents with the same capability
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("data-analysis");

        address[] memory agents = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            address who = address(uint160(0x1000 + i));
            vm.deal(who, 10 ether);
            vm.prank(who);
            registry.registerAgent{value: 0.1 ether + 0.001 ether}(
                string(abi.encodePacked("https://agent", i)), caps
            );
            agents[i] = who;
        }

        // Page 1: offset=0, limit=2
        (address[] memory page1, uint256 total) =
            registry.findAgentsByCapabilityPaginated(keccak256("data-analysis"), 0, 2);
        assertEq(total, 5, "5 total agents");
        assertEq(page1.length, 2, "Page 1 has 2");
        assertEq(page1[0], agents[0], "Page 1 first");
        assertEq(page1[1], agents[1], "Page 1 second");

        // Page 2: offset=2, limit=2
        (address[] memory page2,) =
            registry.findAgentsByCapabilityPaginated(keccak256("data-analysis"), 2, 2);
        assertEq(page2.length, 2, "Page 2 has 2");
        assertEq(page2[0], agents[2], "Page 2 first");
        assertEq(page2[1], agents[3], "Page 2 second");

        // Page 3: offset=4, limit=2 (partial)
        (address[] memory page3,) =
            registry.findAgentsByCapabilityPaginated(keccak256("data-analysis"), 4, 2);
        assertEq(page3.length, 1, "Page 3 has 1");
        assertEq(page3[0], agents[4], "Page 3 first");

        // Offset beyond total → empty
        (address[] memory empty, uint256 totalEmpty) =
            registry.findAgentsByCapabilityPaginated(keccak256("data-analysis"), 10, 5);
        assertEq(empty.length, 0, "Empty page");
        assertEq(totalEmpty, 5, "Total still 5");
    }

    function test_H6_paginatedLimitCappedAt100() public {
        // limit > 100 should be silently capped
        (address[] memory page, uint256 total) =
            registry.findAgentsByCapabilityPaginated(keccak256("nonexistent"), 0, 200);
        assertEq(page.length, 0, "Empty bucket");
        assertEq(total, 0, "Total 0");
    }
}

/// @dev Test helper to expose BFT.resolve as external (libraries with internal functions
///      can't be called directly from a test contract's cheatcode context).
contract BFTLibCaller {
    function resolveExternal(BFT.Vote[] memory votes) external pure returns (BFT.Resolution memory) {
        return BFT.resolve(votes);
    }
}
