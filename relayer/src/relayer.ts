/**
 * XYX Relayer — Main loop
 *
 * Watches for TaskCreated events targeting our agent, signs EIP-712 A2A messages
 * with the agent's session key, and submits them via submitMessageViaSessionKey.
 *
 * Flow per task:
 *   1. TaskCreated(taskId, initiator, specHash, reward) — emit detected
 *   2. Filter: only process if initiator is the watched AGENT_OWNER
 *   3. Verify session key is still valid (validUntil > now)
 *   4. Build A2A message: keccak256("hello-from-relayer") + "ipfs://relayer-msg"
 *   5. Sign EIP-712 (typed data hash with TaskLifecycle's domain)
 *   6. Submit via submitMessageViaSessionKey (relayer pays gas)
 *
 * For real production, the relayer would:
 *   - Read task specHash from event, fetch the actual task from IPFS
 *   - Run an AI agent (or call out to one) to generate a context-aware response
 *   - Implement retry logic with exponential backoff
 *   - Track submitted nonces to avoid double-submission
 *   - Support multiple agents (multi-tenant)
 *
 * This MVP does the bare minimum to prove the end-to-end flow.
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  toBytes,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
  type Account,
  type Chain,
  type Transport,
  getAddress,
} from "viem";
import { loadConfig } from "./config.js";
import { TaskLifecycleABI, AgentRegistryABI } from "./abis.js";

type Public = PublicClient<Transport, Chain>;
type Wallet = WalletClient<Transport, Chain, Account>;

// viem v2 ships a strict `formatters`/`fillTransaction` typing for known chains.
// Our custom defineChain doesn't carry the eip7702 formatters, so we relax the
// helper's client types to `any` at the boundary. The runtime is fine.
type LoosePublic = PublicClient<Transport, any>;
type LooseWallet = WalletClient<Transport, any, Account>;

// TaskState enum (must match src/libraries/TaskStateLib.sol)
enum TaskState {
  None = 0,
  Submitted = 1,
  Working = 2,
  InputRequired = 3,
  Completed = 4,
  Failed = 5,
  Canceled = 6,
  Disputed = 7,
}

// EIP-712 typehash for A2AMessage (must match TaskLifecycle.A2A_MESSAGE_TYPEHASH)
const A2A_MESSAGE_TYPEHASH = keccak256(
  toBytes(
    "A2AMessage(uint256 taskId,bytes32 contentHash,string refUri,uint256 nonce,uint64 deadline)"
  )
);

const EIP712_DOMAIN_NAME = "XYX-A2A";
const EIP712_DOMAIN_VERSION = "1";

interface A2AMessage {
  taskId: bigint;
  contentHash: Hex;
  refUri: string;
  nonce: bigint;
  deadline: bigint;
}

async function main() {
  const { env, account, chain } = loadConfig();
  console.log("🚀 XYX Relayer starting...");
  console.log(`   Chain:        ${chain.name} (${chain.id})`);
  console.log(`   RPC:          ${env.MONAD_RPC_URL}`);
  console.log(`   Relayer EOA:  ${account.address}`);
  console.log(`   Agent Owner:  ${env.AGENT_OWNER_ADDRESS}`);
  console.log(`   TaskContract: ${env.TASK_LIFECYCLE_ADDR}`);
  console.log(`   Registry:     ${env.AGENT_REGISTRY_ADDR}`);
  console.log(`   Dry run:      ${env.DRY_RUN}`);
  console.log("");

  // Public client (read-only)
  const publicClient = createPublicClient({
    chain,
    transport: http(env.MONAD_RPC_URL),
  });

  // Wallet client (signs + sends)
  const walletClient = createWalletClient({
    account,
    chain,
    transport: http(env.MONAD_RPC_URL),
  });

  // 1. Verify session key is registered for the agent
  const agentId = (await publicClient.readContract({
    address: env.AGENT_REGISTRY_ADDR as Address,
    abi: AgentRegistryABI,
    functionName: "getAgentByOwner",
    args: [env.AGENT_OWNER_ADDRESS as Address],
  })) as bigint;

  if (agentId === 0n) {
    console.error(`❌ No agent registered for owner ${env.AGENT_OWNER_ADDRESS}`);
    process.exit(1);
  }

  const sessionKeyInfo = (await publicClient.readContract({
    address: env.AGENT_REGISTRY_ADDR as Address,
    abi: AgentRegistryABI,
    functionName: "getSessionKey",
    args: [agentId],
  })) as readonly [Address, bigint, boolean];

  const [sessionKeyAddr, validUntil, active] = sessionKeyInfo;
  if (!active) {
    console.error(`❌ Session key not active for agent ${agentId}`);
    process.exit(1);
  }
  if (BigInt(Math.floor(Date.now() / 1000)) > validUntil) {
    console.error(`❌ Session key expired at ${new Date(Number(validUntil) * 1000).toISOString()}`);
    process.exit(1);
  }
  if (getAddress(sessionKeyAddr) !== getAddress(env.SESSION_KEY_ADDRESS)) {
    console.error(`❌ Registry session key ${sessionKeyAddr} != configured ${env.SESSION_KEY_ADDRESS}`);
    process.exit(1);
  }

  console.log(`✅ Session key verified:`);
  console.log(`   Agent ID:    ${agentId}`);
  console.log(`   Key:         ${sessionKeyAddr}`);
  console.log(`   Valid until: ${new Date(Number(validUntil) * 1000).toISOString()}`);
  console.log("");

  // 2. Main loop: watch for TaskCreated events targeting our agent
  console.log("👀 Watching for TaskCreated events...");

  // We use polling instead of subscriptions (Monad RPC may not support ws in MVP)
  let lastBlock = await publicClient.getBlockNumber();
  const processedTasks = new Set<string>(); // taskId -> already submitted

  const tick = async () => {
    try {
      const currentBlock = await publicClient.getBlockNumber();
      if (currentBlock <= lastBlock) return;

      const logs = await publicClient.getContractEvents({
        address: env.TASK_LIFECYCLE_ADDR as Address,
        abi: TaskLifecycleABI,
        eventName: "TaskCreated",
        fromBlock: lastBlock + 1n,
        toBlock: currentBlock,
      });

      for (const log of logs) {
        const { taskId, initiator } = log.args as { taskId: bigint; initiator: Address };
        if (getAddress(initiator) !== getAddress(env.AGENT_OWNER_ADDRESS)) continue;
        if (processedTasks.has(taskId.toString())) continue;

        console.log(`\n📥 New task detected: taskId=${taskId} initiator=${initiator}`);
        await submitA2AMessage(publicClient, walletClient, chain, env, taskId);
        processedTasks.add(taskId.toString());
      }

      lastBlock = currentBlock;
    } catch (err) {
      console.error(`⚠️  Loop error:`, err);
    }
  };

  const interval = setInterval(tick, env.POLL_INTERVAL_MS);
  process.on("SIGINT", () => {
    console.log("\n👋 Shutting down...");
    clearInterval(interval);
    process.exit(0);
  });
}

async function submitA2AMessage(
  publicClient: LoosePublic,
  walletClient: LooseWallet,
  chain: Chain,
  env: ReturnType<typeof loadConfig>["env"],
  taskId: bigint
): Promise<void> {
  // 1. Check task state — only submit if Submitted (state=1)
  const state = (await publicClient.readContract({
    address: env.TASK_LIFECYCLE_ADDR as Address,
    abi: TaskLifecycleABI,
    functionName: "getState",
    args: [taskId],
  })) as number;

  if (state !== TaskState.Submitted) {
    console.log(`   ⏭️  Skipping: task state is ${TaskState[state]} (not Submitted)`);
    return;
  }

  // 2. Get current nonce for our session key
  const nonce = (await publicClient.readContract({
    address: env.TASK_LIFECYCLE_ADDR as Address,
    abi: TaskLifecycleABI,
    functionName: "nonces",
    args: [env.SESSION_KEY_ADDRESS as Address],
  })) as bigint;

  // 3. Build A2A message
  // In production, contentHash would be keccak256 of the actual message bytes
  // and refUri would be the IPFS CID of the message envelope.
  const content = `relayer-msg-${taskId}-${Date.now()}`;
  const contentHash = keccak256(toBytes(content));
  const refUri = `ipfs://relayer/${content}`;

  const deadline = BigInt(Math.floor(Date.now() / 1000) + env.DEADLINE_SECONDS);

  // 4. Compute EIP-712 domain separator (must match TaskLifecycle's)
  const domain = {
    name: EIP712_DOMAIN_NAME,
    version: EIP712_DOMAIN_VERSION,
    chainId: env.MONAD_CHAIN_ID,
    verifyingContract: env.TASK_LIFECYCLE_ADDR as Address,
  };

  // 5. Sign the typed data
  const signature = await walletClient.signTypedData({
    domain,
    types: {
      A2AMessage: [
        { name: "taskId", type: "uint256" },
        { name: "contentHash", type: "bytes32" },
        { name: "refUri", type: "string" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint64" },
      ],
    },
    primaryType: "A2AMessage",
    message: {
      taskId,
      contentHash,
      refUri,
      nonce,
      deadline,
    },
  });

  console.log(`   ✍️  Signed A2A: nonce=${nonce} deadline=${new Date(Number(deadline) * 1000).toISOString()}`);

  if (env.DRY_RUN) {
    console.log(`   🧪 DRY RUN: would submit. signature=${signature.slice(0, 18)}...`);
    return;
  }

  // 6. Submit via session key (relayer pays gas, agent's session key signs)
  console.log(`   📤 Submitting via submitMessageViaSessionKey...`);
  const txHash = await walletClient.writeContract({
    chain,
    address: env.TASK_LIFECYCLE_ADDR as Address,
    abi: TaskLifecycleABI,
    functionName: "submitMessageViaSessionKey",
    args: [taskId, contentHash, refUri, deadline, signature],
  });

  console.log(`   ⏳ Tx sent: ${txHash}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
  console.log(`   ✅ Confirmed in block ${receipt.blockNumber} (gas: ${receipt.gasUsed})`);
}

main().catch((err) => {
  console.error("💥 Fatal error:", err);
  process.exit(1);
});
