# ClawdSearch Contract Audit — Stage 3 Report

**Job:** LeftClaw #93 — "Clawd Search"
**Auditor:** clawdbotatg (automated stage)
**Scope:** `packages/foundry/contracts/ClawdSearch.sol`, `packages/foundry/script/DeployClawdSearch.s.sol`, `packages/foundry/script/Deploy.s.sol`, `packages/foundry/test/ClawdSearch.t.sol`
**Commit at audit time:** see `git log -1` at audit timestamp.

---

## Executive Summary

The `ClawdSearch` contract is well-structured, well-documented, and faithfully implements the on-chain spec (three-category lobster king-of-the-hill, 50/50 burn/treasury split with odd-remainder to burn, 48-hour challenge windows, 1-hour cooldowns, per-category loser lockout, Ownable2Step admin, hardcoded CLAWD token at `0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07`). Game-logic invariants — tie-to-defender, zero-vote-to-challenger, hasVoted round-scoping, lazy reign-second accounting, cross-category isolation, deploy-time owner = JOB_CLIENT — were traced end-to-end and are correct. No Critical or High findings.

The five Medium findings are all about defense-in-depth or test coverage gaps rather than active bugs. The Low findings are documentation, gas, and event-indexing polish.

### Findings by severity

| Severity | Count | Filed as GH issue |
|----------|-------|-------------------|
| Critical | 0     | —                 |
| High     | 0     | —                 |
| Medium   | 5     | #1–#5             |
| Low      | 8     | (in this report)  |
| Info     | 5     | (in this report)  |

---

## Medium Findings (filed as GitHub issues)

