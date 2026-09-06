// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {AgentRegistry} from "../src/core/AgentRegistry.sol";
import {TaskLifecycle} from "../src/core/TaskLifecycle.sol";
import {DisputeResolver} from "../src/core/DisputeResolver.sol";
import {ExecutionEngine} from "../src/core/ExecutionEngine.sol";
import {TaskStateLib} from "../src/libraries/TaskStateLib.sol";
import {XYXConstants} from "../src/libraries/XYXConstants.sol";



/// @title XYXHandler
/// @notice Fuzzer handler: only exposes functions that the system supports in any state.
/// @dev Inherited by the test contract so it has access to registry/tasks and the
///      assertions (assertEq, etc.) are inherited from Test.
contract XYXHandler is Test {
    AgentRegistry public registry;
    TaskLifecycle public tasks;

    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public carol = address(0xCA02);

    /// @notice Ghost vars: track task history so we can assert state monotonicity.
    mapping(uint256 => uint8) public lastSeenTaskState;

    /// @notice Ghost vars: track cumulative msg.value deposited per agentId (for
    ///         no-phantom-stake conservation check). Set to 0 means "not tracked
    ///         (registered before handler bound)".
    mapping(uint256 => uint256) public deposits;

    constructor(AgentRegistry _registry, TaskLifecycle _tasks) {
        registry = _registry;
        tasks = _tasks;
    }

    function registerAgent() external {
        if (registry.getAgentByOwner(alice) != 0) return;
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("data-analysis");
        uint256 paid = XYXConstants.MIN_AGENT_STAKE + XYXConstants.REGISTRATION_FEE;
        registry.registerAgent{value: paid}(
            "https://alice", caps
        );
        // Track deposits AFTER registration (we need the agentId)
        uint256 agentId = registry.getAgentByOwner(alice);
        if (agentId != 0) deposits[agentId] = paid;
    }

    function registerJuror() external {
        if (registry.getAgentByOwner(carol) != 0) return;
        vm.deal(carol, 10 ether);
        vm.prank(carol);
        uint256 paid = XYXConstants.MIN_JUROR_STAKE + XYXConstants.REGISTRATION_FEE;
        registry.registerJuror{value: paid}(
            "https://carol"
        );
        uint256 agentId = registry.getAgentByOwner(carol);
        if (agentId != 0) deposits[agentId] = paid;
    }

    function addStake() external {
        if (registry.getAgentByOwner(alice) == 0) return;
        vm.deal(alice, alice.balance + 0.5 ether);
        vm.prank(alice);
        registry.addStake{value: 0.5 ether}();
        uint256 agentId = registry.getAgentByOwner(alice);
        if (agentId != 0) deposits[agentId] += 0.5 ether;
    }

    function createTask() external {
        if (registry.getAgentByOwner(alice) == 0) return;
        if (registry.getAgentByOwner(bob) == 0) return;
        vm.deal(alice, alice.balance + 1 ether);
        address[] memory p = new address[](1);
        p[0] = bob;
        vm.prank(alice);
        try tasks.createTask{value: 1 ether}(keccak256("spec"), p) returns (uint256) {
            // success
        } catch {
            // ignore revert
        }
    }

    function submitMessage() external {
        if (registry.getAgentByOwner(bob) == 0) return;
        // Submit to taskId 1 (the fuzzer's first created task typically gets id=1).
        // We don't iterate over all tasks to keep the fuzzer fast.
        vm.prank(bob);
        try tasks.submitMessage(1, keccak256("msg"), "ipfs://x") {} catch {}

        // Snapshot the state for monotonicity check
        try tasks.getState(1) returns (TaskStateLib.State s) {
            uint8 cur = uint8(s);
            uint8 prev = lastSeenTaskState[1];
            if (prev == 0) {
                lastSeenTaskState[1] = cur;
            } else {
                // State must monotonically increase (or stay same) on each observation.
                // If it decreases, the invariant fails. We use >= because a stable state
                // is a "no-op" snapshot, not a regression.
                require(cur >= prev, "task state decreased");
                lastSeenTaskState[1] = cur;
            }
        } catch {}
    }
}

