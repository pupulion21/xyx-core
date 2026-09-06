// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AgentRegistry} from "../src/core/AgentRegistry.sol";
import {XYXConstants} from "../src/libraries/XYXConstants.sol";

/// @title AgentRegistrySessionKeyTest
/// @notice Tests for PRD §3.3 D16: session key delegation
contract AgentRegistrySessionKeyTest is Test {
    AgentRegistry public registry;

    address alice = address(0xA11CE);
    address sessionKey = address(0xBEEF);

    uint256 aliceAgentId;

    function setUp() public {
        registry = new AgentRegistry(address(this));

        // Register Alice as agent
        vm.deal(alice, 10 ether);
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("data-analysis");
        vm.prank(alice);
        aliceAgentId = registry.registerAgent{value: XYXConstants.MIN_AGENT_STAKE + XYXConstants.REGISTRATION_FEE}(
            "https://alice", caps
        );
    }

    // ========================================================================
    //                              setSessionKey
    // ========================================================================

    function test_setSessionKey_valid() public {
        uint64 validUntil = uint64(block.timestamp + 1 days);

        vm.prank(alice);
        registry.setSessionKey(aliceAgentId, sessionKey, validUntil);

        (address storedKey, uint64 storedUntil, bool active) = registry.getSessionKey(aliceAgentId);
        assertEq(storedKey, sessionKey, "session key stored");
        assertEq(storedUntil, validUntil, "validUntil stored");
        assertTrue(active, "active flag set");

        // Reverse lookup works
        assertEq(registry.sessionKeyToAgentId(sessionKey), aliceAgentId, "reverse lookup");
    }

    function test_setSessionKey_rotatesPrevious() public {
        address firstKey = address(0xCAFE);
        address secondKey = address(0xBEEF);
        uint64 validUntil = uint64(block.timestamp + 1 days);

        vm.startPrank(alice);
        registry.setSessionKey(aliceAgentId, firstKey, validUntil);
        // Second call should revoke the first
        registry.setSessionKey(aliceAgentId, secondKey, validUntil);
        vm.stopPrank();

        (address storedKey,,) = registry.getSessionKey(aliceAgentId);
        assertEq(storedKey, secondKey, "rotated to second key");

        // Old key no longer maps to alice
        assertEq(registry.sessionKeyToAgentId(firstKey), 0, "old key removed from reverse map");
        // New key maps correctly
        assertEq(registry.sessionKeyToAgentId(secondKey), aliceAgentId, "new key in reverse map");
    }

    // ========================================================================
    //                       setSessionKey — error paths
    // ========================================================================

    function test_setSessionKey_notOwner_reverts() public {
        vm.prank(address(0xBAD)); // not the agent owner
        vm.expectRevert(
            abi.encodeWithSelector(AgentRegistry.NotAgentOwnerForSessionKey.selector, aliceAgentId, address(0xBAD))
        );
        registry.setSessionKey(aliceAgentId, sessionKey, uint64(block.timestamp + 1 days));
    }

    function test_setSessionKey_zeroKey_reverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.ZeroSessionKey.selector);
        registry.setSessionKey(aliceAgentId, address(0), uint64(block.timestamp + 1 days));
    }

    function test_setSessionKey_durationTooShort_reverts() public {
        uint64 tooSoon = uint64(block.timestamp + 30 minutes); // < MIN_SESSION_KEY_DURATION (1h)
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentRegistry.InvalidSessionKeyDuration.selector, 30 minutes, XYXConstants.MIN_SESSION_KEY_DURATION, XYXConstants.MAX_SESSION_KEY_DURATION
            )
        );
        registry.setSessionKey(aliceAgentId, sessionKey, tooSoon);
    }

    function test_setSessionKey_durationTooLong_reverts() public {
        uint64 tooFar = uint64(block.timestamp + 31 days); // > MAX_SESSION_KEY_DURATION (30d)
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentRegistry.InvalidSessionKeyDuration.selector, 31 days, XYXConstants.MIN_SESSION_KEY_DURATION, XYXConstants.MAX_SESSION_KEY_DURATION
            )
        );
        registry.setSessionKey(aliceAgentId, sessionKey, tooFar);
    }

    // ========================================================================
    //                              revokeSessionKey
    // ========================================================================

    function test_revokeSessionKey_valid() public {
        uint64 validUntil = uint64(block.timestamp + 1 days);
        vm.startPrank(alice);
        registry.setSessionKey(aliceAgentId, sessionKey, validUntil);
        registry.revokeSessionKey(aliceAgentId);
        vm.stopPrank();

        (address storedKey,, bool active) = registry.getSessionKey(aliceAgentId);
        assertEq(storedKey, address(0), "session key cleared");
        assertFalse(active, "active flag false");

        // Reverse lookup cleared
        assertEq(registry.sessionKeyToAgentId(sessionKey), 0, "reverse map cleared");
    }

    function test_revokeSessionKey_notOwner_reverts() public {
        // First set a key
        vm.prank(alice);
        registry.setSessionKey(aliceAgentId, sessionKey, uint64(block.timestamp + 1 days));

        // Then try to revoke from non-owner
        vm.prank(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(AgentRegistry.NotAgentOwnerForSessionKey.selector, aliceAgentId, address(0xBAD))
        );
        registry.revokeSessionKey(aliceAgentId);
    }

    function test_revokeSessionKey_noneExists_reverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AgentRegistry.NoSessionKeyToRevoke.selector, aliceAgentId)
        );
        registry.revokeSessionKey(aliceAgentId);
    }
}
