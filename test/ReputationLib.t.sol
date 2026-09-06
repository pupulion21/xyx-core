// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ReputationLib} from "../src/libraries/ReputationLib.sol";
import {XYXConstants} from "../src/libraries/XYXConstants.sol";

contract ReputationLibTest is Test {
    using ReputationLib for ReputationLib.State;

    ReputationLib.State state;

    function setUp() public {
        state = ReputationLib.initialize();
    }

    function test_initialReputation() public view {
        assertEq(state.score, 100 * 1e18, "Initial reputation");
        assertEq(uint256(ReputationLib.getTier(state.score)), uint256(ReputationLib.Tier.Medium), "Initial tier");
    }

    function test_tierBoundaries() public pure {
        assertEq(uint256(ReputationLib.getTier(0)), uint256(ReputationLib.Tier.None));
        assertEq(uint256(ReputationLib.getTier(1)), uint256(ReputationLib.Tier.Low));
        assertEq(uint256(ReputationLib.getTier(50 * 1e18)), uint256(ReputationLib.Tier.Low));
        assertEq(uint256(ReputationLib.getTier(51 * 1e18)), uint256(ReputationLib.Tier.Medium));
        assertEq(uint256(ReputationLib.getTier(100 * 1e18)), uint256(ReputationLib.Tier.Medium));
        assertEq(uint256(ReputationLib.getTier(101 * 1e18)), uint256(ReputationLib.Tier.High));
        assertEq(uint256(ReputationLib.getTier(150 * 1e18)), uint256(ReputationLib.Tier.High));
        assertEq(uint256(ReputationLib.getTier(151 * 1e18)), uint256(ReputationLib.Tier.Elite));
        assertEq(uint256(ReputationLib.getTier(200 * 1e18)), uint256(ReputationLib.Tier.Elite));
    }

    function test_taskSuccessIncreasesRep() public {
        uint256 before = state.score;
        state.onTaskSuccess();
        assertEq(state.score, before + 5 * 1e18, "Task success +5");
        assertEq(state.tasksCompleted, 1, "Tasks count");
    }

    function test_taskFailedDecreasesRep() public {
        uint256 before = state.score;
        state.onTaskFailed();
        assertEq(state.score, before - 10 * 1e18, "Task fail -10");
        assertEq(state.tasksFailed, 1, "Tasks failed count");
    }

    function test_disputeWonIncreasesRep() public {
        state.onDisputeWon();
        assertEq(state.score, 100 * 1e18 + 10 * 1e18, "Dispute won +10");
        assertEq(state.disputesWon, 1);
    }

    function test_disputeLostDecreasesRep() public {
        state.onDisputeLost();
        assertEq(state.score, 100 * 1e18 - 20 * 1e18, "Dispute lost -20");
        assertEq(state.disputesLost, 1);
    }

    function test_reputationCap() public {
        // Fill up to MAX
        for (uint256 i = 0; i < 30; i++) {
            state.onTaskSuccess();
            state.onDisputeWon();
        }
        assertEq(state.score, XYXConstants.MAX_REPUTATION, "Should be capped at MAX");
    }

    function test_reputationFloor() public {
        // Apply many negative deltas
        for (uint256 i = 0; i < 20; i++) {
            state.onDisputeLost();
        }
        assertEq(state.score, XYXConstants.MIN_REPUTATION, "Should floor at 0");
    }

    function test_multipliers() public pure {
        assertEq(ReputationLib.getMultiplier(ReputationLib.Tier.Low), 100, "Low 1.0x");
        assertEq(ReputationLib.getMultiplier(ReputationLib.Tier.Medium), 150, "Medium 1.5x");
        assertEq(ReputationLib.getMultiplier(ReputationLib.Tier.High), 200, "High 2.0x");
        assertEq(ReputationLib.getMultiplier(ReputationLib.Tier.Elite), 300, "Elite 3.0x");
    }

    function test_noDecayInGracePeriod() public {
        state.onTaskSuccess(); // Bring to 105
        uint256 before = state.score;

        // Advance 29 days (still in grace)
        vm.warp(block.timestamp + 29 days);
        uint256 after_ = ReputationLib.applyDecay(before, state.lastActivity);

        assertEq(after_, before, "No decay in grace period");
    }

    function test_decayAfterGracePeriod() public {
        uint256 before = state.score; // 100
        uint256 lastActivity = state.lastActivity;

        // Advance 30 + 7 days (1 week past grace)
        vm.warp(block.timestamp + 37 days);
        uint256 after_ = ReputationLib.applyDecay(before, lastActivity);

        // 1% of 100 = 1, new = 99
        assertEq(after_, 99 * 1e18, "1 week decay");
    }

    function test_decayMultipleWeeks() public {
        uint256 before = state.score;
        uint256 lastActivity = state.lastActivity;

        // Advance 30 + 4 weeks = 58 days
        vm.warp(block.timestamp + 30 days + 4 weeks);
        uint256 after_ = ReputationLib.applyDecay(before, lastActivity);

        // Iterative: 100 -> 99 -> 98.01 -> 97.0299 -> 96.0596
        // Should be ~96.06
        assertApproxEqRel(after_, 96.06 * 1e18, 0.01e18, "4 weeks decay");
    }
}
