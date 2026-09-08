# Re-audit report — veQueue / vqALCX

Date: 2026-09-08. Target commit: `5bfb483025e65ab0a88912eda5295849e6bf944c` (identical to the planning baseline; source hashes in `evidence/01-manifest.txt`, `02-hashes.txt`). Executed per `AUDIT_PLAN.md` steps 1–12. This re-audit adds validated findings and a cross-contract adversarial harness on top of the prior audit round in `audit/2026-09-08-astra-interrupted/` and `audit/2026-09-08-verification-astra-interrupted/`.

**Verdict:** No direct theft of user principal was demonstrated; watermark solvency, auction escrow conservation and staking reward conservation held under 3 × 128k-call cross-contract campaigns plus targeted PoCs. However, **one high-severity unprivileged denial-of-service (F-1)** and several medium interface/authority defects (F-2, F-3/F-4/F-5) are confirmed and should be remediated before deployment. This report is not a guarantee of security.

## 1. Scope manifest

- First-party: `src/VqALCX.sol` (537 lines), `src/VqAuctioner.sol` (314), `src/VqStaking.sol` (175). Toolchain: forge 1.5.1-stable, solc 0.8.36 exact. Submodules: OpenZeppelin v5.7.0 (`cab1993`), forge-std v1.16.1 (`620536f`). CI: fmt-check → build --sizes → test -vvv.
- **Deployment inputs: not supplied.** Chain, ALCX/reward-token addresses, DAO framework/version, Safe owners/thresholds, timelocks, treasury, constructor arguments, initial bucket/auction parameters: all unavailable — recorded as a scope limitation (plan step 1). No fork tests were possible; token-behavior assumptions (fees, rebasing, blocklists, callbacks) remain unverified.

## 2. Baseline (plan step 3)

`forge fmt --check` clean; `forge build --sizes` clean; **109 tests pass** in 64 s (seed `0x5bfb483`): 90 pre-existing + 19 re-audit tests. Line coverage (prior round, source unchanged): VqALCX 91.5%, VqAuctioner 90.9%, VqStaking 96.5%. Six `VqStaking` checkpoint tests revert only under coverage instrumentation (`ERC5805FutureLookup`, timepoint==clock) — tool artifact, not a defect (`evidence/06-coverage-note.txt`).

## 3. Findings

Severity reflects demonstrated impact and preconditions. "Validated" = reproduced in `test/audit/reaudit/`.

### F-1 · HIGH · Unprivileged · Vault-wide permanent DoS via dust-request queue spam — validated

`_drip*Bucket` (VqALCX.sol:112-165) iterates one loop per request touched, with no gas bound and no minimum request size. Measured: **10.7M gas for 1000 pending dust requests, 429M for 4000** (`test_F1_DripGasScaling_*`). An attacker spending ~120k gas per request can enqueue ~5000 one-wei deposit requests (~$1–5 of gas at ordinary prices; escrow is 1 wei each, refundable). The next drip after one second of elapsed time must process all of them, exceeding the block gas limit; because every drip-calling entry point (`requestDeposit`, `requestWithdraw`, `deposit`, `mint`, `withdraw`, `redeem`, `drip`, and both `set*BucketParams`, which drip first) reverts atomically and each retry has *more* elapsed time to process, the vault is **permanently bricked**: no new entries, no claims, no parameter changes. Cancelling the spam does not help — cancelled entries still cost one skip-iteration each until `head` passes them, which requires executing the very loop that cannot execute. Waiting worsens the state. The existing invariant handler masks this via `bound(amount, 1e18, ...)` and short campaign horizons.
**Mitigation:** enforce a minimum request size; bound drip work per transaction with persisted progress (partial-drip cursor); and/or add per-account request-count limits plus governance queue compaction (arch.md TD-2). Storage layout: requests are `mapping(uint256 => Request)`; a second cursor field per bucket suffices.

### F-2 · MEDIUM · Governance action · Auctioneer replacement strands in-flight escrow permanently — validated

`mintViaAuction`/`burnViaAuction` (VqALCX.sol:405, 416) require `msg.sender == authorizedAuctioneer`. With locked bids outstanding, `settleDepositRound`/`settleWithdrawRound` by the old auctioneer revert `NotAuctioneer` after the two-step handover (`test_F2_*Strands*Escrow`): 2100e18 ALCX (deposit side) and 2000e18 vqALCX (withdrawal side) remained locked in the old contract. Re-authorization cannot recover: `acceptAuctioneer` must be called *by* the old auctioneer contract, and `VqAuctioner` exposes no entry point that calls it. Funds strand until an external migration path exists (there is none).
**Mitigation:** allow previously-authorized auctioneers to settle (auth by round provenance), or add an escrow migration/sweep callable by the new auctioneer/governance; require deployed auctioneer contracts to implement an `acceptAuctioneer` passthrough operationally.

