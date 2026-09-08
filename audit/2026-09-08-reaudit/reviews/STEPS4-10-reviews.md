# Steps 4–10 — Review-track evidence notes (re-audit 2026-09-08)

Target `5bfb483`. Validation tests: `test/audit/reaudit/*`. Campaign evidence: [../evidence/04-campaign.log](../evidence/04-campaign.log).

## Step 4 — Money map

Prior map at [../../2026-09-08-astra-interrupted/MONEY_MAP.md](../../2026-09-08-astra-interrupted/MONEY_MAP.md) reconciles with code; corrections/extensions confirmed this round:

- `cancelDepositRequest` does **not** drip first (it has no `_drip`). Fulfillment that elapsed since the last drip is refunded as principal and the equivalent rate allocation converts to auction credit. No loss; user-favorable sequencing (F-9, validated).
- Liability formula used by the solvency invariant: `Σ_all requests (filled − claimed)` + `Σ_noncancelled (amount − filled)`; cancelled requests retain `filled − claimed` as a live claim because `deposit()` does not check `cancelled`.
- `withdraw` escrow is share-custody (already inside `totalSupply`); ALCX backing for it is the same 1:1 pool.

## Step 5 — Vault custody and ERC-4626

- `claimed <= filled <= amount` holds on all paths; double claims impossible (`claimed` monotone, scan requires `claimable >= amount`).
- Sender/receiver/owner separation correct on `withdraw`/`redeem` (`_spendAllowance` only when `msg.sender != owner`).
- `max*` findings F-3 and F-4 validated. `totalAssets()` returns raw balance (includes profit + unclaimed deposit principal) while conversions are pure 1:1 — integrators computing `assets = shares * totalAssets / totalSupply` overestimate; documented integrator hazard, no on-chain impact.
- Inflation attack impossible by construction: conversion is hardcoded, first deposits mint only against escrowed principal.
- Reentrancy: all state-changing entry points guarded except `mintViaAuction`/`burnViaAuction` (auctioneer-gated); their external calls occur after storage effects; benign for non-callback tokens (callback tokens out of scope, see limitations).

## Step 6 — Queues, shared capacity, liveness

- Drip arithmetic conserves the time-integrated budget; `head <= tail` holds; FIFO fulfillment order correct; cancelled/satisfied entries skip without consuming budget.
- **F-1 (HIGH) validated:** drip cost is linear in requests touched (10.7M gas @ 1000 dust requests, 429M @ 4000 in `test_F1_DripGasScaling_*`). A ~$1 spam of ~5000 dust requests (each ~120k gas, 1 wei escrow) permanently reverts every drip-calling entry point: `requestDeposit`, `requestWithdraw`, `deposit`, `mint`, `withdraw`, `redeem`, `drip`, and both `set*BucketParams` (all drip first). Waiting worsens it; cancelled entries still cost one skip-iteration each, so self-healing does not occur. Existing invariant handler masks this via `bound(amount, 1e18, ...)` and short campaign horizons.
- Rate/capacity changes drip first; `capacity >= pendingAmount` enforced; accrued credit survives rate cuts (F-8).

## Step 7 — Auction escrow and settlement

- Escrow conservation is exact in both directions (`invariant_AuctionEscrowConservation`, equality, 128k calls): refunds, self-replacement, pro-rata partial settlement, treasury premium, and winner refunds all reconcile with zero dust.
- `payout <= fill` guaranteed structurally (`minPrice <= amount` at bid time); `PayoutExceedsBurn` backstop present.
- Failed/settled rounds roll over; `ensure*` is permissionless so expired rounds are unstickable by anyone (liveness OK apart from F-2).
- **F-2 (MEDIUM) validated:** replacing the auctioneer with locked bids outstanding makes both settlement paths revert (`NotAuctioneer`); `VqAuctioner` exposes no entry point that calls `acceptAuctioneer`, so the old contract can never be re-authorized; escrow is stranded (2100e18 ALCX / 2000e18 vqALCX in the PoCs).

## Step 8 — Staking and voting

- Reward accounting: `accrueRewards` credits the whole balance delta; `claimRewards` decrements `_lastRewardBalance` so deltas stay correct; conservation validated (`paid + Σearned <= funded`, `custody <= net funding`, 128k calls).
- **F-7 (LOW) validated:** donations while `totalStaked == 0` accrue in full to the first staker; donations smaller than `totalStaked / 1e18` never accrue and strand.
- `earned()` staleness until someone accrues (validated); standard masterchef-style behavior, documented for integrators.
- Voting: undelegated stakers have zero `getVotes` (OZ v5 `delegates()` has no self-default) while `getPastBalanceOf` checkpoints are maintained regardless — Aragon `GovernorCountingOverridable` override path works; `_transferVotingUnits` after balance updates per TC-5. `clock()` is timestamp (TC-3) but `CLOCK_MODE()` string is nonstandard (F-6).

## Step 9 — Authority and lifecycle

- Permission matrix verified: only governance can set params/penalty/pause/propose; only auctioneer can mint/burn via auction; two-step handovers verified including auctioneer acceptance by the proposed address.
- `mintViaAuction` is pause-guarded, `burnViaAuction` deliberately is not; `deposit`/`mint` claims stay open under pause (commit 5bfb483 intent). New `requestWithdraw` **is** blocked under pause — exit liveness under pause is claim-only (F-14).
- Constructor: zero asset/governance rejected; zero auctioneer allowed (documented bootstrap); `daoTreasury` unvalidated (zero address would brick premium transfers — prior triage, stands).

## Step 10 — Tokens, dependencies, delivery

- Dependency pins unchanged from prior round: OZ v5.7.0 (`cab1993`), forge-std v1.16.1 (`620536f`), solc 0.8.36 exact. Prior advisory triage ([../../2026-09-08-verification/reviews/DEPENDENCIES.md](../../2026-09-08-verification/reviews/DEPENDENCIES.md)) applies unchanged — commit identical.
- OZ v5.7 `Votes`/`VotesExtended`/`ERC6372Utils` vendored behavior verified against source during this round (delegate resolution, checkpoint semantics, canonical clock-mode strings).
- Slither not installable in this re-audit environment; prior `slither.json` + triage reused (source unchanged, hash-verified in `01-manifest.txt`).
- Token behavior (fees/rebasing/blocklist) remains unverified: actual ALCX/reward-token addresses not supplied. Fee-on-transfer would break 1:1 escrow assumptions in vault and auctioner; rebasing would break checkpoint accounting. Recommend acceptance tests before deployment.
- CI: fmt --check clean, build --sizes clean, tests green (109 tests, seed `0x5bfb483`, 64s).