### M-1 — CEI violation: external CLAWD transfer precedes state writes
**GitHub:** [#1](https://github.com/clawdbotatg/leftclaw-service-job-93/issues/1)
**Location:** `ClawdSearch.sol:178` (`submit`), `:208` (`challenge`), `:236` (`vote`)
**Description:** All three player entry points call `_spendClawd(...)` before writing the state that gates the function (`championObsId`, `challengerObsId`, `hasVoted`). CLAWD is hardcoded as immutable to a specific deployed ERC20 with no transfer hooks today, so reentrancy is not realistically exploitable now — but the trust assumption is implicit and undocumented, and a single `nonReentrant` modifier eliminates the entire class for trivial gas cost.
**Recommendation:** Add `ReentrancyGuard` and apply `nonReentrant` to `submit`, `challenge`, `vote`, `resolve`. Alternatively reorder writes before transfers. Document the CLAWD trust assumption in NatSpec either way.

### M-2 — `renounceOwnership` not overridden — accidental call permanently bricks admin
**GitHub:** [#2](https://github.com/clawdbotatg/leftclaw-service-job-93/issues/2)
**Location:** `ClawdSearch.sol:33` (contract definition; `Ownable2Step` inherited)
**Description:** OZ `Ownable2Step` v5 inherits the one-step `renounceOwnership` from `Ownable`. A single accidental or compromised call by the owner irrevocably zeros the owner — `setTreasury` and `setPrices` become permanently uncallable. There is no upside to renouncement for a config-only admin role; downside is permanent loss of treasury reconfigurability.
**Recommendation:** Override `renounceOwnership` to revert.

### M-3 — Missing test for odd-amount burn/treasury split
**GitHub:** [#3](https://github.com/clawdbotatg/leftclaw-service-job-93/issues/3)
**Location:** `ClawdSearch.t.sol` (no test case)
**Description:** Spec and NatSpec explicitly state odd-remainder goes to burn (e.g. 101 → 51 burn, 50 treasury). All current test prices are even multiples of 100×1e18, so the only path tested is the symmetric split. A swap of the rounding direction in `_spendClawd` would not be caught.
**Recommendation:** Add a test that calls `setPrices(101, 0, 0)` (or any odd value), executes a spend, and asserts `BURN_ADDRESS` increases by 51 while `TREASURY` increases by 50.

### M-4 — Missing test for hasVoted round-scoping across consecutive challenges
**GitHub:** [#4](https://github.com/clawdbotatg/leftclaw-service-job-93/issues/4)
**Location:** `ClawdSearch.t.sol` (no test case)
**Description:** The `hasVoted` mapping is keyed by `challengeRound` so voters can re-vote in subsequent rounds. No existing test has a single voter participate in two consecutive challenge rounds in the same category. A regression that dropped the round dimension would silently lock voters out forever.
**Recommendation:** Add a test in which carol votes in round 1, the challenge resolves, a new challenge opens (round 2), and carol votes again successfully.

### M-5 — Missing tests for SafeERC20 revert paths and price-change behavior
**GitHub:** [#5](https://github.com/clawdbotatg/leftclaw-service-job-93/issues/5)
**Location:** `ClawdSearch.t.sol`
**Description:** Insufficient allowance, insufficient balance, `setPrices` actually affecting subsequent spend amounts, `setTreasury` actually routing subsequent payments, and exact event-content assertions are all uncovered. The current admin tests only verify storage-variable changes, not behavioral changes.
**Recommendation:** Add per-revert-path tests, plus end-to-end tests that change admin params and verify the next user action reflects the change. Use `vm.expectEmit` for event-content verification on `ChampionCrowned`, `ChallengeStarted`, `VoteCast`, `ChallengeResolved`.

---

## Low Findings (in-report only — no issue filed)

### L-1 — Constructor zero-address check is unreachable
**Location:** `ClawdSearch.sol:158`
**Description:** `Ownable(initialOwner)` (OZ v5, `lib/openzeppelin-contracts/contracts/access/Ownable.sol:38-43`) reverts with `OwnableInvalidOwner(address(0))` before the body of the `ClawdSearch` constructor runs. The explicit `if (initialOwner == address(0)) revert ZeroAddress();` is therefore dead code; the `ZeroAddress` selector is never produced from this path.
**Recommendation:** Either remove the dead check (and document the OZ-provided check in NatSpec), or keep it for clarity but acknowledge it as belt-and-suspenders. Consider whether the `ZeroAddress` custom error is still needed (it is — used in `setTreasury`).

### L-2 — Constructor sets treasury and default prices but emits no events
**Location:** `ClawdSearch.sol:160` (treasury) and `:60-66` (default prices)
**Description:** Off-chain indexers/frontends that reconstruct treasury history from `TreasuryUpdated` events will miss the initial value `0x90eF…`. Same for indexers tracking price history from `PricesUpdated` — they will never see the initial `1000/100/100 * 1e18` defaults. They have to hard-code or fall back to a `treasury()` / `submitPrice()` call.
**Recommendation:** Emit `TreasuryUpdated(treasury)` and `PricesUpdated(submitPrice, challengePrice, votePrice)` from the constructor.

### L-3 — `observationId` not indexed in events
**Location:** `ClawdSearch.sol:119` (`ChampionCrowned`), `:120` (`ChallengeStarted`), `:122-128` (`ChallengeResolved`)
**Description:** Frontends that want "show me the history of obs 42" (per-lobster pages) must scan all logs and filter client-side rather than using `topics[N]` filtering. This is an obvious frontend access pattern for a leaderboard dApp.
**Recommendation:** Mark `observationId` / `challengerObsId` / `winnerObsId` as `indexed`. Solidity allows up to three indexed parameters per event; current events have at most two indexed fields, so there's room.

### L-4 — `_spendClawd` does two separate `safeTransferFrom` calls (gas)
**Location:** `ClawdSearch.sol:388-391`
**Description:** Two transferFroms = two SLOADs (allowance) + two SSTOREs (balances) + two events on the CLAWD token. A single `safeTransferFrom` to a "splitter" address, or pulling the full amount to `address(this)` and then doing two `safeTransfer`s, doesn't actually save gas (still two SSTOREs on balances). The current pattern is the cleanest defensible design — flagging only as Info-grade gas note. **Not a bug; document and move on.** Demoted from Low to Info on reflection — kept here for completeness.

### L-5 — `categoryChampionWins` semantics deviation from spec literal
**Location:** `ClawdSearch.sol:101-103`, NatSpec at `:24-28`
**Description:** Spec described this counter as "total wins for leaderboard." The implementation increments it for the *winning side of every resolve* (both successful defenses and successful overthrows). NatSpec documents the deviation. Worth confirming with the client that the leaderboard metric they want is "successful resolves while champion or as a champion-flip" rather than e.g. "number of times this obsId became champion." Both are defensible; the client should confirm the semantic.
**Recommendation:** Confirm the metric with the client. If they prefer "championship acquisitions" only, change to increment only on flip + on first submit. If they're happy with current behavior, no code change needed — keep the explicit NatSpec.

### L-6 — No view function for "current reign duration"
**Location:** `ClawdSearch.sol` (no such view)
**Description:** Reign seconds are credited lazily — only when a champion is overthrown. A frontend that wants to display "alice has reigned for X hours" must compute `block.timestamp - cat.reignStart` itself. A small view helper would be ergonomic.
**Recommendation:** Add `function currentReignSeconds(Category) external view returns (uint256)` returning `block.timestamp - reignStart`. Pure UX nicety.

### L-7 — Test scaffolding uses `vm.etch` without running the constructor
**Location:** `ClawdSearch.t.sol:43-58`
**Description:** `vm.etch(CLAWD_ADDR, rt)` copies runtime bytecode but does *not* execute the constructor at the etched address, so `_name` / `_symbol` are empty strings at `CLAWD_ADDR`. Tests don't read those fields, so this is harmless today, but it's a brittle pattern. `forge`'s `deployCodeTo` (cheatcode) would deploy MockClawd's bytecode at `CLAWD_ADDR` *with constructor execution*, giving correct name/symbol. Or, mock with `vm.mockCall` for each ERC20 call.
**Recommendation:** Switch to `deployCodeTo` for clarity. Low priority; current tests are functionally correct.

### L-8 — `setPrices(0, 0, 0)` makes the contract free; no event nuance
**Location:** `ClawdSearch.sol:347-352`, NatSpec at `:31`
**Description:** Documented as intentional ("promotional period"). Worth noting that during a free period, sybils can submit/challenge/vote at zero cost — game integrity depends on off-chain throttling. Spec accepts this.
**Recommendation:** No code change. Consider mentioning in user-facing docs that "free mode" disables sybil cost.

---

## Info Findings

### I-1 — CLAWD token is hardcoded; no upgrade path
The contract cannot be redirected to a different payment token. If CLAWD is replaced by a v2 token, this contract becomes obsolete (a fresh deployment is required). Acceptable for a one-shot prototype; flag for client awareness.

### I-2 — `block.timestamp` casts to `uint64`
Safe until year ~584,554,531,141 AD. Not a concern.

### I-3 — `unchecked` blocks on uint128/uint256 counters
`championsSubmitted`, `challengesWon` (uint128) and `totalReignSeconds`, `categoryChampionWins`, `challengeRound` (uint256/uint64) all have realistic-overflow margins of millennia or more. The `unchecked` annotations are correct gas optimizations.

### I-4 — Front-running / vote-sniping
Public votes mean the last vote in a tight race can be front-run. Spec accepts this (each vote costs CLAWD, so cost-to-grief scales). No action needed.

### I-5 — CLAWD pause / blacklist risk
If the CLAWD ERC20 ever adds a pause or blacklist mechanism, payments will fail and the tournament freezes. There is no escape hatch (e.g., admin pause). This is consistent with "trustless tournament" framing; flag for client awareness.

---

## Logic Trace — Verified Invariants

I walked these end-to-end against the on-chain spec; all PASS.

| Invariant | Status | Evidence |
|-----------|--------|----------|
| Owner = JOB_CLIENT (`0xC99F…8A19`) at deploy | PASS | `DeployClawdSearch.s.sol:17, :20` passes JOB_CLIENT to constructor; `Ownable(initialOwner)` (OZ v5) sets `_owner = JOB_CLIENT` immediately. No two-step "accept" needed for initial owner. |
| Treasury initialized to `0x90eF…aEd0` | PASS | `ClawdSearch.sol:160` |
| 50/50 burn/treasury split, odd to burn | PASS | `ClawdSearch.sol:386-388` — `treasuryAmount = amount/2; burnAmount = amount - treasuryAmount;` |
| Submit price 1000 CLAWD; challenge/vote 100 each | PASS | `ClawdSearch.sol:60-66` |
| Tie goes to defender | PASS | `ClawdSearch.sol:280` — `challengerWins = challengerVotes > championVotes` (strict `>`) |
| Zero-zero goes to challenger | PASS | `ClawdSearch.sol:277-281` — explicit special case |
| Loser lockout per category only | PASS | `ClawdSearch.sol:314` — `hasLostInCategory[category][loserObsId] = true`; cross-category loser test in `test_resolve_loserLockedOutCategoryButCanPlayOthers` |
| Same lobster CAN win multiple categories | PASS | `championObsId` is per-category mapping; no global lockout |
| First challenger sees `cooldownEnd = 0`; passes `block.timestamp >= 0` check | PASS | Default-zero storage; `challenge` line 204: `if (block.timestamp < cat.cooldownEnd) revert OnCooldown();` — `0 < 0` is false, passes |
| Cooldown applies AFTER first resolve | PASS | `resolve` line 317: `cat.cooldownEnd = uint64(block.timestamp + COOLDOWN);` |
| Outgoing champion's reign credited on overthrow | PASS | `resolve` lines 293-295 |
| Defender's reignStart unchanged on successful defense | PASS | `resolve` line 308 — comment + no write |
| `hasVoted` keyed by `(category, round, voter)`, round increments at challenge OPEN | PASS | `challenge` line 216 increments BEFORE next vote can occur; `vote` line 234 reads current round |
| `cat.championVotes` / `challengerVotes` reset at challenge open AND at resolve | PASS | `challenge` lines 213-214 + `resolve` lines 320-321 (defense in depth) |
| Cannot resolve without active challenge | PASS | `resolve` line 261 — `if (cat.challengerObsId == 0) revert ChallengeNotActive();` |
| Cannot resolve before window closes | PASS | `resolve` line 262 |
| Cannot vote outside window | PASS | `vote` line 231 |
| Cannot challenge while one is active | PASS | `challenge` line 203 |
| Cannot challenge with same obsId as current champion | PASS | `challenge` line 206 |
| Cannot submit if category already has champion | PASS | `submit` line 176 |
| Boundary: at exactly `challengeStart + DURATION`, vote reverts (`>=`) and resolve passes (`<` no longer holds) — mutually exclusive | PASS | `vote:231` uses `>=`; `resolve:262` uses `<` |
| Events: `ChallengeResolved` fires on every resolve; `ChampionCrowned` fires on first submit AND on flip but NOT on successful defense | PASS | `resolve:324, 325-327` — verified by `test_resolve_emitsChampionCrownedOnlyWhenChampionChanges` |
| Vote tallies snapshotted before clearing in `ChallengeResolved` | PASS | `resolve` lines 271-272 capture before clear at lines 320-321 |
| `categoryChampionWins[category][winnerObsId]` ticks on every resolve | PASS | `resolve:312` |
| `userStats.challengesWon` ticks only when challenger wins | PASS | `resolve:296-298` (inside `if (challengerWins)`) |

---

## Deploy Script Verification

`packages/foundry/script/DeployClawdSearch.s.sol`:
- ✓ Hardcodes JOB_CLIENT = `0xC99F74bC7c065d8c51BD724Da898d44F775a8a19`.
- ✓ Passes JOB_CLIENT directly to `ClawdSearch` constructor — deployer never holds ownership.
- ✓ Pushes deployment to `deployments[]` so SE2 ABI export and `yarn verify --network base` pick it up.
- ✓ Inherits `ScaffoldETHDeploy` and uses `ScaffoldEthDeployerRunner` modifier — standard SE2 pattern.

`packages/foundry/script/Deploy.s.sol`:
- ✓ Instantiates `DeployClawdSearch` and calls `.run()`.
- ✓ No other contracts being deployed (YourContract removed — confirmed only `ClawdSearch.sol` exists in `contracts/`).

**No deploy-script issues found.** `yarn verify --network base` should work as the deployment file is registered correctly.

---

## Top 3 Items the Fix Stage Must Address

1. **#2 (M-2): override `renounceOwnership` to revert.** Single-line override; biggest leverage for permanent-state-protection.
2. **#1 (M-1): add `ReentrancyGuard.nonReentrant` to `submit`, `challenge`, `vote`, `resolve` AND document the CLAWD trust assumption in the contract NatSpec header.** Cheap, defensive, removes an entire class.
3. **#3 + #4 + #5 (M-3, M-4, M-5): add the missing test cases.** Specifically the odd-split test, the hasVoted-across-rounds test, and the "setPrices/setTreasury actually changes future spends" tests. These are pure additions, no source-contract changes required, and they cover invariants the current suite leaves blind.

The Low findings are nice-to-haves; **L-2 (constructor events) and L-3 (indexed observationId)** are also low-hanging and ship-quality polish I'd recommend bundling into the fix stage.

---

## Test Recommendations Summary

- ADD: odd-amount split test (M-3).
- ADD: hasVoted round-scoping cross-round test (M-4).
- ADD: insufficient-allowance and insufficient-balance revert tests (M-5).
- ADD: end-to-end behavior tests for `setPrices` and `setTreasury` (not just storage-set assertions) (M-5).
- ADD: `vm.expectEmit` content assertions on all four player-facing events (M-5).
- OPTIONAL: rewrite `vm.etch` setup using `deployCodeTo` for cleaner mock construction (L-7).
- OPTIONAL: add a fork test against the real CLAWD on Base mainnet for one happy-path submit/challenge/resolve cycle. Not required for prototype but a strong signal-of-correctness if added.

---

*End of report.*

---

## Stage 4 Resolution

Every Medium / Low / Info finding from the audit above has been triaged and resolved as documented below. After all changes:

- `forge build` exits 0 (compilation successful, three pre-existing `unsafe-typecast` lints retained — unrelated to audit findings).
- `forge test` exits 0 — **41 tests passing** (28 original + 13 added in this stage), 0 failures, 0 skipped.

### Medium findings

#### M-1 — CEI violation / reentrancy defense in depth
**Resolution:** FIXED.
- Inherited `ReentrancyGuard` and applied `nonReentrant` to `submit`, `challenge`, `vote`, and `resolve` (`ClawdSearch.sol`).
- Reordered every state mutation in `submit`, `challenge`, and `vote` to occur BEFORE the external `_spendClawd` call (proper Checks-Effects-Interactions). The `nonReentrant` modifier is now belt-and-suspenders.
- Added a NatSpec block at the contract header explicitly documenting the CLAWD trust assumption (vetted standard ERC20, no transfer hooks, no fee-on-transfer, no callbacks).
- All existing tests continue to pass — re-ordering writes did not regress any invariant.

#### M-2 — `renounceOwnership` not overridden
**Resolution:** FIXED.
- Added `error OwnershipCannotBeRenounced();` and overrode `renounceOwnership()` to revert with that error.
- The override is `public view override onlyOwner` so the standard owner-check fires for non-owner callers (preserving the OZ behavior of `OwnableUnauthorizedAccount` for non-owners).
- Added two new tests: `test_renounceOwnership_revertsForOwner` and `test_renounceOwnership_revertsForNonOwner`.

#### M-3 — Missing test for odd-amount burn/treasury split
**Resolution:** FIXED.
- Added `test_oddAmountSplit_burnGetsLargerHalf` which sets `submitPrice = 101` (wei), runs a single submit, and asserts BURN_ADDRESS gained 51 while TREASURY gained 50.

#### M-4 — Missing test for `hasVoted` round-scoping
**Resolution:** FIXED.
- Added `test_hasVoted_roundScopingAcrossConsecutiveChallenges` covering: carol votes in round 1, resolve fires, a new challenge opens (round 2), carol votes again successfully. Round-1 storage remains true (per-round independence) and a second vote inside round 2 reverts with `AlreadyVoted`.

#### M-5 — Missing tests for SafeERC20 reverts and price-change behavior
**Resolution:** FIXED.
- `test_submit_revertsOnInsufficientAllowance` — drops alice's allowance below `submitPrice` and asserts the call reverts.
- `test_submit_revertsOnInsufficientBalance` — drains alice's balance and asserts the call reverts.
- `test_setPrices_zeroAllowsFullCycleWithoutPaying` — sets `(0,0,0)`, drains all four participants, and runs a full submit/challenge/vote/resolve cycle without any CLAWD movement.
- `test_setTreasury_routesNextSpendToNewAddress` — sets a new treasury, runs a submit, asserts new treasury gained 500 CLAWD and old treasury was untouched.
- `vm.expectEmit` field-level matching tests for all four player-facing events: `test_emit_championCrowned_onSubmit`, `test_emit_challengeStarted_onChallenge`, `test_emit_voteCast_onVote`, `test_emit_challengeResolved_onResolve`.

### Low findings

#### L-1 — Constructor zero-address check is unreachable
**Resolution:** WON'T FIX (kept as belt-and-suspenders).
- The OZ `Ownable(initialOwner)` check fires first; the explicit `if (initialOwner == address(0)) revert ZeroAddress();` is unreachable. We KEEP the check as defensive code (and added a NatSpec note explaining it's belt-and-suspenders) — the `ZeroAddress` selector is still used by `setTreasury`, so the error remains live. Removing the check would save trivial bytecode but obscures intent. Cost: dead branch in the constructor; benefit: explicit documentation that zero-owner is forbidden.

#### L-2 — Constructor sets treasury and default prices but emits no events
**Resolution:** FIXED.
- Constructor now emits `TreasuryUpdated(treasury)` and `PricesUpdated(submitPrice, challengePrice, votePrice)` after assignment.
- Added `test_constructor_emitsInitialConfigEvents` verifying both events are emitted with the correct values from a fresh deployment.

#### L-3 — `observationId` not indexed in events
**Resolution:** FIXED.
- `ChampionCrowned`: now indexes `category`, `observationId`, `submitter` (3 indexed — fits).
- `ChallengeStarted`: now indexes `category`, `challengerObsId`, `challenger` (3 indexed — fits).
- `ChallengeResolved`: now indexes `category`, `winnerObsId`, `winner` (3 indexed — fits). `championVotes` and `challengerVotes` remain in non-indexed data (frontends typically need values directly, not as filters).
- `VoteCast` unchanged — it had only 2 indexed (`category`, `voter`); the third field is `bool forChallenger` which is more useful as data.

#### L-4 — `_spendClawd` does two `safeTransferFrom` calls
**Resolution:** WON'T FIX. The auditor self-demoted this to Info-grade and confirmed that consolidating the calls would not save SSTOREs on the token contract (still two balance writes regardless). The current pattern is the cleanest defensible design.

#### L-5 — `categoryChampionWins` semantics deviation from spec literal
**Resolution:** WON'T FIX (no code change).
- NatSpec already documents the metric. Re-reading the spec, "total wins for leaderboard" most naturally maps to "total successful resolves while in possession of the throne," which is what the implementation counts. Confirming with the client would require a round-trip outside this stage's scope; the documented behavior is defensible and the dApp can present the metric accurately.

#### L-6 — No view function for "current reign duration"
**Resolution:** WON'T FIX in this stage.
- Pure UX nicety. The frontend can compute `block.timestamp - cat.reignStart` from `getCategory()` directly. Adding a view function would require touching the contract surface for zero on-chain benefit; defer to a frontend helper.

#### L-7 — Test scaffolding uses `vm.etch` without running constructor
**Resolution:** WON'T FIX in this stage.
- Tests are functionally correct (no test reads `_name`/`_symbol` from `CLAWD_ADDR`). Switching to `deployCodeTo` is invasive — would change the entire test setUp pattern and potentially destabilize the existing 28-test suite. Defer until a future test-quality pass.

#### L-8 — `setPrices(0, 0, 0)` makes the contract free
**Resolution:** ACKNOWLEDGED, no code change.
- Documented as intentional. The new `test_setPrices_zeroAllowsFullCycleWithoutPaying` test now codifies this behavior. Sybil-resistance during free periods is an off-chain concern, consistent with the spec.

### Info findings

#### I-1 — CLAWD token hardcoded; no upgrade path
**Resolution:** ACKNOWLEDGED. No on-chain upgrade path is desirable for a "trustless tournament" framing. Documented in the new contract header NatSpec block.

#### I-2 — `block.timestamp` casts to `uint64`
**Resolution:** ACKNOWLEDGED. Safe well past any realistic operational horizon.

#### I-3 — `unchecked` blocks on counters
**Resolution:** ACKNOWLEDGED. Auditor confirmed the optimizations are correct.

#### I-4 — Front-running / vote-sniping
**Resolution:** ACKNOWLEDGED. Spec-accepted; cost-to-grief scales with vote count.

#### I-5 — CLAWD pause / blacklist risk
**Resolution:** ACKNOWLEDGED. Consistent with the trustless framing. The new contract header NatSpec block covers this assumption.

### Summary table

| ID | Severity | Status | Where |
|----|----------|--------|-------|
| M-1 | Medium | Fixed | `ClawdSearch.sol` (ReentrancyGuard + CEI reordering + NatSpec) |
| M-2 | Medium | Fixed | `ClawdSearch.sol` (`renounceOwnership` override, new error) |
| M-3 | Medium | Fixed | `ClawdSearch.t.sol` (odd-amount split test) |
| M-4 | Medium | Fixed | `ClawdSearch.t.sol` (cross-round hasVoted test) |
| M-5 | Medium | Fixed | `ClawdSearch.t.sol` (allowance/balance reverts, free-cycle, treasury routing, expectEmit on all 4 events) |
| L-1 | Low | Won't fix | Kept as belt-and-suspenders; NatSpec note added |
| L-2 | Low | Fixed | Constructor emits initial config events |
| L-3 | Low | Fixed | Indexed `observationId`/`winnerObsId`/`challengerObsId` on the three resolve/submit/challenge events |
| L-4 | Low | Won't fix | Auditor self-demoted to Info; no real gas savings available |
| L-5 | Low | Won't fix | NatSpec documents deviation; defensible interpretation |
| L-6 | Low | Won't fix | Frontend can compute from `getCategory()` |
| L-7 | Low | Won't fix in this stage | Tests functionally correct; defer to test-quality pass |
| L-8 | Low | Acknowledged | Documented + new test codifies the free-cycle behavior |
| I-1..I-5 | Info | Acknowledged | Trust assumptions documented in contract header NatSpec |

### Test count after Stage 4
- Original: 28 passing.
- Added in Stage 4: 13 (2 for renounceOwnership, 11 in `ClawdSearchAuditFixesTest`).
- **Final: 41 passing, 0 failing, 0 skipped.**

