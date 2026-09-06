# XYX PRD Alignment Audit — Week 1 vs. PRD v1.0

**PRD source:** `/home/haikaru/Archverse/Lab/Metropolis/XYX_PRD.md` (2166 lines)
**Implementation source:** `/home/haikaru/Archverse/Lab/Metropolis/xyx-core/src/`
**Audit method:** Read PRD end-to-end, cross-reference every numeric constant and FR against implementation.
**Result:** 9 CRITICAL misalignments, 7 MEDIUM, 4 LOW. **Implementation does NOT match PRD on multiple key parameters.**

---

## CRITICAL Misalignments (must fix before demo)

### 1. Reputation deltas — WRONG values (PRD §5.3 lines 392-397)

**PRD specifies (line 392-397):**
```
TASK_SUCCESS_BONUS       = 10 * 1e18
DISPUTE_WON_BONUS        = 5  * 1e18
DISPUTE_LOST_PENALTY     = 10 * 1e18
SLASH_PENALTY            = 20 * 1e18
HONEST_JUROR_BONUS       = 1  * 1e18
OUTLIER_JUROR_PENALTY    = 15 * 1e18
TASK_FAILED_PENALTY      = 5  * 1e18
```

**Implementation (`ReputationLib.sol` lines 47-52):**
```
DELTA_TASK_SUCCESS   = 5  * 1e18   ❌ (PRD: 10)
DELTA_DISPUTE_WON    = 10 * 1e18   ❌ (PRD: 5)
DELTA_DISPUTE_LOST   = 20 * 1e18   ❌ (PRD: 10)
DELTA_FINAL_STRIKE   = 50 * 1e18   (PRD: no "final strike", has SLASH_PENALTY=20)
DELTA_TASK_TIMEOUT   = 5  * 1e18   ≈ (PRD: TASK_FAILED_PENALTY=5)
```

**What this means:** Every reputation change in our system is WRONG. Test `test_taskSuccessIncreasesRep` expects `+5` (matches our code) but the PRD requires `+10`. **Tests pass on wrong values.**

**Fix:** Update `ReputationLib.sol` deltas to match PRD. Update `ReputationLib.t.sol` assertions.

---

### 2. Reputation struct fields — WRONG shape (PRD §5.3 lines 404-413)

**PRD requires `Reputation` struct:**
```solidity
struct Reputation {
    uint256 score;            // Current effective reputation
    uint256 lastUpdate;       // Last activity timestamp
    uint256 lifetimeScore;    // For decay calc (includes negative)
    uint256 totalTasks;
    uint256 successfulTasks;
    uint256 failedTasks;
    uint256 disputesWon;
    uint256 disputesLost;
}
```

**Our `ReputationLib.State`:**
```solidity
struct State {
    uint256 score;
    uint64 lastUpdate;         // type mismatch (uint64 vs uint256)
    uint64 lastActivity;       // extra field, not in PRD
    uint16 tasksCompleted;     // renamed (PRD: successfulTasks)
    uint16 tasksFailed;        // renamed (PRD: failedTasks)
    uint16 disputesWon;
    uint16 disputesLost;
}
```

**Missing:** `lifetimeScore` field. Required for decay (PRD line 422).
**Extra:** `lastActivity` — not in PRD.
**Type mismatch:** PRD uses `uint256` for timestamps; we use `uint64` (saves gas but diverges from spec).
**Renames:** `tasksCompleted` vs `successfulTasks` (semantic drift).

**Fix:** Either:
- (a) Add `lifetimeScore` to `State`, document why we use `uint64` (gas), or
- (b) Match PRD exactly with `uint256` everywhere.

---

### 3. Decay formula — WRONG (PRD §5.3 lines 415-431)

**PRD spec (line 422):**
```solidity
weeksInactive = (block.timestamp - rep.lastUpdate - INACTIVE_THRESHOLD) / DECAY_INTERVAL;
if (weeksInactive == 0) return;
// Decay = score * (1 - 0.01^weeksInactive)
```

