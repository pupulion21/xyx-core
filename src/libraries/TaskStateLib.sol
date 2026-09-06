// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TaskStateLib
/// @notice State machine for A2A task lifecycle per PRD §FR-2.1
/// @dev Implements 7-state machine:
///      submitted → working → (input-required ↔ working) → completed | failed | canceled | disputed
library TaskStateLib {
    // ============================================================================
    //                                    TYPES
    // ============================================================================

    enum State {
        None, // 0 — slot unused
        Submitted, // 1 — created, waiting for first participant action
        Working, // 2 — at least one participant has engaged
        InputRequired, // 3 — participant asked question, waiting for response
        Completed, // 4 — initiator accepted result
        Failed, // 5 — task failed (timeout, slash, etc.)
        Canceled, // 6 — initiator canceled
        Disputed // 7 — disagreement triggered, in BFT resolution
    }

    /// @notice A2A message envelope (PRD §FR-2.3)
    /// @dev `contentHash` = keccak256 of the message bytes (EIP-712 typed data or JSON-RPC).
    ///      `refUri` = IPFS CID or HTTP URL for full payload retrieval.
    struct Message {
        address sender;
        uint64 timestamp;
        bytes32 contentHash;
        string refUri;
    }

    // ============================================================================
    //                                 CONSTANTS
    // ============================================================================

    /// @notice Terminal states (no further transitions)
    bool internal constant _TERMINAL_COMPLETED = true;
    bool internal constant _TERMINAL_FAILED = true;
    bool internal constant _TERMINAL_CANCELED = true;

    // ============================================================================
    //                                 ERRORS
    // ============================================================================

    error InvalidStateTransition(State from, State to);
    error TaskNotInState(uint256 taskId, State expected, State actual);

    // ============================================================================
    //                              PURE FUNCTIONS
    // ============================================================================

    /// @notice Check if a transition is legal
    /// @dev Legal transitions:
    ///      Submitted → Working, Canceled, Disputed
    ///      Working → InputRequired, Completed, Failed, Disputed
    ///      InputRequired → Working, Canceled, Disputed
    ///      Completed → Disputed (post-completion dispute window)
    ///      Failed/Canceled/Disputed → terminal (no further transitions)
    function isLegalTransition(State from, State to) internal pure returns (bool) {
        if (from == State.Submitted) {
            return to == State.Working || to == State.Canceled || to == State.Disputed;
        }
        if (from == State.Working) {
            return to == State.InputRequired
                || to == State.Completed
                || to == State.Failed
                || to == State.Disputed;
        }
        if (from == State.InputRequired) {
            return to == State.Working || to == State.Canceled || to == State.Disputed;
        }
        if (from == State.Completed) {
            return to == State.Disputed;
        }
        // Failed, Canceled, Disputed are terminal
        return false;
    }

    /// @notice Revert if transition is illegal
    function requireTransition(State from, State to) internal pure {
        if (!isLegalTransition(from, to)) {
            revert InvalidStateTransition(from, to);
        }
    }

    /// @notice Check if state is terminal (no further transitions allowed)
    function isTerminal(State s) internal pure returns (bool) {
        return s == State.Completed
            || s == State.Failed
            || s == State.Canceled
            || s == State.Disputed;
    }

    /// @notice Check if state is "active" (can receive messages or transitions)
    function isActive(State s) internal pure returns (bool) {
        return s == State.Submitted
            || s == State.Working
            || s == State.InputRequired;
    }

    /// @notice Validate a state value (reverts if invalid)
    function requireValidState(State s) internal pure {
        if (uint256(s) > uint256(State.Disputed)) {
            // Out of range — but Solidity enums prevent this at type level
            revert InvalidStateTransition(s, State.None);
        }
    }
}
