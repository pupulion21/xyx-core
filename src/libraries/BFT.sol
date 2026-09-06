// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {XYXConstants} from "./XYXConstants.sol";

/// @title BFT (Byzantine Fault Tolerance)
/// @notice Krum algorithm implementation for aggregating juror votes
/// @dev Adapted for binary decisions (guilty/innocent).
///      Krum score = sum of k-smallest Hamming distances to other votes.
///      Reference = argmin(score). Outliers = votes with high distance to reference.
library BFT {
    // ============================================================================
    //                                  ERRORS
    // ============================================================================

    error NoVotes();
    error InvalidVote(VoteChoice choice);

    // ============================================================================
    //                                    TYPES
    // ============================================================================

    enum VoteChoice {
        Uncast, // 0 (not voted yet)
        Support, // 1 (agent is at fault / agrees with disputer)
        Against, // 2 (agent is innocent / disagrees with disputer)
        Abstain // 3 (explicitly abstained)
    }

    struct Vote {
        address juror; // Juror address
        VoteChoice choice; // Their vote
        uint256 weight; // Stake weight (1e18 fixed point)
        bool cast; // Has this juror cast?
    }

    struct Resolution {
        bool winnerSupport; // true = Support won, false = Against won
        bool inconclusive; // true = no consensus, refund
        address referenceJuror; // The reference juror (argmin Krum score)
        address[] outliers; // Jurors identified as outliers
        uint256 totalWeightSupport; // Sum of weights voting Support
        uint256 totalWeightAgainst; // Sum of weights voting Against
    }

    // ============================================================================
    //                                MAIN FUNCTION
    // ============================================================================

    /// @notice Resolve a dispute using Krum BFT algorithm
    /// @param votes Array of all juror votes. Uncast votes (not yet voted) and Abstain are treated
    ///        as non-votes and excluded from scoring. A tie on weight (Support == Against) is
    ///        marked inconclusive.
    /// @return Resolution The result of BFT aggregation
    function resolve(Vote[] memory votes) public pure returns (Resolution memory) {
        uint256 n = votes.length;
        if (n == 0) revert NoVotes();

        Resolution memory res;
        res.inconclusive = false;
        res.referenceJuror = address(0);
        res.outliers = new address[](0);

        // Step 1: Count totals (Uncast is neither support nor against nor abstain)
        uint256 supportCount = 0;
        uint256 againstCount = 0;
        uint256 abstainCount = 0;
        for (uint256 i = 0; i < n; i++) {
            VoteChoice c = votes[i].choice;
            if (c == VoteChoice.Uncast) continue; // skip silently
            if (c == VoteChoice.Support) supportCount++;
            else if (c == VoteChoice.Against) againstCount++;
            else if (c == VoteChoice.Abstain) abstainCount++;
            else revert InvalidVote(c);
        }

        // Step 2: Check for edge cases
        // 2a. All abstain / all uncast
        if (supportCount == 0 && againstCount == 0) {
            res.inconclusive = true;
            return res;
        }

        // 2b. Unanimous support
        if (supportCount == n) {
            res.winnerSupport = true;
            res.totalWeightSupport = _sumWeight(votes, VoteChoice.Support);
            return res;
        }

        // 2c. Unanimous against
        if (againstCount == n) {
            res.winnerSupport = false;
            res.totalWeightAgainst = _sumWeight(votes, VoteChoice.Against);
            return res;
        }

        // 2d. All three categories present (no clear majority)
        if (supportCount > 0 && againstCount > 0 && abstainCount > 0) {
            res.inconclusive = true;
            return res;
        }

        // 2e. Weight tie (Support == Against) — no clear majority
        uint256 supportWeight = _sumWeight(votes, VoteChoice.Support);
        uint256 againstWeight = _sumWeight(votes, VoteChoice.Against);
        if (supportWeight == againstWeight) {
            res.inconclusive = true;
            res.totalWeightSupport = supportWeight;
            res.totalWeightAgainst = againstWeight;
            return res;
        }

        // Step 3: Krum scoring (only on cast votes, ignoring Abstain AND Uncast)
        // We treat Support as 1, Against as 0 in Hamming distance
        uint256 k = XYXConstants.BFT_K; // n - 2 for n=5 → k=3

        uint256 bestScore = type(uint256).max;
        uint256 bestIdx = type(uint256).max;

        for (uint256 i = 0; i < n; i++) {
            if (votes[i].choice == VoteChoice.Abstain) continue;
            if (votes[i].choice == VoteChoice.Uncast) continue;

            // Compute k-smallest distances from vote i to all others
            uint256[] memory distances = new uint256[](n);
            uint256 distCount = 0;

            for (uint256 j = 0; j < n; j++) {
                if (i == j) continue;
                if (votes[j].choice == VoteChoice.Abstain) continue;
                if (votes[j].choice == VoteChoice.Uncast) continue;
                distances[distCount++] = _hamming(votes[i].choice, votes[j].choice);
            }

            // Sum k-smallest
            uint256 score = _sumKSmallest(distances, distCount, k);
            if (score < bestScore) {
                bestScore = score;
                bestIdx = i;
            }
        }

        if (bestIdx == type(uint256).max) {
            res.inconclusive = true;
            return res;
        }

        res.referenceJuror = votes[bestIdx].juror;
        res.winnerSupport = (votes[bestIdx].choice == VoteChoice.Support);

        // Step 4: Outlier detection (binary: outliers vote opposite of reference)
        for (uint256 i = 0; i < n; i++) {
            if (votes[i].juror == res.referenceJuror) continue;
            if (votes[i].choice == VoteChoice.Abstain) continue;
            if (votes[i].choice == VoteChoice.Uncast) continue;
            if (_hamming(votes[bestIdx].choice, votes[i].choice) > 0) {
                res.outliers = _appendAddress(res.outliers, votes[i].juror);
            }
        }

        // Step 5: PRD §FR-4.2 — if outliers exceed N/2, no clear majority → inconclusive.
        // Note: compares OUTLIER COUNT (not weight) per PRD spec. Weight-based tie
        // detection happens earlier in Step 2e.
        if (res.outliers.length > n / 2) {
            res.inconclusive = true;
            res.totalWeightSupport = supportWeight;
            res.totalWeightAgainst = againstWeight;
            return res;
        }

        // Step 6: Compute totals
        res.totalWeightSupport = supportWeight;
        res.totalWeightAgainst = againstWeight;

        return res;
    }

    // ============================================================================
    //                              HELPER FUNCTIONS
    // ============================================================================

    /// @notice Compute Hamming distance between two binary votes
    function _hamming(VoteChoice a, VoteChoice b) private pure returns (uint256) {
        // Treat Support as 1, Against as 0
        // Abstain shouldn't reach here but handle it
        if (a == VoteChoice.Abstain || b == VoteChoice.Abstain) return 0;
        return a == b ? 0 : 1;
    }

    /// @notice Sum the k smallest values in an array
    function _sumKSmallest(uint256[] memory arr, uint256 length, uint256 k) private pure returns (uint256) {
        if (k > length) k = length;

        // Simple O(k*n) selection - acceptable for n=5, k=3
        uint256 sum = 0;
        bool[] memory used = new bool[](length);

        for (uint256 i = 0; i < k; i++) {
            uint256 minVal = type(uint256).max;
            uint256 minIdx = type(uint256).max;
            for (uint256 j = 0; j < length; j++) {
                if (!used[j] && arr[j] < minVal) {
                    minVal = arr[j];
                    minIdx = j;
                }
            }
            if (minIdx != type(uint256).max) {
                used[minIdx] = true;
                sum += minVal;
            }
        }
        return sum;
    }

    /// @notice Sum weights of votes matching a choice
    function _sumWeight(Vote[] memory votes, VoteChoice choice) private pure returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < votes.length; i++) {
            if (votes[i].choice == choice) {
                total += votes[i].weight;
            }
        }
        return total;
    }

    /// @notice Append an address to a dynamic array
    function _appendAddress(address[] memory arr, address addr) private pure returns (address[] memory) {
        address[] memory newArr = new address[](arr.length + 1);
        for (uint256 i = 0; i < arr.length; i++) {
            newArr[i] = arr[i];
        }
        newArr[arr.length] = addr;
        return newArr;
    }
}