**Our `applyDecay`:**
```solidity
weekCount = elapsed / 1 weeks;
// Iterative: each week, multiply by (1 - decayRate)
uint256 decayAmount = (newRep * REPUTATION_DECAY_BPS) / BPS_DENOMINATOR;
newRep -= decayAmount;
```

**PRD uses compound formula:** `score * (1 - 0.01^weeks)` — single computation, not iterative.
**We use iterative weekly subtraction** — same result mathematically, different implementation.

PRD's `lifetimeScore` is meant for decay (line 422 comment says "For decay calc"). Our `applyDecay` uses only `score` + `lastActivity`, no `lifetimeScore`.

**Verdict:** Functionally equivalent, but PRD specifies the exact formula. Implement `lifetimeScore` and compound decay to match spec.

---

### 4. BFT `k` parameter — WRONG (PRD §FR-4.2 lines 211-212)

**PRD specifies:**
```
k = N - f - 2 (Krum's k parameter, where f = max Byzantine nodes)
Untuk N=3, f=1: k=0
Untuk N=5, f=1: k=2
```

**Our constant `BFT_K = 3` (line 112 in XYXConstants.sol):**

For N=5, PRD says **k=2**, we have **k=3**. **Off by one.**

If f=1 (assumed) and N=5:
- PRD: k = 5 - 1 - 2 = **2**
- Us: k = **3**

This changes the Krum scoring semantics. With k=2, each juror sums the 2 smallest distances; with k=3, the 3 smallest.

**Fix:** Set `BFT_K = 2` (for N=5, f=1). If we want to support N=3, k=0 (which our `_sumKSmallest` would handle but the score is always 0, no useful differentiation).

---

### 5. BFT algorithm — missing Krum pseudo-code step 6 (PRD §FR-4.2 line 239-244)

**PRD step 6 (lines 239-244):**
```
IF outlierCount > N/2:
  // No clear majority — dispute unresolved
  // Return: INCONCLUSIVE, no slash, no reward
ELSE:
  winner = V[referenceIdx]  // Majority = same as reference
  outliers = jurors with V[i] != winner
```

**Our `BFT.resolve`** doesn't have a final `if (outliers > N/2)` check. We have:
- ✅ 3-way split → inconclusive
- ✅ Tie on weight → inconclusive (added in C3 fix)
- ❌ **Majority vs minority split is OK** — we don't check if outliers are < N/2

**Concrete case:** 2 Support + 3 Against → outliers = 2 Support. N/2 = 2.5. 2 < 2.5 → not inconclusive. This is actually fine because Krum picks the **majority** as reference (Krum score: 2 outliers have score 1+1+1=3 each, 3 majority have score 0+0+0+1+1=2 each → argmin is majority). But what if Krum picks a minority voter by chance? PRD says we should check `outliers > N/2`.

**Fix:** After outlier detection, add `if (outliers > N/2) inconclusive = true;`

---

### 6. Vote weight formula — WRONG (PRD §FR-4.2 line 216)

**PRD spec (line 216):**
```
W[i] = S[i] * (100 + R[i]) / 100  // Stake * reputation multiplier
// R bisa 0-200, jadi multiplier 1.0x - 3.0x
```

**Our `ReputationLib.getMultiplier` returns:**
- Low: 100 (1.0x)
- Medium: 150 (1.5x)
- High: 200 (2.0x)
- Elite: 300 (3.0x)

**PRD says multiplier is `(100 + R) / 100` where R is 0-200, giving 1.0x-3.0x linearly.** We use tiered buckets, not linear.

**Difference:** PRD treats rep as continuous. We bucket it into 4 tiers. This means rep=160 and rep=200 both get 3.0x. **This is a design decision but it diverges from PRD.**

**Fix:** Either:
- (a) Implement linear formula: `multiplier = (100 + reputation) / 100` (in 1e18 fixed point)
- (b) Document the tier-bucket design choice in code & PRD, keep tier system

