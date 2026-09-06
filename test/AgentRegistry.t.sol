// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AgentRegistry} from "../src/core/AgentRegistry.sol";
import {ReputationLib} from "../src/libraries/ReputationLib.sol";
import {XYXConstants} from "../src/libraries/XYXConstants.sol";

contract AgentRegistryTest is Test {
    AgentRegistry registry;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        registry = new AgentRegistry(address(this));
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function test_registerAgentSuccess() public {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("data-analysis");

        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 0.1 ether + 0.001 ether}(
            "https://api.alice-agent.xyz/a2a", caps
        );

        assertEq(agentId, 1, "First agent ID");
        assertEq(registry.getAgentByOwner(alice), 1, "Owner mapping");

        AgentRegistry.AgentCard memory agent = registry.getAgent(1);
        assertEq(agent.owner, alice);
        assertEq(agent.stake, 0.1 ether);
        assertTrue(agent.active);
        assertEq(uint256(agent.role), uint256(AgentRegistry.Role.Agent));
    }

    function test_registerJurorSuccess() public {
        vm.prank(alice);
        uint256 agentId = registry.registerJuror{value: 0.5 ether + 0.001 ether}("https://alice-juror.xyz/a2a");

        AgentRegistry.AgentCard memory juror = registry.getAgent(agentId);
        assertEq(uint256(juror.role), uint256(AgentRegistry.Role.Juror));
        assertEq(juror.stake, 0.5 ether);
    }

    function test_registerRejectsDoubleRegistration() public {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("code-review");

        vm.prank(alice);
        registry.registerAgent{value: 0.101 ether}("https://alice.xyz", caps);

        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AlreadyRegistered.selector, alice));
        vm.prank(alice);
        registry.registerAgent{value: 0.101 ether}("https://alice2.xyz", caps);
    }

    function test_registerRejectsInsufficientStake() public {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("test");

        vm.expectRevert(
            abi.encodeWithSelector(
                AgentRegistry.InsufficientStake.selector,
                XYXConstants.MIN_AGENT_STAKE + XYXConstants.REGISTRATION_FEE,
                0.05 ether
            )
        );
        vm.prank(alice);
        registry.registerAgent{value: 0.05 ether}("https://alice.xyz", caps);
    }

    function test_registerRejectsEmptyEndpoint() public {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("test");

        vm.expectRevert(AgentRegistry.InvalidEndpoint.selector);
        vm.prank(alice);
        registry.registerAgent{value: 0.101 ether}("", caps);
    }

    function test_registerRejectsEmptyCapabilities() public {
        bytes32[] memory caps = new bytes32[](0);

        vm.expectRevert(AgentRegistry.EmptyCapabilities.selector);
        vm.prank(alice);
        registry.registerAgent{value: 0.101 ether}("https://alice.xyz", caps);
    }

    function test_addStake() public {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("test");

        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 0.1 ether + 0.001 ether}("https://a.xyz", caps);

        vm.prank(alice);
        registry.addStake{value: 0.5 ether}();

        assertEq(registry.getAgent(agentId).stake, 0.6 ether, "Stake after add");
    }

    function test_requestUnstakeAndWithdraw() public {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("test");

        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 0.5 ether + 0.001 ether}("https://a.xyz", caps);

        uint256 balBefore = alice.balance;

        vm.prank(alice);
        registry.requestUnstake(0.3 ether);

        // Try to withdraw immediately (should fail)
        vm.expectRevert();
        vm.prank(alice);
        registry.withdrawUnstake();

        // Advance 7 days
        vm.warp(block.timestamp + 7 days);

        vm.prank(alice);
        registry.withdrawUnstake();

        assertEq(alice.balance, balBefore + 0.3 ether, "Should receive unstaked amount");
        assertEq(registry.getAgent(agentId).stake, 0.2 ether, "Remaining stake");
    }

    function test_slashReducesStake() public {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("test");

        // Register with 1 ether stake exactly (1 ether - 0.001 fee = 0.999)
        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 1 ether}("https://a.xyz", caps);

        // Stake is 0.999 (1 - 0.001 fee)
        uint256 initialStake = registry.getAgent(agentId).stake;
        assertEq(initialStake, 0.999 ether, "Initial stake after fee");

        // Owner is registry owner (this contract)
        uint256 slashAmount = registry.slash(agentId, 1000); // 10% in BPS

        // 10% of 0.999 = 0.0999
        assertEq(slashAmount, 0.0999 ether, "Slashed 10% of stake");
        assertEq(registry.getAgent(agentId).stake, 0.8991 ether, "Remaining stake");
        assertEq(registry.treasuryBalance(), 0.0999 ether + 0.001 ether, "Treasury = slash + fee");
    }

    function test_slashDeactivatesIfBelowMin() public {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("test");

        // Register with 0.1 + 0.001 ether (min stake + fee)
        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 0.101 ether}("https://a.xyz", caps);

        // Slash 100% to bring stake to 0
        registry.slash(agentId, 10000); // 10000 bps = 100%

        assertFalse(registry.getAgent(agentId).active, "Should be deactivated");
    }

    function test_reputationUpdates() public {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("test");

        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 0.1 ether + 0.001 ether}("https://a.xyz", caps);

        uint256 before = registry.getReputation(agentId);
        registry.updateReputation(agentId, true, false);
        assertEq(registry.getReputation(agentId), before + 5 * 1e18, "Task success +5");
    }

    function test_reputationFailure() public {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("test");

        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 0.1 ether + 0.001 ether}("https://a.xyz", caps);

        uint256 before = registry.getReputation(agentId);
        registry.updateReputation(agentId, false, false);
        assertEq(registry.getReputation(agentId), before - 10 * 1e18, "Task failed -10");
    }

    function test_reputationDisputeWin() public {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("test");

        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 0.1 ether + 0.001 ether}("https://a.xyz", caps);

        uint256 before = registry.getReputation(agentId);
        registry.updateReputation(agentId, true, true);
        assertEq(registry.getReputation(agentId), before + 10 * 1e18, "Dispute won +10");
    }

    function test_reputationDisputeLoss() public {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("test");

        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 0.1 ether + 0.001 ether}("https://a.xyz", caps);

        uint256 before = registry.getReputation(agentId);
        registry.updateReputation(agentId, false, true);
        assertEq(registry.getReputation(agentId), before - 20 * 1e18, "Dispute lost -20");
    }

    function test_tierTransitions() public {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("test");

        vm.prank(alice);
        uint256 agentId = registry.registerAgent{value: 0.1 ether + 0.001 ether}("https://a.xyz", caps);

        // Initial: Medium (100)
        assertEq(uint256(registry.getTier(agentId)), uint256(ReputationLib.Tier.Medium));

        // Gain to High (105)
        registry.updateReputation(agentId, true, false);
        assertEq(uint256(registry.getTier(agentId)), uint256(ReputationLib.Tier.High));

        // Lose back to Medium (105 - 10 = 95)
        registry.updateReputation(agentId, false, false);
        assertEq(uint256(registry.getTier(agentId)), uint256(ReputationLib.Tier.Medium));
    }

    function test_treasuryAccumulates() public {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("test");

        vm.prank(alice);
        registry.registerAgent{value: 0.1 ether + 0.001 ether}("https://a.xyz", caps);
        vm.prank(bob);
        registry.registerAgent{value: 0.1 ether + 0.001 ether}("https://b.xyz", caps);

        assertEq(registry.treasuryBalance(), 0.002 ether, "2 registration fees");
    }

    function test_findAgentsByCapability() public {
        bytes32[] memory aliceCaps = new bytes32[](1);
        aliceCaps[0] = keccak256("data-analysis");

        bytes32[] memory bobCaps = new bytes32[](2);
        bobCaps[0] = keccak256("data-analysis");
        bobCaps[1] = keccak256("code-review");

        vm.prank(alice);
        registry.registerAgent{value: 0.101 ether}("https://a.xyz", aliceCaps);
        vm.prank(bob);
        registry.registerAgent{value: 0.101 ether}("https://b.xyz", bobCaps);

        address[] memory dataAgents = registry.findAgentsByCapability(keccak256("data-analysis"));
        assertEq(dataAgents.length, 2, "2 agents with data-analysis");

        address[] memory codeAgents = registry.findAgentsByCapability(keccak256("code-review"));
        assertEq(codeAgents.length, 1, "1 agent with code-review");
    }

    function test_pauseBlocksRegistration() public {
        registry.pause();

        bytes32[] memory caps = new bytes32[](1);
        caps[0] = keccak256("test");

        vm.expectRevert();
        vm.prank(alice);
        registry.registerAgent{value: 0.101 ether}("https://a.xyz", caps);
    }
}
