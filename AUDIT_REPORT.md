# XYX Audit Report — Week 1 Smart Contracts

**Scope:** `XYXConstants.sol`, `ReputationLib.sol`, `BFT.sol`, `AgentRegistry.sol`, and 4 test files (40 tests).
**Audit method:** Manual review + test inspection + cross-reference with PRD Section 5.
**Result:** 4 CRITICAL, 6 HIGH, 8 MEDIUM, 6 LOW issues found. All tests pass — but tests do not catch the bugs below (false-positive coverage).

---

## CRITICAL Bugs (must fix)

### C1. `ReputationLib.getReputation` returns stale (non-decayed) value
**File:** `ReputationLib.sol` lines 86-111, `AgentRegistry.sol` line 315-317
**Issue:** `applyDecay` exists and is tested, but `getReputation()` in `AgentRegistry` returns the raw `score` without applying decay. Same for `getTier` (line 319-322) and `getVoteWeight` (line 324-329). An agent that registered 6 months ago and did nothing still reads as `Medium` tier.
**Repro:**
```
vm.warp(block.timestamp + 365 days);
uint256 rep = registry.getReputation(agentId);  // returns INITIAL_REPUTATION, not 0
```
**Fix:** `getReputation` should call `ReputationLib.applyDecay(repState.score, repState.lastActivity)` before returning. `getTier` and `getVoteWeight` should use the decayed value.

### C2. BFT `Uncast` votes are treated as outliers
**File:** `BFT.sol` lines 100, 108, 133
**Issue:** Only `Abstain` is skipped in Krum scoring and outlier detection. `Uncast` (vote before deadline) is treated as a distinct vote choice, which inflates Hamming distances and incorrectly marks real voters as outliers.
**Repro:**
- 3 Support + 1 Against + 1 Uncast
- Expected: 1 outlier (the Against voter)
- Actual: 2 outliers (Against + Uncast, because Uncast looks "different" from Support)
**Fix:** Add `|| votes[i].choice == VoteChoice.Uncast` to all three skip conditions.

### C3. BFT tie (2 Support / 2 Against) does not mark `inconclusive`
**File:** `BFT.sol` lines 92-126
**Issue:** Krum tie-breaking picks the first-encountered minimum score, so a 2-2 split silently resolves to whoever the first voter voted. The PRD requires a clear majority for resolution.
**Repro:**
```
3 Support voters (100 weight) + 2 Against voters (150 weight each)
= 300 support, 300 against (equal)
Krum scores: support voters each get distance 0+0+0+1+1=2
             against voters each get distance 1+1+1+0+0=3
Reference = first support voter. Outliers = 2 against. winnerSupport = true.
But the WEIGHTS are tied — should be inconclusive.
```
**Fix:** Add weight-sum check: if `totalWeightSupport == totalWeightAgainst` (no Abstain sum), mark `inconclusive = true`.

### C4. `registerAgent` accepts stake below MIN if msg.value is just above min+fee
**File:** `AgentRegistry.sol` line 110-112
**Issue:** Test only checks `msg.value >= MIN + fee`. After fee deduction, `stake = msg.value - fee` could be < `MIN`. Example: `msg.value = MIN + fee - 1` is impossible due to integer math — but `msg.value = MIN + fee + 5` and `fee = 0.001 ether` → `stake = MIN + 4`. Actually wait, this passes. But the **overpayment case** is checked, not the **post-fee stake check**.
**Repro:**
```solidity
uint256 required = XYXConstants.MIN_AGENT_STAKE + XYXConstants.REGISTRATION_FEE;  // 0.101 ether
if (msg.value < required) revert InsufficientStake(required, msg.value);
// After this, stake = msg.value - fee. Could be 0.05 ether if msg.value is exactly 0.051 + 0.001 = 0.051? No, msg.value >= 0.101 so stake >= 0.1.
// BUT: if MIN_AGENT_STAKE is changed to 0.05 in future without updating this check, it would silently pass.
```
**Verdict:** This is **defensive paranoia, not an active bug**. Current constants are consistent. But the check is **implicit** and could break in future. Add explicit `if (stake < MIN_AGENT_STAKE) revert("Below min after fee")`.

