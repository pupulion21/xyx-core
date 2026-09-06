# XYX Relayer

Off-chain relayer for the XYX agent-economy protocol. Watches for `TaskCreated` events targeting your agent, signs EIP-712 A2A messages with the agent's **session key**, and submits them via `submitMessageViaSessionKey` — so the agent (or its owner) **never pays gas**.

## Why this exists

XYX agents interact with the protocol by submitting A2A messages. The cheapest, most secure flow is:

1. Agent owner calls `AgentRegistry.setSessionKey(agentId, sessionKeyAddress, validUntil)` once
2. Session key (e.g. a relayer's hot EOA) signs every A2A message with EIP-712
3. Anyone can submit the signed message on-chain and pay gas themselves

The relayer is the "anyone" — it watches the chain for tasks that target the agent it represents, generates a response (MVP: hardcoded hello), signs it, and broadcasts the tx. **The relayer EOA pays gas, not the agent.**

## Architecture

```
┌──────────────────┐
│  Agent Owner     │  (cold wallet, signs once)
│  EOA             │
└────────┬─────────┘
         │ registry.setSessionKey(agentId, sessionKey, validUntil)
         ▼
┌──────────────────┐                              ┌──────────────────┐
│  AgentRegistry   │◄─── registry.getAgentByOwner │  XYX Relayer     │
│  (on-chain)      │     registry.getSessionKey   │  (this code)     │
└──────────────────┘                              └────────┬─────────┘
                                                            │
         ┌──────────────────────────────────────────────────┘
         │ watches TaskCreated events
         │ signs EIP-712 A2A messages
         │ submits via session key
         ▼
┌──────────────────┐
│  TaskLifecycle   │  ──► emits MessageSubmitted
│  (on-chain)      │
└──────────────────┘
```

## Prerequisites

- **Node.js 20+** (for `tsx` and ESM)
- A deployed XYX v1.3 on Monad testnet (run `forge script script/Deploy.s.sol:Deploy --broadcast` from the project root)
- A Monad testnet RPC URL (default: `https://testnet-rpc.monad.xyz`)
- A **relayer EOA** with some testnet MON (the gas payer)
- An **agent** already registered on `AgentRegistry` with the relayer's EOA set as its session key

## Setup

```bash
cd relayer
npm install
cp .env.example .env
# Edit .env with your addresses + private key
```

### One-time: register the agent and set the session key

From a separate script (or `cast`):

```bash
# 1. Agent owner registers
cast send $AGENT_REGISTRY_ADDR "registerAgent(string,bytes32[])" \
  "https://my-agent.example.com" \
  "[$(cast keccak 'data-analysis')]" \
  --value 0.101ether \
  --private-key $AGENT_OWNER_PRIVATE_KEY \
  --rpc-url $MONAD_RPC_URL

# 2. Get the new agentId
AGENT_ID=$(cast call $AGENT_REGISTRY_ADDR "getAgentByOwner(address)(uint256)" $AGENT_OWNER_ADDRESS --rpc-url $MONAD_RPC_URL)

# 3. Agent owner sets the relayer's EOA as the session key (1 hour from now)
VALID_UNTIL=$(($(date +%s) + 3600))
cast send $AGENT_REGISTRY_ADDR "setSessionKey(uint256,address,uint64)" \
  $AGENT_ID $RELAYER_ADDRESS $VALID_UNTIL \
  --private-key $AGENT_OWNER_PRIVATE_KEY \
  --rpc-url $MONAD_RPC_URL
```

## Run

```bash
# Dry-run mode (no txs sent — just logs what it would do)
npm run start:dry

# Live mode
npm run start
```

The relayer will:

1. Verify the session key is registered and not expired
2. Print config to stdout
3. Poll every `POLL_INTERVAL_MS` (default 4s) for new blocks
4. For each new block, scan `TaskCreated` events
5. Filter to events initiated by `AGENT_OWNER_ADDRESS`
6. For each new task: build A2A message → sign EIP-712 → call `submitMessageViaSessionKey`

## How signing works (EIP-712)

The relayer signs the same 5-field typed data that `TaskLifecycle` expects:

```typescript
{
  taskId: bigint,        // the task being replied to
  contentHash: bytes32,  // keccak256 of the message body
  refUri: string,        // e.g. "ipfs://relayer/..." (full msg envelope)
  nonce: uint256,        // current session key nonce (read from chain)
  deadline: uint64,      // unix timestamp, now + DEADLINE_SECONDS
}
```

Domain:

```typescript
{
  name: "XYX-A2A",
  version: "1",
  chainId: 10143,                       // Monad testnet
  verifyingContract: TASK_LIFECYCLE_ADDR
}
```

The `TaskLifecycle._verifyAndConsumeSignature` helper re-derives the same digest and calls `ECDSA.recover`. If the recovered address matches the session key AND the nonce matches AND the deadline hasn't passed, the message is accepted.

## MVP limitations

- **Polling, not subscriptions.** Monad's public RPC may not support `eth_subscribe` reliably. We poll every 4s.
- **Hardcoded response.** The MVP signs `keccak256("relayer-msg-<taskId>-<timestamp>")` and emits a `ipfs://relayer/<content>` URI. A real agent would fetch the task spec from IPFS, run an LLM, and sign the actual response.
- **Single tenant.** Only watches one agent. Multi-agent support is trivial — loop over agents and track per-agent nonces.
- **No retry logic.** If a tx fails, the error is logged and we move on. Real relayer should exponential-backoff on transient RPC errors.
- **In-memory state.** `processedTasks` Set is lost on restart. Fine for MVP, but production should persist to disk (e.g. SQLite).

## What this proves

The relayer is a smoke test for the **full gasless A2A flow**:

1. Agent owner signs once (session key registration) — D2 (agent autonomy) preserved ✅
2. Relayer pays gas — agents can run on free Monad testnet tier ✅
3. Every message has cryptographic proof of authorship — FR-2.3 met ✅
4. Replay-protected (nonce), expiry-bounded (deadline), domain-bound (EIP-712) ✅
5. Compromised session key blast radius = `validUntil` (≤ 30 days) ✅

If this works end-to-end on Monad testnet, the protocol is shipping-ready.