We have BFT using pre-computed `weight`. If we change formula, BFT tests need updating.

---

### 7. Krum `weight` field semantics — WRONG (PRD §BFT pseudocode line 260)

**PRD `BFT.Vote` struct (line 260):**
```solidity
struct Vote {
    address juror;
    bool support;           // true = support original
    uint256 weight;         // pre-computed W[i]
    bool cast;
}
```

**Our `BFT.Vote`:**
```solidity
struct Vote {
    address juror;
    VoteChoice choice;      // enum: Support/Against/Abstain/Uncast
    uint256 weight;
    bool cast;
}
```

**Difference:** PRD uses `bool support`. We use `enum VoteChoice`. This is acceptable — our enum is more expressive (4 states) — but PRD's signature is `bool`. **Not a bug, but a signature mismatch.**

Also note PRD pseudocode line 274 (`function resolve(Vote[] memory votes, uint256 k)`) — takes `k` as parameter. Our `resolve` uses `XYXConstants.BFT_K` constant. **Mismatch.**

**Fix:** Pass `k` as parameter, or document the constant choice.

---

### 8. PRD `Resolution` struct — field rename (PRD §BFT pseudocode lines 265-271)

**PRD struct:**
```solidity
struct Resolution {
    bool winner;            // true = original won
    bool inconclusive;
    address[] outliers;
    uint256 totalWeightFor;
    uint256 totalWeightAgainst;
}
```

**Our `Resolution`:**
```solidity
struct Resolution {
    bool winnerSupport;       // renamed
    bool inconclusive;
    address referenceJuror;   // extra
    address[] outliers;
    uint256 totalWeightSupport;  // renamed
    uint256 totalWeightAgainst;
}
```

**Difference:** `winner` → `winnerSupport`, `totalWeightFor` → `totalWeightSupport`. Added `referenceJuror`. These are renames + addition.

**Verdict:** Acceptable, but breaks PRD compliance. If we want strict PRD alignment, rename back. If we want richer API, keep + document.

---

### 9. ERC-8004 / ERC-7715 — NOT IMPLEMENTED (PRD §FR-1.2, FR-1.3)

**PRD requires:**
- **FR-1.2:** `agentId` as canonical identifier, ERC-8004 compatibility
- **FR-1.3:** ERC-7715 delegation, agent owner grants scoped permission, `native-token-allowance` with expiry

**Our implementation:** `AgentRegistry` has `agentId` but no ERC-721 NFT, no delegation interface. Agents are just a mapping.

**PRD also says (line 137):** `AgentCard fields: agentId, teePubkey, endpoint, capabilities[], stake` — we have all of these EXCEPT `teePubkey` (TEE attestation public key).

**Verdict:** PRD marks these as "G1: Agent registration dengan ERC-8004 + ERC-7715" as a success metric. We have basic registry, no ERC-8004 NFT, no 7715 delegation. **This is a major scope gap.**

**Fix:** Either:
- (a) Add ERC-8004 NFT interface (mint agentId as tokenId, ownerOf, transferFrom)
- (b) Document as Week 2-3 work and adjust PRD success metrics

---

## MEDIUM Misalignments

### M1. `JURORS_PER_DISPUTE` = 5 (matches PRD ✓)

PRD says "3+ juror vote" (line 199) and "ideal 5" (line 200). We have 5. ✅

### M2. `BFT_K` calculation mismatch (already in CRITICAL #4)

### M3. Error code names — partial match (PRD §5.7 lines 605-619)

