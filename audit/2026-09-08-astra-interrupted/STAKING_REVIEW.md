# Staking, voting, and reward-token review

Audit target: `5bfb483025e65ab0a88912eda5295849e6bf944c`, `src/VqStaking.sol` lines 1–175. Reviewed 2026-09-08. The repository is private and the contracts are undeployed, as confirmed by the owner. All attack simulations were local. No production source was changed or disclosed.

This track completed source review, imported dependency review, adversarial token simulations, timestamp/delegation tests, and representative OpenZeppelin governance integration. The intended Aragon deployment, token addresses, chain, DAO settings, and approved reward-funding policy were not supplied. Consequently, no deployed-token fork or actual DAO end-to-end assurance is claimed. The money map in `MONEY_MAP.md` supplied provisional accounting oracles; unresolved specification choices remain separate below.

## Results

- Confirmed low-severity interface defect: the timestamp clock advertises an invalid clock mode.
- Confirmed low-severity reward-accounting defect: each accrual permanently discards its global precision remainder. Materiality depends on reward decimals, funding granularity, and stake supply.
- Conditional integration limitations reproduced: negative reward balance changes, reward balance-query failures, extra sender fees, and callbacks before reward-token balance debit can prevent principal exits. No selected production reward token was available to establish these as deployed vulnerabilities.
- Standard exact-transfer token tests preserved principal, reward ownership across cohorts, historical votes, signature nonce/domain protection, and delegate override behavior in the representative pinned OpenZeppelin governor.

## Confirmed defects

### STK-L01 — CLOCK_MODE does not describe the timestamp clock

Severity: Low. Confidence: High. Function: `VqStaking.CLOCK_MODE`. Group key: `VqStaking | CLOCK_MODE | invalid-clock-mode`.

