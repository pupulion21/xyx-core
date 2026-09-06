// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {AgentRegistry} from "../src/core/AgentRegistry.sol";
import {TaskLifecycle} from "../src/core/TaskLifecycle.sol";
import {DisputeResolver} from "../src/core/DisputeResolver.sol";
import {ExecutionEngine} from "../src/core/ExecutionEngine.sol";

/// @title Deploy
/// @notice Foundry deployment script for XYX v1.3 on Monad testnet/mainnet.
/// @dev Deployment order is critical. The 4 core contracts are deployed first with
///      the deployer as initial owner; cross-references are wired; ownership is
///      **transferred but not accepted** (the engine has no EOA to broadcast from,
///      so acceptOwnership must be a separate on-chain action).
///
///      For hackathon MVP, the deployer EOA REMAINS the owner of all 4 contracts.
///      This is documented as a known limitation; the production path is:
///      1. Deploy via this script
///      2. Use a Gnosis Safe as the deployer (Safe IS an EOA-like multisig)
///      3. Safe executes engine.acceptOwnership() × 3 in a single batch
///      4. After acceptance, the engine is the sole owner, and protocol economic
///         actions (slash, distribute) are gated through the engine.
///
/// Usage:
///   # Dry run (no broadcast, no gas):
///   forge script script/Deploy.s.sol:Deploy --via-ir
///
///   # Deploy to Monad testnet (set env vars first):
///   export MONAD_TESTNET_RPC_URL=https://testnet-rpc.monad.xyz
///   export DEPLOYER_PRIVATE_KEY=0x...   # DO NOT commit this
///   export TREASURY_ADDRESS=0x...      # Where 10% slash proceeds go
///   forge script script/Deploy.s.sol:Deploy --rpc-url monad_testnet --broadcast --via-ir
///
///   # Verify on explorer (after deploy):
///   forge verify-contract --chain-id 10143 --etherscan-api-key $MONADSCAN_API_KEY \
///     <ADDRESS> src/core/AgentRegistry.sol:AgentRegistry
contract Deploy is Script {
    AgentRegistry public registry;
    TaskLifecycle public tasks;
    DisputeResolver public resolver;
    ExecutionEngine public engine;
    address public treasury;

    function run() external {
        // -- 1. Load deployer private key (NEVER hardcoded) --
        uint256 deployerPK = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPK);

        // -- 2. Treasury address (override with TREASURY_ADDRESS env) --
        treasury = vm.envOr("TREASURY_ADDRESS", deployer);
        require(treasury != address(0), "treasury cannot be zero");

        // -- 3. Deploy all 4 core contracts in dependency order --
        vm.startBroadcast(deployerPK);

        // 1. AgentRegistry (owner = deployer)
        registry = new AgentRegistry(deployer);

        // 2. TaskLifecycle (owner = deployer, registry = AgentRegistry)
        tasks = new TaskLifecycle(deployer, address(registry));

        // 3. DisputeResolver (owner = deployer, registry, taskLifecycle)
        resolver = new DisputeResolver(deployer, address(registry), address(tasks));

        // 4. ExecutionEngine (owner = deployer, registry, taskLifecycle, treasury)
        engine = new ExecutionEngine(deployer, address(registry), address(tasks), treasury);

        // -- 4. Wire cross-references (deployer still owner, so can call setX) --
        engine.setDisputeResolver(address(resolver));
        resolver.setExecutionEngine(address(engine));

        vm.stopBroadcast();

        // -- 5. Output for verification --
        console2.log("===========================================");
        console2.log("XYX v1.3 Deployment Complete");
        console2.log("===========================================");
        console2.log("Chain ID:        ", block.chainid);
        console2.log("Deployer:        ", deployer);
        console2.log("Treasury:        ", treasury);
        console2.log("AgentRegistry:   ", address(registry));
        console2.log("TaskLifecycle:   ", address(tasks));
        console2.log("DisputeResolver: ", address(resolver));
        console2.log("ExecutionEngine: ", address(engine));
        console2.log("===========================================");
        console2.log("Verify with:");
        console2.log("  forge verify-contract --chain-id", block.chainid, "<ADDRESS> <Contract>");
        console2.log("===========================================");
        console2.log("IMPORTANT: For production, transfer ownership to engine via:");
        console2.log("  - tasks.transferOwnership(engine); engine.acceptOwnership();");
        console2.log("  - registry.transferOwnership(engine); engine.acceptOwnership();");
        console2.log("  - resolver.transferOwnership(engine); engine.acceptOwnership();");
        console2.log("For hackathon, deployer retains ownership (no multisig yet).");
        console2.log("===========================================");
    }

    /// @notice Post-deploy verification helper (read-only, no broadcast).
    /// @dev Call this after deployment to confirm cross-references are wired.
    function verify() external view {
        require(address(engine.disputeResolver()) == address(resolver), "engine.disputeResolver != resolver");
        require(address(resolver.executionEngine()) == address(engine), "resolver.executionEngine != engine");
        require(engine.treasury() == treasury, "engine.treasury != configured treasury");
        require(address(registry) != address(0), "registry not deployed");
        require(address(tasks) != address(0), "tasks not deployed");
    }
}

