/**
 * XYX Relayer — Minimal ABIs for the contracts we interact with.
 *
 * Full ABIs would be exported via `forge inspect <Contract> abi` after build.
 * We hand-write the minimum needed for the relayer to:
 *   1. Read task state (TaskLifecycle.getState, getMessageCount)
 *   2. Read session key info (AgentRegistry.getSessionKey)
 *   3. Watch for events (TaskCreated)
 *   4. Sign EIP-712 + call submitMessageViaSessionKey
 */

export const TaskLifecycleABI = [
  {
    type: "function",
    name: "getState",
    stateMutability: "view",
    inputs: [{ name: "taskId", type: "uint256" }],
    outputs: [{ name: "", type: "uint8" }], // TaskStateLib.State enum
  },
  {
    type: "function",
    name: "getMessageCount",
    stateMutability: "view",
    inputs: [{ name: "taskId", type: "uint256" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "getMessages",
    stateMutability: "view",
    inputs: [{ name: "taskId", type: "uint256" }],
    outputs: [
      {
        name: "",
        type: "tuple[]",
        components: [
          { name: "sender", type: "address" },
          { name: "contentHash", type: "bytes32" },
          { name: "refUri", type: "string" },
          { name: "timestamp", type: "uint64" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "nonces",
    stateMutability: "view",
    inputs: [{ name: "", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "submitMessageViaSessionKey",
    stateMutability: "nonpayable",
    inputs: [
      { name: "taskId", type: "uint256" },
      { name: "contentHash", type: "bytes32" },
      { name: "refUri", type: "string" },
      { name: "deadline", type: "uint64" },
      { name: "signature", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "event",
    name: "TaskCreated",
    inputs: [
      { name: "taskId", type: "uint256", indexed: true },
      { name: "initiator", type: "address", indexed: true },
      { name: "specHash", type: "bytes32", indexed: false },
      { name: "reward", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "MessageSubmitted",
    inputs: [
      { name: "taskId", type: "uint256", indexed: true },
      { name: "sender", type: "address", indexed: true },
      { name: "contentHash", type: "bytes32", indexed: false },
    ],
  },
] as const;

export const AgentRegistryABI = [
  {
    type: "function",
    name: "getSessionKey",
    stateMutability: "view",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [
      { name: "key", type: "address" },
      { name: "validUntil", type: "uint64" },
      { name: "active", type: "bool" },
    ],
  },
  {
    type: "function",
    name: "sessionKeyToAgentId",
    stateMutability: "view",
    inputs: [{ name: "key", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "ownerOf",
    stateMutability: "view",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "getAgentByOwner",
    stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;