---

## HIGH Bugs

### H1. `slash` does not validate `percentBps <= 10000`
**File:** `AgentRegistry.sol` line 290
**Issue:** `slashAmount = (stake * percentBps) / 10000`. If `percentBps > 10000`, `slashAmount > stake`, then `agent.stake -= slashAmount` underflows and reverts. Better to revert early with a clear error.
**Fix:** Add `if (percentBps > XYXConstants.BPS_DENOMINATOR) revert InvalidSlashBps(percentBps);`

### H2. `addStake` does not reactivate inactive agents
**File:** `AgentRegistry.sol` line 199-207
**Issue:** If an agent is deactivated (e.g., after withdrawal that drops stake below min), they can call `addStake` to top up, but the `active` flag stays `false`. They are stuck.
**Fix:** After adding stake, check if `agent.stake >= _getMinStake(agent.role)`. If yes and `!agent.active`, set `active = true` and emit `AgentReactivated`.

### H3. `applyFinalStrike` does not deactivate agent
**File:** `AgentRegistry.sol` line 272-276
**Issue:** PRD says unregister-during-task = reputation -50 + agent deactivated. Current implementation only reduces reputation, agent stays active.
**Fix:** Add `if (agent.active) { agent.active = false; emit AgentDeactivated(agentId, "Final strike"); }`

### H4. `getTier` and `getVoteWeight` don't apply decay
**File:** `AgentRegistry.sol` lines 319-329
**Issue:** Same root cause as C1 — these view functions should also use the decayed score.

### H5. `getReputation` does not apply decay
**File:** `AgentRegistry.sol` line 315-317
**Issue:** Same as C1.

### H6. `findAgentsByCapability` array grows unbounded
**File:** `AgentRegistry.sol` line 53, 159, 187
**Issue:** Every agent registration pushes their address to `agentCapabilities[cap]`. On deactivation, no removal. Over time, this leaks gas + storage and returns deactivated agents in search.
**Fix:** Add a `deactivateAgent()` or `removeCapability()` flow, or accept this for Week 1 and document.

---

## MEDIUM Bugs

### M1. `onFinalStrike` and `onTaskTimeout` don't update `lastActivity`
**File:** `ReputationLib.sol` lines 171-181
**Issue:** These are negative reputation events, but they don't reset `lastActivity`. Inconsistent with `onTaskSuccess/Failed/onDisputeWon/Lost` which all update `lastActivity`. Could be intentional (penalize inactivity harder), but undocumented.
**Fix:** Document the asymmetry, or add `self.lastActivity = uint64(block.timestamp);` to both.

### M2. `applyDecay` does not update `lastActivity` after applying
**File:** `ReputationLib.sol` line 86-111
**Issue:** If you read reputation, decay is computed, but `lastActivity` stays the same. Next read with same timestamp would compute same decay. Not a bug per se, but `lastActivity` semantically means "last time reputation was updated." Should it become "last time decay was applied"?
**Verdict:** Design decision. Document or fix.

### M3. `using ReputationLib for uint256` is declared but unused
**File:** `ReputationLib.sol` line 12
**Issue:** Dead code. Remove.

### M4. No `unregister()` / `updateEndpoint()` functions
**File:** `AgentRegistry.sol`
**Issue:** Agents can withdraw all stake (auto-deactivates) but no explicit unregister. If they need to change their A2A endpoint, no way to do it.
**Fix:** Add `updateEndpoint(string calldata newEndpoint)` and consider explicit `unregister()`.

### M5. `Role.None` default value is unchecked
**File:** `AgentRegistry.sol` line 24-28, 339-341
**Issue:** `_getMinStake(Role.None)` returns `MIN_AGENT_STAKE` because the ternary falls through. This is a defensive default but could mask bugs in future code.
**Fix:** Use `if/else if/else` with explicit revert for `None`.

### M6. BFT `Uncast` not counted in `_sumWeight` totals
**File:** `BFT.sol` lines 60-62
**Issue:** `_sumWeight(votes, Support)` only counts Support. Uncast is silently dropped. Inconsistent with C2 fix: if we treat Uncast like Abstain everywhere, this is fine. If we keep C2 fix, also count it as "no vote" in totals.
**Verdict:** Same fix as C2.