### F-3 · MEDIUM · Interface (ERC-4626) · `max*` overreports and ignores `receiver` — validated

`maxDeposit`/`maxWithdraw` (VqALCX.sol:259-261, 301-303) (a) use `msg.sender` and ignore the `receiver`/`owner` argument, and (b) sum claimable across *all* of a user's requests, while `deposit`/`mint`/`withdraw`/`redeem` can only claim from a *single* request with `claimable >= amount` (`_findClaimable*`). Result: `maxDeposit == 100e18` while `deposit(100e18)` reverts `RequestNotFulfillable` when the claimable splits 60/40 across two requests (`test_F3_MaxDepositOverreports`). `maxMint`/`maxRedeem` inherit both defects. ERC-4626 integrators (vault aggregators, wallets) will construct failing transactions.
**Mitigation:** either split claims across multiple requests, or cap `max*` at the largest single-request claimable; forward the `receiver`/`owner` parameter.

### F-4 · MEDIUM · Spec non-conformance · Views do not project elapsed drip — validated

All queue progress is persisted only by state-changing calls. `max*`, `depositQueueDepth` and every other view report stale values until someone transacts: after `requestDeposit(60e18)` + `requestDeposit(40e18)` and 10 s elapsed, `maxDeposit(alice)` returns **0** (validated). This contradicts arch.md §8.4 ("any read or write triggers lazy drip"), INV-L-1 ("any vault view … reflects queue state current to block.timestamp") and R-2's mitigation claim ("the queue also advances on reads"). EVM views cannot persist state, so the documented behavior is unimplementable as stated — the spec, not just the code, must change (project drip arithmetically inside views, or re-document).

### F-5 · MEDIUM · Spec non-conformance · Previews are pure identities — validated

`previewDeposit/Mint/Withdraw/Redeem` (VqALCX.sol:263-266, 284-287, 305-308, 331-334) are `pure` 1:1 conversions unrelated to queue state: `previewDeposit(50e18)` returns success-indicating values for a user with nothing claimable, while `deposit(50e18)` reverts (`test_F4_PreviewDoesNotReflectQueue`). arch.md §4.1/§8.1 promise "100% faithful", "no optimistic values" previews; the code cannot honor it. Integrators relying on ERC-4626 previews will mis-price failing calls. Same remediation track as F-4.

### F-6 · LOW · Integration · Non-canonical ERC-6372 clock-mode string — validated

`VqStaking.CLOCK_MODE()` returns `"mode=blockstamp"` (VqStaking.sol:69-71); OZ's canonical timestamp string is `"mode=timestamp"` (`ERC6372Utils.timestampClockMode`). Tooling that validates the mode string (per ERC-6372) will reject the contract (`test_FINT1_ClockModeStringNonstandard`).
**Mitigation:** return `"mode=timestamp"`.

### F-7 · LOW · Design · Zero-staker reward funding misallocates — validated

Rewards donated while `_totalStaked == 0` are not distributed and not held aside: `accrueRewards` skips the update, so the entire backlog credits to whichever account is staked when accrual next succeeds — in tests, 100% to the first staker (`test_FSTAKE1_PreStakeDonationsGoToFirstStaker`). Donations smaller than `totalStaked / 1e18` never accrue at all and strand permanently (`test_SubResolutionDonationsStranded`, 999 wei stranded). Donor intent is violated; no staker loses principal.
**Mitigation:** document; or accrue a carry balance during zero-staker intervals and let governance sweep; or revert dust donations.

### F-8 · LOW · Economic · Auction credit is unbounded, un-expired, and survives rate cuts — validated

`availableAuctionCapacity` accumulates every drip residual with no cap or expiry and is not reduced when governance lowers `rate` (`test_F8_AuctionCreditSurvivesRateCut`). A long-idle vault can therefore offer one oversized instant mint far above the intended per-round envelope `rate × roundDuration`, weakening the governance-rate-limit property the queue exists to enforce. Capital-reserve risk is nil (credit mints only against transferred ALCX).
**Mitigation:** cap credit at `rate × K` at drip time or at consumption time; optionally expire credit on parameter change.

### F-9 · INFO · Sequencing · Cancellation does not persist elapsed drip — validated

`cancelDepositRequest`/`cancelWithdrawRequest` do not drip first. Fulfillment accrued since the last drip is refunded as principal and the equivalent allocation converts to auction credit (`test_PartialFillClaimableAfterCancel`). User-favorable, conservation holds; document as intended or add `_drip` for cleaner accounting.

### F-10 · INFO · Rounding · Accrual floors strand bounded dust — validated

Per-share flooring skips donations below resolution (F-7) and per-user flooring leaves residue in the contract after claims (3001-wei donation → 2×1000 paid, 1001 stuck; `test_RewardConservationAndDust`). Auction settlement splits are exact; deposit/withdraw penalties floor to the user's benefit by < 1 unit. Bounded, favors the protocol/stakers-as-a-body; acceptable.

