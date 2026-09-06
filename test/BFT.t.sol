// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BFT} from "../src/libraries/BFT.sol";

contract BFTTest is Test {
    using BFT for BFT.Vote[];

    function _makeVote(address juror, BFT.VoteChoice choice, uint256 weight)
        internal
        pure
        returns (BFT.Vote memory)
    {
        return BFT.Vote({juror: juror, choice: choice, weight: weight, cast: true});
    }

    function test_unanimousSupport() public pure {
        BFT.Vote[] memory votes = new BFT.Vote[](5);
        votes[0] = _makeVote(address(1), BFT.VoteChoice.Support, 100);
        votes[1] = _makeVote(address(2), BFT.VoteChoice.Support, 100);
        votes[2] = _makeVote(address(3), BFT.VoteChoice.Support, 100);
        votes[3] = _makeVote(address(4), BFT.VoteChoice.Support, 100);
        votes[4] = _makeVote(address(5), BFT.VoteChoice.Support, 100);

        BFT.Resolution memory res = BFT.resolve(votes);
        assertTrue(res.winnerSupport, "Support wins");
        assertFalse(res.inconclusive, "Not inconclusive");
        assertEq(res.totalWeightSupport, 500, "Total support weight");
        assertEq(res.outliers.length, 0, "No outliers for unanimous");
    }

    function test_unanimousAgainst() public pure {
        BFT.Vote[] memory votes = new BFT.Vote[](5);
        for (uint256 i = 0; i < 5; i++) {
            votes[i] = _makeVote(address(uint160(i + 1)), BFT.VoteChoice.Against, 100);
        }

        BFT.Resolution memory res = BFT.resolve(votes);
        assertFalse(res.winnerSupport, "Against wins");
        assertFalse(res.inconclusive, "Not inconclusive");
        assertEq(res.totalWeightAgainst, 500);
    }

    function test_majoritySupportWithOutliers() public pure {
        BFT.Vote[] memory votes = new BFT.Vote[](5);
        // 3 Support, 2 Against (outliers)
        votes[0] = _makeVote(address(1), BFT.VoteChoice.Support, 100);
        votes[1] = _makeVote(address(2), BFT.VoteChoice.Support, 100);
        votes[2] = _makeVote(address(3), BFT.VoteChoice.Support, 100);
        votes[3] = _makeVote(address(4), BFT.VoteChoice.Against, 100);
        votes[4] = _makeVote(address(5), BFT.VoteChoice.Against, 100);

        BFT.Resolution memory res = BFT.resolve(votes);
        assertTrue(res.winnerSupport, "Support wins by majority");
        assertFalse(res.inconclusive, "Not inconclusive");
        assertEq(res.outliers.length, 2, "2 outliers detected");
    }

    function test_majorityAgainstWithOutliers() public pure {
        BFT.Vote[] memory votes = new BFT.Vote[](5);
        votes[0] = _makeVote(address(1), BFT.VoteChoice.Against, 100);
        votes[1] = _makeVote(address(2), BFT.VoteChoice.Against, 100);
        votes[2] = _makeVote(address(3), BFT.VoteChoice.Against, 100);
        votes[3] = _makeVote(address(4), BFT.VoteChoice.Support, 100);
        votes[4] = _makeVote(address(5), BFT.VoteChoice.Support, 100);

        BFT.Resolution memory res = BFT.resolve(votes);
        assertFalse(res.winnerSupport, "Against wins");
        assertEq(res.outliers.length, 2);
    }

    function test_allAbstainInconclusive() public pure {
        BFT.Vote[] memory votes = new BFT.Vote[](5);
        for (uint256 i = 0; i < 5; i++) {
            votes[i] = _makeVote(address(uint160(i + 1)), BFT.VoteChoice.Abstain, 100);
        }

        BFT.Resolution memory res = BFT.resolve(votes);
        assertTrue(res.inconclusive, "All abstain is inconclusive");
    }

    function test_threeWaySplitInconclusive() public pure {
        BFT.Vote[] memory votes = new BFT.Vote[](5);
        votes[0] = _makeVote(address(1), BFT.VoteChoice.Support, 100);
        votes[1] = _makeVote(address(2), BFT.VoteChoice.Support, 100);
        votes[2] = _makeVote(address(3), BFT.VoteChoice.Against, 100);
        votes[3] = _makeVote(address(4), BFT.VoteChoice.Abstain, 100);
        votes[4] = _makeVote(address(5), BFT.VoteChoice.Abstain, 100);

        BFT.Resolution memory res = BFT.resolve(votes);
        assertTrue(res.inconclusive, "3-way split is inconclusive");
    }

    function test_referenceJurorSelected() public pure {
        BFT.Vote[] memory votes = new BFT.Vote[](5);
        votes[0] = _makeVote(address(1), BFT.VoteChoice.Support, 100);
        votes[1] = _makeVote(address(2), BFT.VoteChoice.Support, 100);
        votes[2] = _makeVote(address(3), BFT.VoteChoice.Support, 100);
        votes[3] = _makeVote(address(4), BFT.VoteChoice.Against, 100);
        votes[4] = _makeVote(address(5), BFT.VoteChoice.Against, 100);

        BFT.Resolution memory res = BFT.resolve(votes);
        // Reference should be one of the Support voters (j1, j2, or j3)
        assertTrue(
            res.referenceJuror == address(1) || res.referenceJuror == address(2) || res.referenceJuror == address(3),
            "Reference is from majority"
        );
    }

    function test_weightSumCorrect() public pure {
        BFT.Vote[] memory votes = new BFT.Vote[](5);
        votes[0] = _makeVote(address(1), BFT.VoteChoice.Support, 200);
        votes[1] = _makeVote(address(2), BFT.VoteChoice.Support, 150);
        votes[2] = _makeVote(address(3), BFT.VoteChoice.Support, 100);
        votes[3] = _makeVote(address(4), BFT.VoteChoice.Against, 300);
        votes[4] = _makeVote(address(5), BFT.VoteChoice.Against, 50);

        BFT.Resolution memory res = BFT.resolve(votes);
        assertEq(res.totalWeightSupport, 450, "Support weight sum");
        assertEq(res.totalWeightAgainst, 350, "Against weight sum");
    }
}