Root cause: `src/VqStaking.sol:70` returns `mode=blockstamp`, although `clock()` at line 65 returns `block.timestamp`. [ERC-6372](https://eips.ethereum.org/EIPS/eip-6372) requires timestamp clocks to return `mode=timestamp`. This also contradicts the architecture's final decision at `arch.md:696`, although the earlier interface sketch repeats the typo.

Internal prerequisites: None. External prerequisites: an integrator relies on the standard descriptor; no particular actual DAO consumer was supplied.

Reproduction:

1. Deploy the staking adapter at timestamp 1,000.
2. Observe `clock() == 1000`, but `CLOCK_MODE() == "mode=blockstamp"`.
3. Deploy the pinned OpenZeppelin `GovernorVotes` consumer. Its `CLOCK_MODE()` forwards the same invalid descriptor unchanged.

Affected parties: governance integrators and tooling cannot identify the clock as timestamp mode using the standard value. The representative governor's on-chain snapshot and override operations still work because they directly use `clock()`; a DAO failure or voting exploit was not inferred from the typo alone.

Minimal mitigation: replace the returned value with `mode=timestamp`, update the existing construction test, and align the architecture sketch. Tests: `test_ClockModeDoesNotDescribeTimestampClock`, both representative governor tests.

Calibration: reachability ALLOWS; no code guard corrects the descriptor; real standard nonconformance; demonstrated financial loss absent. Low, rather than Medium, because actual incompatible DAO/tooling behavior was unavailable.

### STK-L02 — Accrual discards undistributed rewards at every balance checkpoint

Severity: Low under 18-decimal reward assumptions; reassess for low-decimal rewards and frequent small funding. Confidence: High. Function: `VqStaking.accrueRewards`. Group key: `VqStaking | accrueRewards | discarded-global-remainder`.

Root cause: `src/VqStaking.sol:91` floors the global index increment and line 92 records the entire incoming balance as processed. The remainder has no accumulator, claimant, or recovery path. In particular, an increment of zero still consumes all newly observed rewards. The externally callable accrual operation can permanently partition distinct funding arrivals that would be distributable together.

Internal prerequisites: stake supply `S` and funding arrivals `r` for which `r * 1e18 < S`, or any nonzero division remainder. External prerequisites: separate funding transactions provide such amounts; an observer can accrue after each. Exact-transfer, non-rebasing ERC-20s suffice.

Reproduction with two cohorts and the last-user check:

1. At t0, Alice and Bob each stake `1e18` raw stake units (one token each).
2. Across t1 funding events, a donor supplies one raw reward unit 100 times. After each arrival, anyone calls `accrueRewards()`; each index increment is `floor(1 * 1e18 / 2e18) = 0`.
3. At t2, `lastRewardBalance == 100`, the real reward balance is 100, and both users have zero claimable rewards. Alice and Bob completely unstake. A later first staker also cannot claim these 100 units because the balance checkpoint already consumed them.
4. Control: delivering the same 100 units before one accrual with the same two-user stake distribution gives Alice 50 and Bob 50.

Victims: the stakers present during funding permanently lose the 100 raw reward units intended for proportional distribution; neither the attacker nor a later cohort can collect the residue. This is tiny for an 18-decimal token. With `S = 1,000,000e18`, however, each funding smaller than 1,000,000 raw reward units gives a zero increment; this equals one token for a six-decimal reward and 1,000,000 tokens for a zero-decimal reward. A six-decimal token is an ordinary ERC-20 behavior, but none has been selected for this deployment.

Minimal mitigation: retain the unallocated scaled remainder and include it in subsequent index updates, with an explicit policy when stake supply changes or becomes zero. Merely skipping zero increments leaves the nonzero-quotient remainder case unresolved. Use an overflow-safe implementation and test funding fragmentation against batched funding while stake composition stays constant. Higher precision alone reduces, but does not remove, loss.

Tests: `test_AccrualFragmentationPermanentlyStrandsOtherwiseDistributableRewards`. Calibration: code path ALLOWS; externally triggered accrual ALLOWS; other stakers bear loss ALLOWS; repeatable loss demonstrated but practical raw-unit amount is token-dependent. Low is chosen because no material-value funding/token deployment was supplied; do not advertise unrestricted low-decimal compatibility without resolving it.

## Conditional integration limitations and specification observations

These are not elevated to unconditional vulnerabilities in the actual intended deployment. Each is backed by a local reproduction or explicit source reasoning. The distinction is necessary because token addresses and the funding specification are unavailable.

### STK-C01 — Reward balance reduction can freeze unrelated stake principal

Function: `accrueRewards`. Group key: `VqStaking | accrueRewards | negative-balance-delta`.

At `src/VqStaking.sol:89`, `currentBalance - _lastRewardBalance` reverts if rewards decrease independently of a normal claim. Every stake, unstake, and claim calls it via `_updateUserRewards`; notably `unstake` line 126 cannot return the separate vqALCX principal before this calculation succeeds.

Trace: Alice and Bob each stake 10 vqALCX; 100 reward tokens are funded and accrued. A negative rebase or external burn removes one raw reward unit. Both Alice's 10-vqALCX exit and Bob's reward claim revert with arithmetic panic `0x11`. The 20-vqALCX principal remains fully backed but inaccessible. Replacing the missing one reward unit restores Alice's exit. An extra sender fee on a claim produces the same deficit without a rebase: after Alice's 50-token claim plus a five-token sender fee, actual rewards are 45 but the recorded balance is 50; Bob's principal exit fails.

Internal prerequisites: prior positive accrual and remaining stake. External prerequisites: selected reward token permits negative balance changes or additional sender debits. No named production token/configuration is asserted. Conditional impact would be Medium, potentially persistent if the reward balance cannot be restored.

Mitigation options: restrict and verify the immutable reward token to supported exact-debit/non-rebasing semantics; or design explicit loss handling and an independent principal-exit path that does not corrupt surviving users' reward entitlements. Simply clamping the subtraction to zero does not settle the pre-existing reward deficit.

Tests: `test_NegativeRewardBalanceChangeBlocksPrincipalExitUntilRecapitalized`, `test_SenderFeeOnClaimCreatesBalanceDeficitAndBlocksPrincipalExit`.

### STK-C02 — Unguarded accrual during a reward transfer can recredit the outgoing claim

Function: `claimRewards`/external accrual interaction. Primary group key: `VqStaking | claimRewards | callback-recredits-outgoing-reward`.

Root cause: `src/VqStaking.sol:169` reduces the recorded reward balance before line 171 calls the token. If that token invokes `accrueRewards()` before debiting its actual sender balance, the unguarded public function at line 87 sees the outgoing claim as new funding. Guarded `stake`, `unstake`, and `claimRewards` cannot be recursively entered, but `accrueRewards` can.

Trace: Alice and Bob stake one vqALCX each; 100 rewards arrive. Alice claims 50; the ledger first falls from 100 to 50. The token callback observes the old actual balance of 100 and accrues a fictitious 50, restoring the ledger to 100. The token then pays Alice, leaving actual balance 50. Alice is shown another 25 earned, Bob 75, and Bob's next unstake reverts on the negative delta. No additional reward theft beyond this overcredit/DoS was claimed.

External prerequisite: an actual callback before the token's sender-balance debit. The adversarial mock intentionally provides it. A conventional recipient callback after the debit passed the same accounting test; this is not a claim that all ERC-777 recipient hooks break the adapter.

Minimal mitigation: make external accrual a `nonReentrant` wrapper around an internal accrual function, then have already-guarded stake/unstake/claim operations call the internal function. Simply applying `nonReentrant` to the current public function without splitting internal calls would break every guarded caller. Also verify selected reward-token callback semantics.

Tests: `test_PreTransferCallbackRecreditsPaidRewardsAndBlocksOtherStaker`, `test_PostTransferCallbackPreservesAccounting`.

### STK-C03 — A failing reward balance query also prevents principal exits

Function: `unstake` via `_updateUserRewards` and `accrueRewards`. Group key: `VqStaking | unstake | reward-query-exit-dependency`.

At `src/VqStaking.sol:126`, the exit unconditionally invokes the external reward-token `balanceOf` at line 88 before returning principal. Alice stakes 10 vqALCX while the reward token works. If the reward token later reverts from `balanceOf`, Alice's exit reverts even when no rewards were ever funded. Conditional impact: Medium liveness risk, dependent on selected reward-token behavior. This does not follow merely from a token pausing transfers: a transfer-only pause with working `balanceOf` need not block unstaking, as the false-return transfer test demonstrates.

Mitigation: require a reliable verified reward-token implementation and define an independent principal-exit policy for reward accounting failures. Test: `test_RevertingRewardBalanceQueryBlocksPrincipalExit`.

### STK-I01 — Funding with no stakers goes entirely to the next entrant

Function: `accrueRewards`. Group key: `VqStaking | accrueRewards | zero-stake-cohort-policy`. Specification question; no prior eligible staker victim was established.

The `_totalStaked > 0` condition at line 90 leaves zero-stake funding uncheckpointed. At t0, fund 100 rewards with no stakers. At t1, Alice stakes one vqALCX. At t2, Bob stakes 99: Bob's pre-stake update accrues all 100 to Alice. Bob gets zero. After all exit, a new 50-token funding is similarly awarded to the next first staker. Establish whether this is intended, queued funding for future stakers, or donor/treasury property. A zero-stake funding-recovery or delay policy must not confiscate previously earned rewards.

Test: `test_FundingAtZeroStakeBelongsToFirstSubsequentStaker`.

### STK-I02 — Per-user settlement drops fractional entitlement when a user changes stake

Function: `_updateUserRewards`. Group key: `VqStaking | _updateUserRewards | discarded-user-remainder`. Informational/self-harm-only in the supplied API.

Lines 100–101 floor individual rewards and advance the individual index without retaining the fraction. Alice and Bob each stake 0.5 vqALCX. After one raw reward unit arrives, Alice changes stake and loses her half-unit fraction. Repeating the cycle after another unit arrives leaves Alice with zero while passive Bob can claim one. No caller can force another account's user checkpoint through the exposed API, so this was not reported as an unprivileged theft/griefing finding. Retaining individual scaled remainder would avoid the frequency-dependent result if supporting fractional stakes and small reward units.

Test: `test_UserSettlementDropsFractionOnRepeatedStakeChanges`.

### STK-I03 — earned is a stored-accrual view, not a claim preview

Function: `earned`. Group key: `VqStaking | earned | unaccrued-funding-view`. Interface clarification.

Lines 150–154 exclude funding not yet processed by `accrueRewards()`. After Alice stakes one vqALCX and 100 rewards are transferred directly, `earned(alice)` returns zero, but `claimRewards()` immediately pays 100. Specify this behavior or project the current positive balance delta in the view. Do not accidentally introduce the callback/rebase assumptions into a supposedly safe preview.

Test: `test_EarnedExcludesUnaccruedFunding`.

### STK-I04 — Instant stake/unstake and transferable existing shares do not impose an ownership-duration commitment

Functions: `stake`, `unstake`, inherited voting queries. Group key: `VqStaking | stake | governance-duration-assumption`. Explicit design limit; actual DAO lifecycle remains unverified.

At timestamp 1,000, Alice can stake and delegate 100 vqALCX and immediately have 100 current votes. If she unstakes before timestamp advances, a later historical lookup for 1,000 returns zero: same-time checkpoint replacement and future-lookup rejection defeat a same-time flash-loan historical snapshot in the tested consumer.

If Alice remains staked through timestamp 1,000 and exits at 1,001, the historical 100 votes persist. She can transfer the returned 100 existing shares to Bob, who stakes/delegates them immediately at 1,001. Alice's old snapshot weight and Bob's new current weight coexist as expected for different snapshots. The representative governor permits Alice to override her delegate using the old snapshot after she unstaked. This is correct snapshot behavior, but it means proposal-duration exposure is not guaranteed by rate-limited vault mint/redemption alone.

The architecture explicitly permits free transfers and instant unstaking. It also describes a broad governance commitment goal. Reconcile whether the goal concerns new share issuance, current voting units, borrowed existing shares, or holding through execution; assess exact DAO snapshot/delay/quorum and borrowing-market assumptions before claiming governance attack resistance.

Tests: both timestamp history tests and both representative governor override-order tests.

### STK-I05 — Direct stake-token donations are unaccounted surplus

Function: `totalStaked`/custody. Informational specification correction.

Alice stakes five vqALCX; an unsolicited seven-vqALCX donation makes custody 12 while recorded stake and votes remain five. Alice exits five, and seven remain in the adapter with no recovery method. Donations correctly confer no voting power and do not inflate users' stakes. Therefore architecture INV-T-9 should use custody coverage (`recorded stakes <= actual custody`), not unconditional equality. The exact equality holds only when there are no unsolicited transfers. Test: `test_DirectShareDonationDoesNotCreateVotingUnits`.

## Imported dependency review and governance evidence

Reviewed pinned OpenZeppelin git revision `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` (repository pin v5.7.0), specifically:

| Dependency path | Integration conclusion |
|---|---|
| `governance/utils/VotesExtended.sol` | Stake and unstake update internal balances before `_transferVotingUnits`, satisfying the required order. Historical user balances use uint208 checkpoints; delegates use uint160 addresses. |
| `governance/utils/Votes.sol` | Stake mints and unstake burns voting units; direct share donations do neither. Delegation moves the account's current stake. Past-query timepoints must be strictly before `clock()`. |
| `utils/structs/Checkpoints.sol` | Same timestamp overwrites the last checkpoint instead of preserving intermediate flash positions. Backward insertion is rejected. Historical lookup uses the latest checkpoint at or before the requested time. |
| `utils/cryptography/EIP712.sol` | Domain includes name `VqStaking`, version `1`, chain ID, and verifying contract. Chain-ID changes rebuild the cached domain. `eip712Domain` provides introspection; no proxy deployment is present. |
| `utils/cryptography/ECDSA.sol` and `utils/Nonces.sol` | Low-s enforcement and invalid-recovery rejection reviewed. `delegateBySig` consumes the recovered signer's checked nonce, binds delegate/nonce/expiry, rejects expired signatures, and accepts exact expiry. Replay, cross-instance, and cross-chain intended-signer protection tested. |
| `token/ERC20/utils/SafeERC20.sol` | Nonempty false returns fail; empty successful returns from code-bearing contracts are accepted. Transfers bubble token failure atomically. SafeERC20 does not guarantee exact balance movement, benign hooks, or stable `balanceOf`. |
| `utils/ReentrancyGuard.sol` | Stake, unstake, and claim share one guard. Delegation only changes the caller/recovered signer's delegation. Unguarded public accrual creates the conditional callback exposure above. |
| `governance/extensions/GovernorVotes.sol` and `GovernorCountingOverridable.sol` | Representative integration tests use historical balance/delegate checkpoints and reject repeat override. Both delegate-first and override-first paths tally 60 against/40 for from a 60/40 stake distribution. These contracts are a test consumer, not evidence of an actual Aragon deployment. |

A stake of `2^208` raw units reverts at the voting SafeCast bound and restores the user's token balance and all stake totals atomically. Practical vqALCX supply is far below this, but the effective bound should be documented. Historical timepoints are uint48; truncation at year-scale values near `2^48` is outside a realistic deployment horizon. No ERC-1271 contract-wallet delegation-by-signature support is present in inherited `Votes.delegateBySig`; a Safe can call `delegate` directly. This is inherited interface scope, not a signature-bypass finding.

## Reward-token compatibility matrix

No exact reward-token contract was selected for verification. The stake-token column assumes the immutable address is the in-scope VqALCX implementation; deploying the adapter with an arbitrary different token requires another custody review.

| Pattern | Review outcome |
|---|---|
| 1. Transfer hooks | Before-debit callback causes conditional overcredit/DoS; after-debit callback tested safe. Guarded entry-point recursion is blocked. |
| 2. Missing return values | Supported by SafeERC20; reward transfer tested. |
| 3. Recipient fee | Funding credits actual net receipt; payout charges the recipient again. 100 funded externally becomes 90 distributed and 81 received in the 10% mock. Policy must specify net rewards. |
| 4. Balance changes outside transfers | Positive increases become rewards for the current cohort; negative changes can block all stake/reward entry points. |
| 5. Upgradeability | Reward identity/upgrade authority unavailable. An upgrade can invalidate all balance, fee, hook, or liveness assumptions. VqStaking is not upgradeable. |
| 6. Flash minting/borrowing | Existing stake units can be acquired/returned immediately; historical same-time snapshots collapse the intermediate position. Actual liquidity and DAO settings unavailable. |
| 7. Blocklists | A blocked reward receiver cannot claim if transfer rejects; this alone does not block unstaking when `balanceOf` remains available. Contract-level confiscation can create negative-delta freeze. |
| 8. Pausing | Transfer-only reward pause affects claims; balance-query pause can also block principal exit. Actual token behavior unavailable. |
| 9. Zero-before-nonzero approval | Staking does not approve reward tokens; caller-side stake allowance setup remains the caller's responsibility. |
| 10. Approval to zero address | No staking-generated approval call; not applicable. |
| 11. Zero-value approval revert | No staking-generated approval call; not applicable. |
| 12. Zero-value transfer revert | Stake/unstake reject zero; zero reward claims revert before transfer. No zero transfer in these paths. |
| 13. Multiple token addresses/aliases | Constructor only prevents equal addresses, not two wrappers/aliases exposing the same backing balance. Verify immutable token identity; otherwise reward funding may overlap principal. |
| 14. Low decimals | Ordinary tokens with low decimals amplify global/per-user remainder loss. No explicit exclusion or normalization exists. |
| 15. High decimals/large raw supply | Multiplications at lines 91 and 100 are checked but can overflow before division at extreme balances. No realistic selected token establishes reachability. |
| 16. transferFrom self semantics | Adapter transfers from caller to itself with distinct sender/caller addresses. In-scope VqALCX uses normal OZ allowances. |
| 17. Non-string metadata | Staking never queries reward name/symbol/decimals, so metadata type is irrelevant here. |
| 18. Transfer to zero | Stake and reward payouts use the caller, not a user-supplied zero receiver. Wrong immutable addresses remain deployment validation failures. |
| 19. False/no-revert failure | False return tested: reward claim and checkpoint updates roll back. Token must not lie by returning true without intended transfer. |
| 20. Large approval restriction | No adapter-generated approvals; frontends must handle selected stake token if changed from VqALCX. |
| 21. Token-name code injection | Metadata unused in these contracts; no frontend supplied. |
| 22. Unusual permit | Adapter never invokes token permit; delegateBySig is its own EIP-712 delegation API. |
| 23. Transfer less than requested | Reward inbound balance delta sees net funding; outgoing extra debit breaks checkpoint; arbitrary stake token short receipt would overcredit recorded stake. Actual VqALCX has exact transfers. |
| 24. ERC-20 native-asset representation | No native value/payment accounting here. Selected chain/token still needs verification; no dual native/ERC-20 recovery path exists. |

## Distinct review-pass ledger

The assigned lenses were executed as separate passes under the four-agent concurrency limit. They were not claimed to be eight independent reviewers.

| Pass | Questions and result |
|---|---|
| 0xSimao temporal/cohort | [Model: stake] A holder deposits voting assets, retains a recoverable principal claim, and receives funded rewards while participating. [Model: accrual] Actual new reward funding is divided among current stakers; the index and balance checkpoint move. Two-user t0/t1/t2 timelines establish correct pre-join accrual, the zero-stake policy, and precision loss. |
| 0xSimao integration assumptions | [Why: VqStaking.sol:89] Why must every external reward balance never fall except through an exact claim? Broke that assumption with burn, fee, and failed balance query; classified these as conditional because token identity is missing. Reviewed all 24 token patterns above. |
| 0xSimao liquidation/solvency | No borrowing, collateral, health factor, or liquidation exists; those parts are irrelevant. [LastOut: stake/rewards] Standard-token two-cohort claims and both principal exits pay fully in the divisible property domain. Fractional global residues stay in the adapter; negative-delta cases leave even fully backed principal inaccessible. |
| 0xSimao cross-chain/asynchronous state | No bridge, cross-chain messages, proxy, or retry handler exists; these parts are irrelevant. Adapted to separated funding/accrual/claim transactions and token callback timing. [Defeat: claimRewards] Reenter accrual before debit, reenter after debit, and return false after an attempted claim: only before-debit accrual corrupts the ledger. |
| Solidity auditor periphery | Reviewed Votes/VotesExtended, EIP712, ECDSA, Nonces, Checkpoints, ReentrancyGuard, SafeERC20 and the representative Governor consumer. The inherited checkpoint integration order is correct; CLOCK_MODE is not. |
| Solidity auditor first principles | [Why: VqStaking.sol:92] Why mark all funding processed when the index represents less than all of it? Confirmed unrecoverable global residue. [Defeat: historical vote] Same-time stake/unstake, next-time exit, and transfer/re-stake to another account demonstrate the exact commitment boundary. |
| Solidity auditor numerical gap | Precision × conservation: repeated zero-index accrual destroys the aggregate entitlement available in a batched control. Precision × user state: changing stake resets individual fractions. Votes uint208 overflow fails atomically. |
| Solidity auditor trust gap | Public accrual can choose checkpoint timing but cannot arbitrarily checkpoint another user's personal account. Rewards are allocated to the current stake cohort; no owner-controlled reward setter exists. Funding-before-entry and governance-duration concerns remain specification/consumer questions. |

## Variant sweep

Applied the variant-analysis method after identifying the global reward remainder and invalid descriptor. Scope was all first-party `src`, with matching constructor/test/doc context reviewed separately.

| Search | Matches and disposition |
|---|---|
| Exact `rewardPerShare += (newRewards * SHARES_PRECISION) / _totalStaked;` | One: `VqStaking.sol:91`, confirmed STK-L02. |
| Broaden accumulated division to `\+=.* / ` / `\+=.*\) /` | Two accounting sites: global index line 91 and per-user reward line 100. The latter is STK-I02, self-controlled fractional settlement, requiring a different remainder fix. |
| `rewardPerShare|SHARES_PRECISION|lastRewardBalance` | Only VqStaking implements this funding/index/checkpoint shape. `earned` duplicates the fractional formula but does not mutate/discard a checkpoint; its separate stale-view behavior is STK-I03. |
| `CLOCK_MODE|mode=blockstamp` | One first-party implementation; docs and the existing unit assertion repeat the invalid descriptor. No separate first-party clock implementation exists. |
| Balance subtraction/checkpoint writes | Negative-delta root is line 89; claim line 169 supplies the callback timing and sender-fee variants. Broader raw balance-subtraction search introduced comments and ordinary stake decrements, so it was stopped instead of reporting these as matches. |

Recommended regression guard after remediation: require `CLOCK_MODE() == "mode=timestamp"`; for unchanged stake composition, compare final entitlements after fragmented funding/accrual against a batched control with the approved dust bound. The audit reproduction assertions intentionally preserve current defective behavior and must be inverted/adapted when fixing the implementation.

## Test artifact and measured execution

Source: `/tmp/vqalcx-audit-20260908/test/audit/StakingAudit.t.sol` (the coordinator may copy it into the retained audit evidence tree). SHA-256: `2770336e8d5d4504c4ee4300e3f64aefc32669a6f214932fc6c5683f02bd6094`.

Executed in the isolated target checkout using Forge `1.5.1-stable`, commit `b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2`, Solidity `0.8.36` and repository default settings:

```sh
forge fmt --check test/audit/StakingAudit.t.sol
forge test --match-path test/audit/StakingAudit.t.sol --fuzz-runs 4096 --fuzz-seed 0x2026090808 -vvv
```

Result: **21 passed, 0 failed, 0 skipped**; the cohort property ran **4,096 cases**, with no rejected input preconditions. Suite execution reported 955.33 ms; total reported 958.03 ms. One preliminary 20-test run also passed before adding the second delegate-override order and strengthening the cross-instance signature check. Final format check passed. Only dependency future-keyword warnings and missing Etherscan configuration warning were emitted; no RPC/Etherscan use was required.

The property generates positive integer stake weights from 1 to 1,000,000 tokens and positive integer funding multipliers, deliberately constructs divisible funding, checks exact cohort entitlements independently, varies claim order, and fully exits both participants. It verifies custody and payout conservation rather than recomputing rewardPerShare. Separate deterministic tests cover the excluded fractional/dust domain, failure paths, and external-token behaviors.

All 21 test names and outcomes are discoverable in the artifact. Tests with a defect in the name pass when that defect is reproduced; passing the suite is not a clean-security verdict. No remediation was applied, so no patched-commit retest is claimed. Actual Aragon/selected reward-token integration remains an explicit follow-up prerequisite before deployment.