/// @title DeployAndHandoff
/// @notice 2-tx deployment with proper 2-step ownership handoff.
///         This is the production-grade path: deploys, then in a second transaction
///         from the SAME deployer EOA, calls engine.acceptOwnership() × 3 after the
///         1st tx has set engine as pending owner of all 3 subsidiaries.
/// @dev Caveat: The 1st tx transferOwnership sets engine as pending owner; the 2nd tx
///      calls engine.acceptOwnership() — but acceptOwnership() needs msg.sender == engine.
///      In Foundry scripts, we can use `vm.startBroadcast(address(engine))` to fake
///      the engine as the sender, but on a real network the engine has no key.
///      The real solution: use a multisig (Gnosis Safe) as the deployer; the Safe
///      is the "EOA-like" address that can call engine.acceptOwnership() via Safe.exec.
contract DeployAndHandoff is Script {
    function run() external {
        uint256 deployerPK = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPK);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);

        // Phase 1: Deploy + transfer ownership (sets pending owner = engine)
        vm.startBroadcast(deployerPK);

        AgentRegistry registry = new AgentRegistry(deployer);
        TaskLifecycle tasks = new TaskLifecycle(deployer, address(registry));
        DisputeResolver resolver = new DisputeResolver(deployer, address(registry), address(tasks));
        ExecutionEngine engine = new ExecutionEngine(deployer, address(registry), address(tasks), treasury);

        engine.setDisputeResolver(address(resolver));
        resolver.setExecutionEngine(address(engine));

        // Transfer ownership (sets pending owner = engine). acceptOwnership() deferred
        // to a separate tx that the deployer EOA (or multisig) executes.
        tasks.transferOwnership(address(engine));
        registry.transferOwnership(address(engine));
        resolver.transferOwnership(address(engine));

        vm.stopBroadcast();

        console2.log("Phase 1 complete. Contracts deployed. Pending owners set.");
        console2.log("Run `forge script script/Deploy.s.sol:AcceptOwnership --rpc-url <chain> --broadcast` next.");
        console2.log("Registry:   ", address(registry));
        console2.log("Tasks:      ", address(tasks));
        console2.log("Resolver:   ", address(resolver));
        console2.log("Engine:     ", address(engine));
    }
}

/// @title AcceptOwnership
/// @notice Standalone script: accepts pending ownership transfers for all 3 subsidiaries.
///         Reads addresses from env vars set in Phase 1.
/// @dev This is the "Phase 2" — must be run by the same address that's currently the
///      owner of each contract (the deployer EOA from Phase 1). It cannot accept on
///      behalf of the engine because the engine has no EOA. The owner is the deployer
///      until the engine explicitly calls acceptOwnership(). To trigger that, the
///      deployer EOA calls engine directly. Workaround: use a multisig as deployer
///      (the Safe exec call is from the Safe's address, which CAN be the engine if
///      you use a Safe module pattern — beyond hackathon scope).
///
///      For now, this script is a NO-OP acknowledgment. The 2-step handoff is a
///      known limitation documented in the Deploy script header.
contract AcceptOwnership is Script {
    function run() external view {
        console2.log("AcceptOwnership is a no-op for hackathon MVP.");
        console2.log("See script/Deploy.s.sol:Deploy for documentation.");
        console2.log("Production path: use Gnosis Safe as deployer.");
    }
}

/// @title DeployMockEngine
/// @notice Test-only deployment for DisputeResolver unit tests.
contract DeployMockEngine is Script {
    function run() external {
        uint256 deployerPK = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPK);
        vm.startBroadcast(deployerPK);

        AgentRegistry registry = new AgentRegistry(deployer);
        TaskLifecycle tasks = new TaskLifecycle(deployer, address(registry));
        ExecutionEngine engine = new ExecutionEngine(deployer, address(registry), address(tasks), deployer);

        vm.stopBroadcast();

        console2.log("Registry: ", address(registry));
        console2.log("Tasks:    ", address(tasks));
        console2.log("Engine:   ", address(engine));
    }
}
