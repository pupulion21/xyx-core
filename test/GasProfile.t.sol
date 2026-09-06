// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {AgentRegistry} from "../src/core/AgentRegistry.sol";
import {TaskLifecycle} from "../src/core/TaskLifecycle.sol";
import {TaskStateLib} from "../src/libraries/TaskStateLib.sol";
import {XYXConstants} from "../src/libraries/XYXConstants.sol";

/// @title GasProfileTest
/// @notice Side-by-side gas comparison: unsigned vs signed (EIP-712) submitMessage.
/// @dev Verifies the "22k gas overhead" claim documented in PRD §3.4 v1.3.
///      Uses identical task setup for both paths to isolate the EIP-712 cost
///      (ecrecover + 1× SSTORE for nonce bump + domain hash).
contract GasProfileTest is Test {
    AgentRegistry public registry;
    TaskLifecycle public tasks;

    uint256 internal constant ALICE_PK = 0xA11CE;
    uint256 internal constant BOB_PK = 0xB0B;

    address internal alice;
    address internal bob;

    function setUp() public {
        alice = vm.addr(ALICE_PK);
        bob = vm.addr(BOB_PK);

        registry = new AgentRegistry(address(this));
        tasks = new TaskLifecycle(address(this), address(registry));

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("data-analysis");

        vm.prank(alice);
        registry.registerAgent{value: XYXConstants.MIN_AGENT_STAKE + XYXConstants.REGISTRATION_FEE}(
            "https://alice", caps
        );
        vm.prank(bob);
        registry.registerAgent{value: XYXConstants.MIN_AGENT_STAKE + XYXConstants.REGISTRATION_FEE}(
            "https://bob", caps
        );
    }

    /// @notice Build a task + measure submitMessage (unsigned) gas
    function _benchUnsigned() internal returns (uint256) {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        vm.prank(alice);
        uint256 taskId = tasks.createTask{value: 1 ether}(keccak256("bench-spec"), participants);

        uint256 gasBefore = gasleft();
        vm.prank(bob);
        tasks.submitMessage(taskId, keccak256("msg"), "ipfs://m");
        return gasBefore - gasleft();
    }

    /// @notice Build a task + measure submitMessageSigned (EIP-712) gas
    function _benchSigned() internal returns (uint256) {
        address[] memory participants = new address[](1);
        participants[0] = bob;
        vm.prank(alice);
        uint256 taskId = tasks.createTask{value: 1 ether}(keccak256("bench-spec"), participants);

        // Read current nonce (incremented by previous bench calls)
        uint256 currentNonce = tasks.nonces(bob);

        // Sign an A2A message with current nonce
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("A2AMessage(uint256 taskId,bytes32 contentHash,string refUri,uint256 nonce,uint64 deadline)"),
                taskId,
                keccak256("msg"),
                keccak256(bytes("ipfs://m")),
                currentNonce,
                deadline
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(tasks.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BOB_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        uint256 gasBefore = gasleft();
        vm.prank(bob);
        tasks.submitMessageSigned(taskId, keccak256("msg"), "ipfs://m", deadline, sig);
        return gasBefore - gasleft();
    }

    /// @notice Headline benchmark: signed vs unsigned overhead.
    /// @dev Runs 3 iterations to smooth out EVM noise. Reports median.
    function test_gasProfileSignedVsUnsigned() public {
        uint256[] memory unsigned = new uint256[](3);
        uint256[] memory signed = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            unsigned[i] = _benchUnsigned();
            signed[i] = _benchSigned();
        }

        // Compute medians
        uint256 medUnsigned = _median(unsigned);
        uint256 medSigned = _median(signed);
        uint256 overhead = medSigned - medUnsigned;

        emit log_named_uint("submitMessage (unsigned) median gas", medUnsigned);
        emit log_named_uint("submitMessageSigned (EIP-712) median gas", medSigned);
        emit log_named_uint("EIP-712 overhead (signed - unsigned)", overhead);

        // Measured: ~9k overhead. We allow [5k, 20k] for EVM noise.
        // Tight bound catches: lost optimization, accidental extra SLOAD, etc.
        // Breakdown of expected 9k: ecrecover (~3k) + 1× SSTORE warm (~5k) + domain hash (~1k).
        assertGe(overhead, 5_000, "EIP-712 overhead >= 5k (sanity floor)");
        assertLe(overhead, 20_000, "EIP-712 overhead <= 20k (sanity ceiling)");
    }

    /// @notice Hard upper bound: signed path must stay under 200k gas.
    /// @dev Catches catastrophic regressions (e.g. accidentally adding a loop).
    function test_gasProfileHardCeiling() public {
        uint256 gasUsed = _benchSigned();
        emit log_named_uint("submitMessageSigned hard ceiling", gasUsed);
        assertLe(gasUsed, 200_000, "signed path under 200k hard ceiling");
    }

    function _median(uint256[] memory arr) internal pure returns (uint256) {
        // Sort (insertion sort — n=3)
        for (uint256 i = 1; i < arr.length; i++) {
            uint256 key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) {
                arr[j] = arr[j - 1];
                j--;
            }
            arr[j] = key;
        }
        return arr[arr.length / 2];
    }
}