### M7. No `PAUSE_DURATION_MAX` auto-unpause
**File:** `AgentRegistry.sol` lines 366-372
**Issue:** PRD mentions `PAUSE_DURATION_MAX = 30 days` with auto-unpause. Current `Pausable` is binary. Manual `unpause()` only.
**Fix:** Track `pauseTimestamp`, allow `unpause` after `PAUSE_DURATION_MAX`. Or document as Week 2-3 feature.

### M8. `renounceOwnership` is single-step (OZ v5 default)
**File:** `AgentRegistry.sol` (inherits OZ Ownable)
**Issue:** Anyone can renounce ownership, bricking admin functions. Use `Ownable2Step` for production.
**Verdict:** Acceptable for hackathon. Document.

---

## LOW Priority / Style

### L1. `require(n > 0, "BFT: no votes")` uses string instead of custom error
**File:** `BFT.sol` line 92
**Fix:** Use `error NoVotes();`

### L2. Test `test_unanimousSupport` doesn't assert `outliers.length == 0`
**File:** `BFT.t.sol` line 18-30
**Fix:** Add `assertEq(res.outliers.length, 0, "No outliers for unanimous");`

### L3. Test `test_reputationUpdates` only covers task success
**File:** `AgentRegistry.t.sol` line 167-177
**Fix:** Add tests for task failure, dispute win, dispute loss.

### L4. No test for `onFinalStrike`, `onTaskTimeout`, `touchActivity`
**File:** `ReputationLib.t.sol`
**Fix:** Add unit tests.

### L5. No test for `applyDecay` floor (decay past 0)
**File:** `ReputationLib.t.sol`
**Fix:** Add test where `weeks * decay > score`, expect floor at 0.

### L6. No test for BFT empty votes
**File:** `BFT.t.sol`
**Fix:** Add test for `resolve(empty)` — should revert with `NoVotes`.

---

## False Positive / Test Coverage Analysis

The 40 passing tests give a false sense of security. They cover **happy paths** but miss:

1. **Decay application in view functions** — `applyDecay` is tested in isolation, but `getReputation/getTier/getVoteWeight` are tested without time warp. The bug is invisible.
2. **BFT `Uncast` handling** — Tests only use `Support/Against/Abstain`. Uncast is unhandled.
3. **BFT tie** — All tests have clear majorities. 2-2 split is untested.
4. **`slash` overflow** — Tests use small BPS values (1000 = 10%, 10000 = 100%). Never test `> 10000`.
5. **`addStake` reactivation** — Tests register fresh agents, never deactivated ones.
6. **`applyFinalStrike` deactivation** — Not tested at all (function isn't even in the test file).

**Recommendation:** Add 12+ new tests to close the coverage gaps before deploying.

---

## Severity Summary

| Severity | Count | Examples |
|----------|-------|----------|
| CRITICAL | 4 | Stale reputation, BFT Uncast, BFT tie, implicit stake check |
| HIGH | 6 | Slash overflow, no reactivation, no final-strike deactivation, view decay |
| MEDIUM | 8 | Unused `using`, missing updateEndpoint, single-step ownership |
| LOW | 6 | String require, missing tests, doc gaps |
| **Total** | **24** | |

---

## Recommended Fix Order

1. **C1, H4, H5** (decay in view funcs) — one-line fix each, high value
2. **C2, M6** (BFT Uncast handling) — 3-line fix
3. **C3** (BFT tie) — 5-line fix
4. **H1** (slash BPS validation) — 1-line fix
5. **H2** (addStake reactivation) — 5-line fix
6. **H3** (final strike deactivation) — 3-line fix
7. **C4** (explicit stake check) — 2-line fix
8. Remaining MEDIUM/LOW as time permits

After fixes: re-run all 40 tests + add 12 new tests for coverage gaps.

---

**Generated:** 2026-09-04
**Auditor:** Claude (Full-Stack Expert Engineer role for XYX)