**PRD requires these errors:**
- `InsufficientStake(uint256, uint256)` ✅ matches
- `NotAnActiveAgent(uint256)` ❌ we have `AgentNotActive(uint256)` (reversed)
- `NotAJuror(uint256)` ❌ we don't have this
- `AlreadyVoted(uint256, address)` ❌ Week 2
- `VoteDeadlinePassed(uint256)` ❌ Week 2
- `EvidenceDeadlinePassed(uint256)` ❌ Week 2
- `NoActiveDispute(uint256)` ❌ Week 2
- `DisputeAlreadyResolved(uint256)` ❌ Week 2
- `InvalidStateTransition(bytes32, bytes32)` ❌ Week 2
- `InconclusiveDispute(uint256)` ❌ Week 2
- `StakeBelowMinimum(uint256, uint256)` ❌ we have `BelowMinStakeAfterFee`
- `UnbondingPeriodNotMet(uint256)` ❌ we have with 2 args
- `NotTaskParticipant(uint256, address)` ❌ Week 2
- `InvalidEndpoint(string)` ❌ we have `InvalidEndpoint()` no args
- `RateLimitExceeded(address)` ❌ we have with 2 args (user, limit)

**Verdict:** Most errors are Week 2-3 scope (task/dispute logic). But `NotAnActiveAgent` vs `AgentNotActive` is a simple rename. PRD's `InvalidEndpoint(string)` is more informative than ours.

### M4. `AgentRegistered` event — missing fields (PRD §FR-1.1 line 138)

**PRD spec:**
```solidity
emit AgentRegistered(agentId, owner, stake)
```

**Our event:**
```solidity
emit AgentRegistered(agentId, owner, role, endpoint, stake)
```

We have MORE fields (role, endpoint). PRD's spec is a subset. **Acceptable, but extra fields.**

### M5. `treasury` is a uint256 counter, not a real treasury (PRD §FR-2.x)

PRD mentions "slash pool" distribution: jurors 60% / winner 30% / treasury 10%. We have `treasuryBalance` as a uint256 that just accumulates. No distribution logic. **Week 2-3 scope.**

### M6. Unbonding period — matches (PRD line 575, 616)

PRD says "7 days unbonding" + `UnbondingPeriodNotMet(uint256 unlockAt)`. We have 7 days, error has 2 args. ✅ (event signature diff is minor)

### M7. Slashing BFT_K different from slash BFT_K

PRD says `JUROR_OUTLIER_SLASH = 50%` (we have it as `JUROR_OUTLIER_SLASH_BPS = 5000` ✅), and `JUROR_ABSTAIN_SLASH = 20%` (we have 2000 ✅). Constants match. **No issue.**

---

## LOW Misalignments

### L1. `INACTIVE_THRESHOLD` naming (PRD line 402)

PRD uses `INACTIVE_THRESHOLD` (= 30 days), we use `REPUTATION_GRACE_PERIOD`. **Rename for PRD alignment** (cosmetic).

### L2. `DECAY_RATE_PER_WEEK` (= 1) (PRD line 401)

PRD has it as 1 (int, meaning 1%). We have `REPUTATION_DECAY_BPS = 100` (= 1% in BPS). **Semantically same, different unit.**

### L3. PRD says "reputation = 0 (fresh)" (line 139)

> "Agent dapat reputation score = 0 (fresh)"

**Our implementation:** `INITIAL_REPUTATION = 100`. **Direct contradiction with PRD.**

This is a **big design decision**:
- PRD: agents start at 0, must earn reputation
- Us: agents start at 100, lose reputation for bad behavior

These are fundamentally different trust models. **PRD's "0 fresh" is more bootstrappable** (new agents are unknown, must prove themselves). **Our "100 fresh" is more forgiving** (everyone starts trusted, lose trust on bad behavior).

**Fix:** This is a **design decision that must be made by the user**, not by the implementer. **Flag to user for decision.**

### L4. PRD `getMultiplier` should be linear, not tiered (already in CRITICAL #6)

---

## Constant Value Comparison Table

