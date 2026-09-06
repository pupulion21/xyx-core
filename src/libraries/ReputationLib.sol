// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {XYXConstants} from "./XYXConstants.sol";

/// @title ReputationLib
/// @notice Reputation scoring system for XYX agents and jurors
/// @dev Reputation is a fixed-point number (1e18 decimals) bounded [0, 200e18].
///      Tier system: Low (0-50), Medium (51-100), High (101-150), Elite (151-200).
///      Decay: 30 days no decay, then 1% per week, floor at MIN_REPUTATION.
library ReputationLib {
    // ============================================================================
    //                                    TYPES
    // ============================================================================

    enum Tier {
        None, // 0 (reputation = 0)
        Low, // 1 (0 < rep ≤ 50)
        Medium, // 2 (50 < rep ≤ 100)
        High, // 3 (100 < rep ≤ 150)
        Elite // 4 (150 < rep ≤ 200)
    }

    struct State {
        uint256 score; // Current reputation (1e18 fixed point)
        uint64 lastUpdate; // Last update timestamp
        uint64 lastActivity; // Last on-chain activity
        uint16 tasksCompleted; // Lifetime tasks
        uint16 tasksFailed; // Lifetime failures
        uint16 disputesWon;
        uint16 disputesLost;
    }

    // ============================================================================
    //                                 CONSTANTS
    // ============================================================================

    // Tier thresholds (in 1e18 units)
    uint256 internal constant TIER_LOW_MAX = 50 * 1e18;
    uint256 internal constant TIER_MEDIUM_MAX = 100 * 1e18;
    uint256 internal constant TIER_HIGH_MAX = 150 * 1e18;
    uint256 internal constant TIER_ELITE_MIN = 150 * 1e18;

    // Reputation deltas
    int256 internal constant DELTA_TASK_SUCCESS = 5 * 1e18;
    int256 internal constant DELTA_TASK_FAILED = 10 * 1e18;
    int256 internal constant DELTA_DISPUTE_WON = 10 * 1e18;
    int256 internal constant DELTA_DISPUTE_LOST = 20 * 1e18;
    int256 internal constant DELTA_FINAL_STRIKE = 50 * 1e18; // unregister during task
    int256 internal constant DELTA_TASK_TIMEOUT = 5 * 1e18;

    // Tier multipliers (basis points of stake weight)
    uint256 internal constant TIER_LOW_MULTIPLIER = 100; // 1.0x
    uint256 internal constant TIER_MEDIUM_MULTIPLIER = 150; // 1.5x
    uint256 internal constant TIER_HIGH_MULTIPLIER = 200; // 2.0x
    uint256 internal constant TIER_ELITE_MULTIPLIER = 300; // 3.0x

    // ============================================================================
    //                                PURE FUNCTIONS
    // ============================================================================

    /// @notice Get the tier for a given reputation score
    function getTier(uint256 reputation) internal pure returns (Tier) {
        if (reputation == 0) return Tier.None;
        if (reputation <= TIER_LOW_MAX) return Tier.Low;
        if (reputation <= TIER_MEDIUM_MAX) return Tier.Medium;
        if (reputation <= TIER_HIGH_MAX) return Tier.High;
        return Tier.Elite;
    }

    /// @notice Get the vote weight multiplier for a tier
    function getMultiplier(Tier tier) internal pure returns (uint256) {
        if (tier == Tier.Low) return TIER_LOW_MULTIPLIER;
        if (tier == Tier.Medium) return TIER_MEDIUM_MULTIPLIER;
        if (tier == Tier.High) return TIER_HIGH_MULTIPLIER;
        if (tier == Tier.Elite) return TIER_ELITE_MULTIPLIER;
        return 0; // Tier.None
    }

    /// @notice Apply time-based decay to a reputation score
    /// @param currentRep Current reputation (1e18 fixed point)
    /// @param lastActivityTs Last activity timestamp
    /// @return New reputation after decay
    function applyDecay(uint256 currentRep, uint256 lastActivityTs) internal view returns (uint256) {
        if (currentRep == 0) return 0;
        if (block.timestamp < lastActivityTs + XYXConstants.REPUTATION_GRACE_PERIOD) {
            return currentRep; // Still in grace period
        }

        // Calculate weeks elapsed since grace period ended
        uint256 decayStart = lastActivityTs + XYXConstants.REPUTATION_GRACE_PERIOD;
        uint256 elapsed = block.timestamp - decayStart;
        uint256 weekCount = elapsed / 1 weeks;

        if (weekCount == 0) return currentRep;

        // Apply decay: rep = rep * (1 - decayBps/10000)^weeks
        // Iterative: each week, multiply by (1 - decayRate)
        uint256 newRep = currentRep;
        for (uint256 i = 0; i < weekCount && newRep > 0; i++) {
            uint256 decayAmount = (newRep * XYXConstants.REPUTATION_DECAY_BPS) / XYXConstants.BPS_DENOMINATOR;
            if (decayAmount == 0) break; // Too small to decay further
            unchecked {
                newRep -= decayAmount;
            }
        }

        return newRep;
    }

    // ============================================================================
    //                              STATE-MUTATING HELPERS
    // ============================================================================

    /// @notice Initialize a new reputation state
    function initialize() internal view returns (State memory) {
        return
            State({
                score: XYXConstants.INITIAL_REPUTATION,
                lastUpdate: uint64(block.timestamp),
                lastActivity: uint64(block.timestamp),
                tasksCompleted: 0,
                tasksFailed: 0,
                disputesWon: 0,
                disputesLost: 0
            });
    }

    /// @notice Record a successful task completion
    function onTaskSuccess(State storage self) internal {
        self.score = _applyDelta(self.score, DELTA_TASK_SUCCESS);
        self.lastUpdate = uint64(block.timestamp);
        self.lastActivity = uint64(block.timestamp);
        unchecked {
            self.tasksCompleted += 1;
        }
    }

    /// @notice Record a task failure
    function onTaskFailed(State storage self) internal {
        self.score = _applyDelta(self.score, -DELTA_TASK_FAILED);
        self.lastUpdate = uint64(block.timestamp);
        self.lastActivity = uint64(block.timestamp);
        unchecked {
            self.tasksFailed += 1;
        }
    }

    /// @notice Record a dispute win
    function onDisputeWon(State storage self) internal {
        self.score = _applyDelta(self.score, DELTA_DISPUTE_WON);
        self.lastUpdate = uint64(block.timestamp);
        self.lastActivity = uint64(block.timestamp);
        unchecked {
            self.disputesWon += 1;
        }
    }

    /// @notice Record a dispute loss
    function onDisputeLost(State storage self) internal {
        self.score = _applyDelta(self.score, -DELTA_DISPUTE_LOST);
        self.lastUpdate = uint64(block.timestamp);
        self.lastActivity = uint64(block.timestamp);
        unchecked {
            self.disputesLost += 1;
        }
    }

    /// @notice Record a final strike (e.g., unregister during task)
    function onFinalStrike(State storage self) internal {
        self.score = _applyDelta(self.score, -DELTA_FINAL_STRIKE);
        self.lastUpdate = uint64(block.timestamp);
        self.lastActivity = uint64(block.timestamp);
    }

    /// @notice Record a task timeout
    function onTaskTimeout(State storage self) internal {
        self.score = _applyDelta(self.score, -DELTA_TASK_TIMEOUT);
        self.lastUpdate = uint64(block.timestamp);
        self.lastActivity = uint64(block.timestamp);
    }

    /// @notice Update last activity timestamp (for decay calculations)
    function touchActivity(State storage self) internal {
        self.lastActivity = uint64(block.timestamp);
    }

    // ============================================================================
    //                                INTERNAL
    // ============================================================================

    /// @dev Apply a reputation delta with bounds checking
    function _applyDelta(uint256 currentRep, int256 delta) private pure returns (uint256) {
        if (delta >= 0) {
            uint256 increase = uint256(delta);
            uint256 newRep = currentRep + increase;
            return newRep > XYXConstants.MAX_REPUTATION ? XYXConstants.MAX_REPUTATION : newRep;
        } else {
            uint256 decrease = uint256(-delta);
            if (decrease >= currentRep) return XYXConstants.MIN_REPUTATION;
            unchecked {
                return currentRep - decrease;
            }
        }
    }
}
