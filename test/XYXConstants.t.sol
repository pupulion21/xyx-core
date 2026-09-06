// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {XYXConstants} from "../src/libraries/XYXConstants.sol";

contract XYXConstantsTest is Test {
    function test_stakeConstants() public pure {
        assertEq(XYXConstants.MIN_AGENT_STAKE, 0.1 ether, "MIN_AGENT_STAKE");
        assertEq(XYXConstants.MIN_JUROR_STAKE, 0.5 ether, "MIN_JUROR_STAKE");
        assertEq(XYXConstants.UNBONDING_PERIOD, 7 days, "UNBONDING_PERIOD");
    }

    function test_feeConstants() public pure {
        assertEq(XYXConstants.REGISTRATION_FEE, 0.001 ether, "REGISTRATION_FEE");
        assertEq(XYXConstants.TASK_CREATION_FEE, 0.0001 ether, "TASK_CREATION_FEE");
        assertEq(XYXConstants.DISPUTE_FEE, 0.005 ether, "DISPUTE_FEE");
    }

    function test_slashConstants() public pure {
        assertEq(XYXConstants.AGENT_SLASH_BPS, 1000, "AGENT_SLASH_BPS = 10%");
        assertEq(XYXConstants.JUROR_OUTLIER_SLASH_BPS, 5000, "JUROR_OUTLIER_SLASH = 50%");
    }

    function test_rewardDistribution() public pure {
        uint256 total = XYXConstants.JUROR_REWARD_SHARE + XYXConstants.WINNER_REWARD_SHARE
            + XYXConstants.TREASURY_SHARE;
        assertEq(total, 100, "Reward shares must sum to 100");
    }

    function test_bftConstants() public pure {
        assertEq(XYXConstants.JURORS_PER_DISPUTE, 5, "JURORS_PER_DISPUTE");
        // PRD §FR-4.2: k = N - f - 2. With N=5, f=1 (max Byzantine) → k=2.
        assertEq(XYXConstants.BFT_K, 2, "BFT_K = N-f-2 = 2 for N=5,f=1");
    }
}