### F-11 · INFO · Voting semantics · Undelegated stakers hold zero votes — validated

OZ v5.7 `Votes.delegates()` has no self-delegation default: staked-but-undelegated accounts show `getVotes == 0` while `getPastBalanceOf` checkpoints remain correct (validated) — Aragon delegate-override reads work. Operational requirement: users must `delegate` (typically self) for votes to count; the DAO integration must communicate this.

### F-12 · INFO · Documentation · arch.md drift (three confirmed contradictions)

(a) §4.1 says deposit ALCX "transfer happens at `deposit()`" — code escrows in `requestDeposit` (VqALCX.sol:178); (b) §4.1/§8.1 preview-faithfulness claims are false (F-5); (c) INV-L-1 / §8.4 read-time drip claims are false (F-4). Fix arch.md or the code per F-4/F-5 decisions. `README.md` is the stock Foundry template (references a nonexistent `script/Counter.s.sol`).

### F-13 · INFO · Hygiene (prior triage, stands)

`daoTreasury` accepts `address(0)` (premium transfers would brick settlement) and `daoTreasury`/`roundDuration` could be `immutable`. Validate deployment arguments.

### F-14 · INFO · Policy · Pause matrix — validated, confirm intent

Under pause: requests blocked (entry), `mintViaAuction` blocked, but claims (`deposit`/`mint`/`withdraw`/`redeem`) and `burnViaAuction` stay open, and **new `requestWithdraw` is blocked** — exit liveness under pause is claim-only (`test_PauseBlocksEntryKeepsExits`). Consistent with commit `5bfb483`'s intent; confirm the product decision that users cannot *queue* new exits during an incident.

## 4. Validation evidence (plan steps 3, 11)

- **Cross-contract harness** (`test/audit/reaudit/CrossContractInvariant.t.sol`): 4 actors × 15 weighted operations across vault+auctioner+staking with reward funding. Invariants, all passing at 256 runs × 500 calls (seed `0x5bfb483`, zero handler reverts; `evidence/04-campaign.log`):
  - Solvency: `vault ALCX ≥ totalSupply + Σ(filled−claimed) + Σ_noncancelled(amount−filled)`.
  - Auction escrow: `auctioner ALCX == depositLockedTotal(currentRound)` and `auctioner vqALCX == withdrawLockedTotal(currentRound)` — exact equality, both directions, through bids/outbids/partial settles.
  - Staking: `Σ stakes == totalStaked`; custody ≥ recorded stakes; `paid + Σearned ≤ funded`; reward custody ≤ net funding.
  - Non-vacuity: `test_NonVacuousCrossSequence` proves every subsystem executes end-to-end (queue→claim, bid→settle, stake→fund→accrue→claim).
- **Targeted PoCs** (19 tests): F-1 gas scaling, F-2 both directions, F-3/F-4 views, F-5 previews, F-6 clock string, F-7 both misallocations, F-8 credit survival, F-9 sequencing, F-10 dust, F-11 checkpoints, F-14 pause matrix, plus regression confirmation of partial-fill-claimable-after-cancel.
- **Not re-run:** Slither (not installable here; prior `slither.json` + triage reused — source unchanged), fork tests (no deployment inputs). Longer campaigns recommended in CI before deployment (e.g., 10k+ runs, multi-seed).

## 5. Remediation status and recommendation

No remediation has occurred this round (target unchanged from planning baseline). Required before deployment, in order: F-1 (DoS), F-2 (escrow stranding), F-3/F-4/F-5 (ERC-4626 posture decision + spec fixes), F-6; document or accept F-7/F-8/F-14 with the owner; fix F-12 docs. A release recommendation additionally requires the deployment-input review that remains impossible until chain/token/DAO/Safe configuration is supplied (plan steps 1, 10).

## 6. Evidence index

| Item | Path |
|---|---|
| Manifest, hashes, toolchain | `evidence/01-manifest.txt`, `evidence/02-hashes.txt` |
| Baseline build/fmt | `evidence/03-baseline-build.txt` |
| Campaign log (seed, selector tables) | `evidence/04-campaign.log` |
| Coverage log + artifact note | `evidence/05-coverage.log`, `evidence/06-coverage-note.txt` |
| Requirements disposition (step 2) | `reviews/STEP2-requirements-disposition.md` |
| Track reviews (steps 4–10) | `reviews/STEPS4-10-reviews.md` |
| Reproductions | `test/audit/reaudit/` (run: `forge test --match-path "test/audit/reaudit/*"`) |
| Prior-round documents reused | `audit/2026-09-08-astra-interrupted/REQUIREMENTS.md`, `MONEY_MAP.md`, `audit/2026-09-08-verification-astra-interrupted/reviews/` |
