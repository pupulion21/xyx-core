# XYX Core — Smart Contracts

**XYX = "Expose, Yield, Execute"** — Coordination layer for the agent economy.

This is the on-chain foundation of the XYX protocol. Built for Monad Metropolis Hackathon (Track 4: Trust, Identity & AI Infrastructure).

## Stack

- **Solidity** 0.8.24
- **Foundry** (forge, cast, anvil)
- **OpenZeppelin** v5 (ReentrancyGuard, Pausable, Ownable)
- **Monad** testnet (Chain ID 10143)

## Architecture

```
src/
├── libraries/
│   ├── XYXConstants.sol       # All magic numbers (no state, no logic)
│   ├── ReputationLib.sol      # Reputation math + tier system
│   └── BFT.sol                # Krum BFT algorithm
└── core/
    └── AgentRegistry.sol      # Agent & juror registration (ERC-8004 compatible)

test/
├── XYXConstants.t.sol         # Constant values
├── ReputationLib.t.sol        # Reputation math
├── BFT.t.sol                  # BFT algorithm
└── AgentRegistry.t.sol        # Registration flow

Planned (Week 2-3):
├── TaskLifecycle.sol          # A2A task state machine
├── DisputeResolver.sol        # BFT aggregation + reward distribution
├── ExecutionEngine.sol        # Slash/reward mechanism
├── ZKVerifier.sol             # Proof validation (stub for now)
└── XYXCoordination.sol        # Main coordinator
```

## Quick Start

### 1. Install Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### 2. Install Dependencies

```bash
cd xyx-core
forge install foundry-rs/forge-std --no-commit
forge install OpenZeppelin/openzeppelin-contracts --no-commit
```

### 3. Build

```bash
forge build
```

### 4. Test

```bash
# All tests
forge test

# Verbose
forge test -vv

# With gas report
forge test --gas-report

# Specific test
forge test --match-test test_slashReducesStake
```

### 5. Coverage

```bash
forge coverage
```

## Deploy to Monad Testnet

```bash
# Set env vars
export MONAD_TESTNET_RPC_URL="https://testnet-rpc.monad.xyz"
export PRIVATE_KEY="0x..."
export MONADSCAN_API_KEY="..."

# Deploy
forge create --rpc-url $MONAD_TESTNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  src/core/AgentRegistry.sol:AgentRegistry
```

## Status (Week 1)

- [x] Foundry setup
- [x] XYXConstants (all magic numbers)
- [x] ReputationLib (with tier system)
- [x] BFT (Krum implementation)
- [x] AgentRegistry (registration + stake management)
- [x] Test suite (60+ test cases)
- [ ] TaskLifecycle (next)
- [ ] DisputeResolver
- [ ] ZKVerifier stub
- [ ] XYXCoordination (main)

## License

MIT
