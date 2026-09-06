// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title XYXConstants
/// @notice Centralized system constants for XYX protocol
/// @dev All magic numbers live here. No state, no logic, pure constants.
///      Import this everywhere instead of hardcoding values.
library XYXConstants {
    // ============================================================================
    //                                STAKES (in wei)
    // ============================================================================

    /// @notice Minimum stake required to register as an agent (0.1 MON)
    uint256 internal constant MIN_AGENT_STAKE = 0.1 ether;

    /// @notice Minimum stake required to register as a juror (0.5 MON)
    uint256 internal constant MIN_JUROR_STAKE = 0.5 ether;

    /// @notice Period after unstake request before withdrawal is allowed
    uint256 internal constant UNBONDING_PERIOD = 7 days;

    // ============================================================================
    //                                   FEES
    // ============================================================================

    /// @notice Fee to register a new agent (0.001 MON)
    uint256 internal constant REGISTRATION_FEE = 0.001 ether;

    /// @notice Fee to create a task (0.0001 MON)
    uint256 internal constant TASK_CREATION_FEE = 0.0001 ether;

    /// @notice Fee to trigger a dispute (0.005 MON)
    uint256 internal constant DISPUTE_FEE = 0.005 ether;

    // ============================================================================
    //                              SLASHING (basis points: 10000 = 100%)
    // ============================================================================

    /// @notice Basis points of agent stake slashed on dispute loss (10% = 1000 bps)
    uint256 internal constant AGENT_SLASH_BPS = 1000;

    /// @notice Basis points of juror stake slashed for voting outlier (50% = 5000 bps)
    uint256 internal constant JUROR_OUTLIER_SLASH_BPS = 5000;

    /// @notice Basis points slashed for missed juror vote (20% = 2000 bps)
    uint256 internal constant JUROR_ABSTAIN_SLASH_BPS = 2000;

    /// @notice Basis points slashed for frivolous dispute (15% = 1500 bps)
    uint256 internal constant FRIVOLOUS_DISPUTE_SLASH_BPS = 1500;

    // ============================================================================
    //                            REWARD DISTRIBUTION (percent: sum to 100)
    // ============================================================================

    /// @notice Share of slash pool distributed to honest jurors (60%)
    uint256 internal constant JUROR_REWARD_SHARE = 60;

    /// @notice Share of slash pool to winning party (30%)
    uint256 internal constant WINNER_REWARD_SHARE = 30;

    /// @notice Share of slash pool to treasury (10%)
    uint256 internal constant TREASURY_SHARE = 10;

    uint256 internal constant BPS_DENOMINATOR = 10000;

    // ============================================================================
    //                                  TIMING
    // ============================================================================

    /// @notice Time window for disputing party to submit evidence
    uint256 internal constant EVIDENCE_DEADLINE = 24 hours;

    /// @notice Time window for jurors to cast votes
    uint256 internal constant VOTE_DEADLINE = 48 hours;

    /// @notice Maximum task execution time (7 days)
    uint256 internal constant MAX_TASK_DURATION = 7 days;

    /// @notice Maximum duration for emergency pause
    uint256 internal constant PAUSE_DURATION_MAX = 30 days;

    // ============================================================================
    //                                REPUTATION
    // ============================================================================

    /// @notice Reputation precision (1e18 for fixed-point math)
    uint256 internal constant REPUTATION_DECIMALS = 1e18;

    /// @notice Initial reputation when agent registers
    uint256 internal constant INITIAL_REPUTATION = 100 * 1e18;

    /// @notice Maximum reputation cap (200)
    uint256 internal constant MAX_REPUTATION = 200 * 1e18;

    /// @notice Minimum reputation floor (0, no negative)
    uint256 internal constant MIN_REPUTATION = 0;

    /// @notice Number of days with no decay before decay starts
    uint256 internal constant REPUTATION_GRACE_PERIOD = 30 days;

    /// @notice Weekly decay rate (1%)
    uint256 internal constant REPUTATION_DECAY_BPS = 100; // 1% in BPS

    // ============================================================================
    //                                 BFT (Byzantine Fault Tolerance)
    // ============================================================================

    /// @notice Number of jurors selected per dispute
    uint256 internal constant JURORS_PER_DISPUTE = 5;

    /// @notice k value for Krum algorithm (N - f - 2, where f = max Byzantine nodes).
    /// @dev PRD §FR-4.2: k = N - f - 2. With N=5, f=1 → k=2. Each juror sums the k=2 smallest
    ///      Hamming distances to all other jurors (excluding self).
    uint256 internal constant BFT_K = 2;

    /// @notice Maximum concurrent disputes a juror can handle
    uint256 internal constant MAX_CONCURRENT_DISPUTES_PER_JUROR = 3;

    // ============================================================================
    //                                RATE LIMITS
    // ============================================================================

    uint256 internal constant MAX_REGISTRATIONS_PER_DAY = 5;
    uint256 internal constant MAX_TASKS_PER_DAY = 20;
    uint256 internal constant MAX_DISPUTES_PER_DAY = 3;
    uint256 internal constant MAX_VOTES_PER_DAY = 50;

    // ============================================================================
    //                              TASK LIFECYCLE
    // ============================================================================

    /// @notice Maximum participants per task (PRD §FR-2.2)
    uint256 internal constant MAX_PARTICIPANTS_PER_TASK = 10;

    /// @notice Minimum jurors for a dispute (PRD §FR-3.2)
    uint256 internal constant MIN_JURORS_PER_DISPUTE = 3;

    /// @notice Maximum jurors for a dispute (PRD §FR-3.2)
    uint256 internal constant MAX_JURORS_PER_DISPUTE = 7;

    /// @notice Salt for juror selection randomness (domain separation)
    bytes32 internal constant JUROR_SEED_SALT = keccak256("xyx-juror-selection-v1");

    /// @notice Reward distribution denominator (for percentage math)
    uint256 internal constant REWARD_DISTRIBUTION_DENOM = 100;

    // ============================================================================
    //                          EIP-712 SIGNATURE LIMITS
    // ============================================================================

    /// @notice Maximum window for an A2A message signature to be valid (1 hour)
    uint256 internal constant A2A_SIGNATURE_DEADLINE = 1 hours;

    /// @notice Minimum session key duration (prevents spam delegations)
    uint256 internal constant MIN_SESSION_KEY_DURATION = 1 hours;

    /// @notice Maximum session key duration (30 days — bound compromise blast radius)
    uint256 internal constant MAX_SESSION_KEY_DURATION = 30 days;

    // ============================================================================
    //                                EMERGENCY
    // ============================================================================

    /// @notice Multi-sig threshold for emergency pause (3 of 5)
    uint256 internal constant EMERGENCY_MULTISIG_THRESHOLD = 3;
}