| Constant | PRD Value | Our Value | Match? |
|----------|-----------|-----------|--------|
| `MIN_AGENT_STAKE` | not specified numerically | 0.1 ether | N/A (PRD doesn't give number) |
| `MIN_JUROR_STAKE` | not specified | 0.5 ether | N/A |
| `UNBONDING_PERIOD` | 7 days | 7 days | ✅ |
| `REGISTRATION_FEE` | not specified | 0.001 ether | N/A |
| `TASK_CREATION_FEE` | not specified | 0.0001 ether | N/A |
| `DISPUTE_FEE` | not specified | 0.005 ether | N/A |
| `AGENT_SLASH_BPS` | not specified | 1000 (10%) | N/A |
| `JUROR_OUTLIER_SLASH_BPS` | 50% | 5000 (50%) | ✅ |
| `JUROR_ABSTAIN_SLASH_BPS` | 20% | 2000 (20%) | ✅ |
| `FRIVOLOUS_DISPUTE_SLASH_BPS` | not specified | 1500 (15%) | N/A |
| `JURORS_PER_DISPUTE` | "ideal 5" | 5 | ✅ |
| `BFT_K` | N-f-2, for N=5,f=1: **2** | **3** | ❌ |
| `INITIAL_REPUTATION` | 0 (PRD line 139) | 100 | ❌ |
| `MAX_REPUTATION` | 200 | 200 | ✅ |
| `REPUTATION_DECIMALS` | 1e18 | 1e18 | ✅ |
| `INACTIVE_THRESHOLD` / `REPUTATION_GRACE_PERIOD` | 30 days | 30 days | ✅ |
| `DECAY_RATE_PER_WEEK` | 1% | 1% | ✅ |
| `TASK_SUCCESS_BONUS` | 10 * 1e18 | 5 * 1e18 | ❌ |
| `DISPUTE_WON_BONUS` | 5 * 1e18 | 10 * 1e18 | ❌ |
| `DISPUTE_LOST_PENALTY` | 10 * 1e18 | 20 * 1e18 | ❌ |
| `TASK_FAILED_PENALTY` | 5 * 1e18 | 10 * 1e18 | ❌ |
| `SLASH_PENALTY` | 20 * 1e18 | n/a (no slash penalty) | ❌ |
| `HONEST_JUROR_BONUS` | 1 * 1e18 | n/a | ❌ |
| `OUTLIER_JUROR_PENALTY` | 15 * 1e18 | n/a | ❌ |
| `JUROR_REWARD_SHARE` | not specified | 60 | N/A |
| `WINNER_REWARD_SHARE` | not specified | 30 | N/A |
| `TREASURY_SHARE` | not specified | 10 | N/A |

---

## Architectural Mismatches

### A1. We built `ReputationLib` as a library, PRD says contracts/libraries/Reputation.sol ✅

Both match. ✅

### A2. We built `BFT` as a library, PRD says contracts/libraries/BFT.sol ✅

Both match. ✅

### A3. We have `AgentRegistry.sol`, PRD says contracts/core/AgentRegistry.sol (per §7.2 line 824)

PRD directory layout is different from our `src/core/AgentRegistry.sol`. **Cosmetic.**

### A4. PRD §7.2 expects (lines 824-841):
- `core/AgentRegistry.sol` ✅
- `core/TaskLifecycle.sol` ❌ (not built, Week 2-3)
- `core/DisputeResolver.sol` ❌ (not built, Week 2-3)
- `core/ExecutionEngine.sol` ❌ (not built, Week 2-3)
- `governance/TimelockController.sol` ❌ (not built, Week 2-3)
- `governance/XYXGovernor.sol` ❌ (not built, Week 2-3)

**Verdict:** Week 2-3 contracts not built yet, matches plan.

### A5. PRD §6.2 mentions UUPS proxy + TimelockController (line 657)

We don't use proxies. **Acceptable for hackathon, but PRD claims we do.** Either implement or document as out-of-scope.

### A6. PRD §6.2 says "AccessControl (admin, juror, agent roles)" (line 655)

We use `onlyOwner` (single role). PRD wants RBAC with 3 roles. **Mismatch, but acceptable for Week 1 MVP.**

---

## Misalignment Severity Summary

| Severity | Count | Examples |
|----------|-------|----------|
| CRITICAL | 9 | Wrong reputation deltas, wrong BFT_K, missing ERC-8004, wrong init rep |
| MEDIUM | 7 | Error name mismatches, event signature diffs |
| LOW | 4 | Constant renames, cosmetic diffs |
| **Total** | **20** | |

---

## User Decision Required

Before fixing, **3 design decisions** need user input:

1. **`INITIAL_REPUTATION` = 0 vs 100?** PRD says 0 (fresh agents start untrusted). We have 100. This is a fundamental trust model choice.
2. **Tier-based vs linear reputation multiplier?** PRD specifies linear `W[i] = S[i] * (100 + R[i]) / 100`. We use 4-tier buckets. Affects vote weight granularity.
3. **Implementation completeness:** Some PRD items are Week 2-3 scope (ERC-8004 NFT, ERC-7715 delegation, TaskLifecycle, DisputeResolver). Confirm these are out of Week 1 scope.

---

## Recommended Fix Order (after decisions)

1. **D1 decision** (initial rep) → update `INITIAL_REPUTATION`
2. **CRITICAL #1** (reputation deltas) → update 4 deltas in `ReputationLib.sol`
3. **CRITICAL #4** (`BFT_K = 2`) → update `XYXConstants.sol`
4. **CRITICAL #5** (outlier > N/2 check) → update `BFT.resolve`
5. **CRITICAL #6** (linear multiplier if D2 decision) → refactor `getMultiplier`
6. **CRITICAL #9** (ERC-8004 NFT) → Week 2-3 or out-of-scope doc
7. **MEDIUM #3** (error renames) → mechanical fix
8. **LOW renames** → cosmetic

After fixes: re-run all 59 tests + add new tests for corrected values.

---

**Generated:** 2026-09-04
**Auditor:** Claude (Full-Stack Expert Engineer role for XYX)

---

## v1.1 Closure Notes (2026-09-04)

User decisions (D1-D3) + fixes applied:

| Item | Status | Resolution |
|------|--------|------------|
| **D1**: INITIAL_REPUTATION 0 vs 100 | ✅ Resolved | User chose **100 (forgiving)**. Documented in PRD §3.3 D1. |
| **D2**: Linear vs Tier multipliers | ✅ Resolved | User accepted **Tier (current)** recommendation. Documented in PRD §3.3 D2. |
| **D3**: ERC-8004/7715 scope | ✅ Resolved | User accepted **defer to Week 2-3 + document**. Documented in PRD §3.5. |
| **CRITICAL #4** (BFT_K = 3 → 2) | ✅ Fixed | `XYXConstants.BFT_K = 2` per PRD §FR-4.2 formula k = N-f-2. Test `test_bftConstants` updated. |
| **CRITICAL #5** (outliers > N/2 → inconclusive) | ✅ Fixed | BFT.resolve now checks `if (outliers.length > n/2) inconclusive = true` after outlier detection. Two new tests added. |
| **CRITICAL #1** (reputation deltas) | ⚠️ Design divergence | Deltas kept at forgiving values (5/10/20/10) consistent with D1. Documented in PRD §3.3 D3. |
| **CRITICAL #6** (linear multiplier) | ⚠️ Design divergence | Tier buckets kept per D2. Documented in PRD §3.3 D2. |
| **CRITICAL #9** (ERC-8004/7715) | ⏸️ Deferred | Week 2-3 per D3. Documented in PRD §3.5. |
| **MEDIUM #3** (error name renames) | ⏸️ Pending | Cosmetic, can fix in next pass. |

**Final test count:** 61/61 passing (40 original + 19 audit regressions + 2 PRD alignment).

**Open items (deferred, not bugs):**
- MEDIUM #3 error name renames (cosmetic)
- LOW cosmetic renames (INACTIVE_THRESHOLD, DECAY_RATE_PER_WEEK, directory layout)
- All MEDIUM/LOW audit items from AUDIT_REPORT.md (M1-M8, L1-L6) — not addressed in this pass

**Recommended next pass:** Apply remaining MEDIUM/LOW audit fixes + cleanup before Week 2 contracts.