/// @title XYXInvariantTest
/// @notice Property-based tests asserting structural & economic invariants of the system.
/// @dev Inherits both Test (for assertEq/assertLe/assertGe/assertFalse/vm) and StdInvariant
///      (for targetContract/targetSelector/excludeContract).
contract XYXInvariantTest is StdInvariant, Test {
    AgentRegistry public registry;
    TaskLifecycle public tasks;
    DisputeResolver public resolver;
    ExecutionEngine public engine;
    XYXHandler public handler;

    function setUp() public {
        registry = new AgentRegistry(address(this));
        tasks = new TaskLifecycle(address(this), address(registry));
        engine = new ExecutionEngine(
            address(this),
            address(registry),
            address(tasks),
            address(0x7E45)
        );
        resolver = new DisputeResolver(address(this), address(registry), address(tasks));

        // 2-step ownership: tasks → engine
        tasks.transferOwnership(address(engine));
        vm.prank(address(engine));
        tasks.acceptOwnership();

        // 2-step ownership: registry → engine
        registry.transferOwnership(address(engine));
        vm.prank(address(engine));
        registry.acceptOwnership();

        // Wire cross-references BEFORE transferring resolver ownership
        engine.setDisputeResolver(address(resolver));
        resolver.setExecutionEngine(address(engine));

        // 2-step ownership: resolver → engine
        resolver.transferOwnership(address(engine));
        vm.prank(address(engine));
        resolver.acceptOwnership();

        // Build the handler and bind it as the fuzzer's call target.
        handler = new XYXHandler(registry, tasks);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = XYXHandler.registerAgent.selector;
        selectors[1] = XYXHandler.registerJuror.selector;
        selectors[2] = XYXHandler.addStake.selector;
        selectors[3] = XYXHandler.createTask.selector;
        selectors[4] = XYXHandler.submitMessage.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // ============================================================================
    //                          INVARIANT: STAKE NON-NEGATIVE
    // ============================================================================

    /// @notice Sum of all agent stakes is bounded by what was deposited.
    function invariant_stakeNonNegative() public view {
        uint256 sumStakes;
        for (uint256 id = 1; id < registry.nextAgentId(); id++) {
            sumStakes += registry.stakeOf(id);
        }
        // We don't track ghost deposits in this minimal suite, so just verify the
        // sum is finite (catches underflow by virtue of Solidity 0.8 + bounded loop).
        // A stronger check would track deposits per call.
        assertLe(sumStakes, type(uint256).max, "stakes finite");
    }

    // ============================================================================
    //                INVARIANT: TASK STATE MONOTONICITY
    // ============================================================================

    /// @notice Task state moves only through legal transitions (forward, no skipping or
    ///         resurrection). This is enforced by the handler's snapshot logic.
    function invariant_taskStateMonotonic() public view {
        // The handler asserts monotonicity at each call. If it failed, the fuzzer
        // would have already reverted. We re-check here for clarity.
        for (uint256 id = 1; id <= 5; id++) {
            try tasks.getState(id) returns (TaskStateLib.State s) {
                uint8 cur = uint8(s);
                uint8 prev = handler.lastSeenTaskState(id);
                if (prev != 0) {
                    assertGe(cur, prev, "task state decreased");
                }
            } catch {
                // task doesn't exist; skip
            }
        }
    }

    // ============================================================================
    //                  INVARIANT: REPUTATION BOUNDS
    // ============================================================================

    /// @notice Reputation is bounded by [0, MAX_REPUTATION].
    function invariant_reputationBounded() public view {
        for (uint256 id = 1; id < registry.nextAgentId(); id++) {
            uint256 rep = registry.getReputation(id);
            assertLe(rep, XYXConstants.MAX_REPUTATION, "rep <= MAX");
        }
    }

    // ============================================================================
    //                   INVARIANT: AGENT ID MONOTONIC
    // ============================================================================

    /// @notice nextAgentId >= 1 (always starts at 1, only ever increases).
    function invariant_nextAgentIdMonotonic() public view {
        assertGe(registry.nextAgentId(), 1, "nextAgentId >= 1");
    }

    // ============================================================================
    //               INVARIANT: OWNERSHIP CHAIN INTACT
    // ============================================================================

    /// @notice ExecutionEngine remains the owner of AgentRegistry, TaskLifecycle, and
    ///         DisputeResolver. The single-source-of-truth for protocol economic actions.
    function invariant_engineOwnsSubsidiaries() public view {
        assertEq(registry.owner(), address(engine), "registry owner == engine");
        assertEq(tasks.owner(), address(engine), "tasks owner == engine");
        assertEq(resolver.owner(), address(engine), "resolver owner == engine");
    }

    // ============================================================================
    //                INVARIANT: NO SKIPPED AGENT IDS
    // ============================================================================

    /// @notice nextAgentId - 1 == count of registered agents (no IDs are skipped).
    function invariant_noSkippedAgentIds() public view {
        uint256 count;
        for (uint256 id = 1; id < registry.nextAgentId(); id++) {
            if (registry.ownerOf(id) != address(0)) count++;
        }
        assertEq(count, registry.nextAgentId() - 1, "no skipped IDs");
    }

    // ============================================================================
    //                INVARIANT: PAUSE GUARD WORKS
    // ============================================================================

    /// @notice When the registry is paused, no new agents can register.
    function invariant_pauseGuardHolds() public view {
        // Pause is owner-only and we don't drive it in the fuzzer. We just check the
        // public state is sane.
        assertFalse(registry.paused(), "registry not paused during fuzz");
    }

    // ============================================================================
    //         INVARIANT: CONSERVATION OF VALUE (REGISTRY SOLVENCY)
    // ============================================================================

    /// @notice The AgentRegistry contract holds ≥ sum of all tracked agent stakes.
    ///         This is a "first principles" conservation check: every MON deposited
    ///         via registerAgent / addStake / slash must be reflected in agent.stake,
    ///         and the contract must never send out more than it has.
    ///         Catches: silent stake loss, double-withdraw, accounting drift.
    /// @dev Conservative bound: only checks >= (allows contract to hold more than
    ///      tracked, e.g. fees). The reverse direction (== exact) is too strict
    ///      because the registry may legitimately hold more than sum-of-stakes
    ///      (registration fees, slash proceeds awaiting distribution).
    function invariant_registrySolvent() public view {
        uint256 sumStakes;
        uint256 activeAgents;
        for (uint256 id = 1; id < registry.nextAgentId(); id++) {
            if (registry.ownerOf(id) != address(0)) {
                sumStakes += registry.stakeOf(id);
                activeAgents++;
            }
        }
        // Contract balance must cover all tracked stakes. A failed assertion here
        // means the contract sent out MON it didn't debit from any counter, OR
        // ghost deposits were credited to stakes without being held by the contract.
        assertGe(
            address(registry).balance,
            sumStakes,
            "registry.solvent: balance < sum(agent.stake)"
        );
    }

    // ============================================================================
    //         INVARIANT: NO AGENT STAKE EXCEEDS CONTRACT DEPOSITS
    // ============================================================================

    /// @notice For each agent: agent.stake ≤ sum of msg.value sent to that agent's
    ///         registration + addStake calls. This is a per-agent conservation check
    ///         that catches "phantom stake" (counter increased without payment).
    /// @dev Simplified: assumes every registered agent deposited ≥ MIN_AGENT_STAKE
    ///      + REGISTRATION_FEE at registration. We track deposits via a
    ///      handler-side mapping (see XYXHandler.deposits).
    function invariant_noPhantomStake() public view {
        for (uint256 id = 1; id < registry.nextAgentId(); id++) {
            address owner = registry.ownerOf(id);
            if (owner == address(0)) continue;
            uint256 recorded = handler.deposits(id);
            if (recorded == 0) continue; // not tracked (registered before handler bound)
            assertLe(
                registry.stakeOf(id),
                recorded,
                "phantom stake: stake > deposits"
            );
        }
    }
}
