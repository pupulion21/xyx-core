/**
 * XYX Relayer — Environment Configuration
 *
 * Required env vars (use .env file, never commit):
 *   - MONAD_RPC_URL         — Monad testnet RPC endpoint
 *   - RELAYER_PRIVATE_KEY   — EOA that pays gas for agent messages
 *   - TASK_LIFECYCLE_ADDR   — Deployed TaskLifecycle contract address
 *   - AGENT_REGISTRY_ADDR   — Deployed AgentRegistry contract address
 *   - SESSION_KEY_ADDRESS   — The session key we registered for the agent (relayer-controlled)
 *   - AGENT_OWNER_ADDRESS   — The agent's owner (whose tasks we want to watch)
 *
 * Optional:
 *   - MONAD_CHAIN_ID        — defaults to 10143 (Monad testnet)
 *   - POLL_INTERVAL_MS      — defaults to 4000 (4s)
 *   - DEADLINE_SECONDS      — defaults to 3600 (1 hour, per A2A_SIGNATURE_DEADLINE)
 *   - DRY_RUN               — "true" to log but not send transactions
 */
import { defineChain } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { z } from "zod";

const EnvSchema = z.object({
  MONAD_RPC_URL: z.string().url(),
  RELAYER_PRIVATE_KEY: z.string().regex(/^0x[a-fA-F0-9]{64}$/, "Must be 0x-prefixed 32-byte hex"),
  TASK_LIFECYCLE_ADDR: z.string().regex(/^0x[a-fA-F0-9]{40}$/),
  AGENT_REGISTRY_ADDR: z.string().regex(/^0x[a-fA-F0-9]{40}$/),
  SESSION_KEY_ADDRESS: z.string().regex(/^0x[a-fA-F0-9]{40}$/),
  AGENT_OWNER_ADDRESS: z.string().regex(/^0x[a-fA-F0-9]{40}$/),
  MONAD_CHAIN_ID: z.coerce.number().int().positive().default(10143),
  POLL_INTERVAL_MS: z.coerce.number().int().positive().default(4000),
  DEADLINE_SECONDS: z.coerce.number().int().positive().default(3600),
  DRY_RUN: z.enum(["true", "false"]).default("false").transform((v) => v === "true"),
});

export type Env = z.infer<typeof EnvSchema>;

export function loadConfig(): {
  env: Env;
  account: ReturnType<typeof privateKeyToAccount>;
  chain: ReturnType<typeof defineChain>;
} {
  const parsed = EnvSchema.safeParse(process.env);
  if (!parsed.success) {
    console.error("❌ Invalid environment configuration:");
    console.error(parsed.error.flatten().fieldErrors);
    console.error("\nRequired env vars — see relayer/.env.example");
    process.exit(1);
  }
  const env = parsed.data;

  const account = privateKeyToAccount(env.RELAYER_PRIVATE_KEY as `0x${string}`);
  if (account.address.toLowerCase() !== env.SESSION_KEY_ADDRESS.toLowerCase()) {
    console.error(`❌ RELAYER_PRIVATE_KEY derives to ${account.address}, but SESSION_KEY_ADDRESS is ${env.SESSION_KEY_ADDRESS}`);
    console.error("   The session key must be the relayer's EOA (or vice versa).");
    process.exit(1);
  }

  const chain = defineChain({
    id: env.MONAD_CHAIN_ID,
    name: env.MONAD_CHAIN_ID === 10143 ? "Monad Testnet" : "Monad",
    nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
    rpcUrls: { default: { http: [env.MONAD_RPC_URL] } },
  });

  return { env, account, chain };
}
