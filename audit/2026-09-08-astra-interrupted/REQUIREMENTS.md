# Requirements, permissions, and deployment evidence

Audit target: `5bfb483025e65ab0a88912eda5295849e6bf944c`. Prepared 2026-09-08 from `AUDIT_PLAN.md`, `arch.md`, all three first-party contracts, the exported entry-point lists, and the evidence cited below.

The user confirmed these are undeployed contracts in a private repository and authorized this audit as an invited collaborator. The coordinating reviewer also verified repository privacy and write access. This is a source and local-test audit. Deployed addresses, deployment transactions, and a deployed-protocol fork block are **not applicable at this stage**. Intended deployment inputs remain unknown where listed below.

The requirements below are a working interpretation, not owner-approved resolutions of contradictory architecture statements. Passing a test means the tested property held within its stated model; it does not approve that model as the intended product specification. Findings and severity decisions belong in the final audit report.

## Common accounting and threat model

For an exact-transfer, non-rebasing underlying token and the supplied honest auctioneer, the principal oracle is:

`vault ALCX balance >= vqALCX totalSupply + still-owed deposit principal not represented by minted shares`.

An uncancelled deposit contributes `amount - claimed`; a cancelled deposit contributes `filled - claimed`. Withdrawal escrow already belongs to `totalSupply` and must not be counted twice. Vault profit is the residual only after these liabilities are deducted. See [MONEY_MAP.md](MONEY_MAP.md) for every tracked writer and lifecycle.

The unprivileged actor model includes multiple accounts, share transfers, token donations, transaction ordering, many requests, cancellations, self-outbidding, permissionless settlements, stake changes, delegation, and reward accrual. Administrative changes, compromised auctioneer behavior, and unsupported token behavior are evaluated separately. No external DAO implementation, deployed token implementation, or Safe configuration is supplied by the repository.

## Requirements matrix

Status terms: **tested** means local evidence exists; **contradiction** means code or another specification passage disagrees with the stated requirement; **conditional** means an explicit trust or configuration assumption is needed; **open** means the owner must settle the behavior or provide integration evidence. A row can have more than one status.

| ID | Architecture / plan requirement | Relevant implementation | Evidence and disposition |
|---|---|---|---|
| R-01 | INV-WM-1/3/5, INV-T-3; plan 4–5: all share and pending-deposit principal is covered. | `VqALCX.requestDeposit`, claim/cancel paths, `mintViaAuction`; auction deposit settlement | **Tested/conditional.** Baseline watermark tests only compare balance to supply. The system audit additionally tracks unminted deposit liability and surplus. Auction hook backing depends on the authorized caller transferring ALCX first; the hook itself does not verify receipts. |
| R-02 | Quality goal 2, R-1 versus TC-4/INV-T-6: 1:1 redemption and equal loss sharing. | `convertToShares`, `convertToAssets`, all four previews and claims | **Contradiction/open.** All conversions and payouts use fixed raw-unit 1:1. There is no loss allocation state or proportional payout branch. Clarify loss mode, pending-deposit treatment, and withdrawal ordering before asserting equal loss sharing. |
| R-03 | INV-Q-5/8, plan 4–5: request, filled, claimed, cancelled, and pending amounts reconcile. | Both request mappings, bucket totals, `_drip*Bucket`, claims, cancellations | **Tested.** Baseline partial fill/claim/cancel examples; `test_PartialCancellationRetainsClaimsAndAllowanceIsAtomic`; system per-request and custody checks. Cancellation preserves `filled - claimed` and removes only unfilled principal. |
| R-04 | Section 4.1: deposit funding occurs at `deposit()`, rather than request. | `requestDeposit:178`, `deposit:267`, `mint:288` | **Contradiction.** ALCX is escrowed when the request is created; claims mint against that escrow. This changes the user's capital commitment and the deposit liability model. |
| R-05 | INV-Q-9/10: cancellation refunds unfilled principal minus a bounded penalty, without disturbing FIFO. | `cancelDepositRequest:206`, `cancelWithdrawRequest:225` | **Tested/open.** Owner checks, partial-claim retention, refund/burn, and 500 bps cap are exercised. Cancellation uses stored fulfillment without dripping elapsed time first; clarify whether cancellation intentionally precedes unpersisted time allocation. Tiny raw-unit requests can have a zero rounded penalty. |
| R-06 | INV-Q-1/2/4/7: queue capacity, FIFO, and valid indices. | Requests, `_dripDepositBucket:112`, `_dripWithdrawBucket:140`, parameter setters | **Tested.** Existing FIFO/capacity cases and vault invariants; system model checks both directions. Capacity is pending token amount, not request count, and does not bound traversal cost. |
| R-07 | INV-Q-3, INV-A-6, plan 6: queues and auctions consume one shared rate budget. | `_drip*Bucket`, `availableAuctionCapacity`, auction mint/burn hooks, setters | **Tested/open.** System model checks piecewise rate production against queue fills, auction usage, and remaining credit. Unused credit accumulates without cap or expiry, so a lifetime budget and a per-round budget are different promises. Select the intended one. |
| R-08 | INV-L-1/2, quality goal 4: every interaction/read reflects or persists current-time queue state. | Four `max*` functions, bucket/request getters, previews, ERC20 transfers, cancellation, `drip` | **Contradiction.** Read functions return stored state; previews return the input. Plain ERC20 transfers do not drip. Only selected transactions persist progression. `test_ElapsedCancellationAndStaleViews` demonstrates the distinction. A view call cannot persist storage changes. |
| R-09 | OC-1, INV-AUTH-4, INV-L-4: permissionless and affordable progression without operator dependence. | `_drip*Bucket`, global `_drip`, all claim entry points and parameter setters | **Tested defect evidence.** `test_CancelledQueueBacklogCannotProgressWithin30MillionGas` reproduces a backlog exceeding an explicit 30 million gas call budget. The final report must state the actual setup, cost, and supported chain gas envelope; source contains no bounded-progress operation. |
| R-10 | Section 4.1/9.1: O(1) queue operations; plan 6: bounded claim cost over long user histories. | Both drip loops and all four user-request search/aggregation helpers | **Contradiction.** Work scales with visited queue entries; claim helpers also copy and scan all historical IDs for the owner. O(1) per individual fulfilled entry does not imply O(1) per public call. No per-owner history compaction or direct claim-by-ID method exists. |
| R-11 | TC-1 and section 8.1: `max*` values do not overstate accepted claim amounts. | `maxDeposit:259`, `maxMint:280`, `maxWithdraw:301`, `maxRedeem:327`, `_findClaimable*` | **Tested defect evidence.** The two split-request tests show aggregation by `max*` versus single-request selection by claims. Two fulfilled 50-unit requests advertise 100 although a 100-unit claim reverts. The user can claim smaller requests separately. |
| R-12 | TC-1/INV-Q-6: preview semantics and standard-compatible request flows. | Four previews and four claims; `requestDeposit`/`requestWithdraw` | **Contradiction/open.** Architecture describes previews as queue limits; ERC-4626 deliberately separates previews from limits. Fixed 1:1 previews alone are not an ERC-4626 violation. The implementation is a custom asynchronous interface; choose exact ERC-4626/ERC-7540 compliance or document its deviations. |
| R-13 | Plan 5: caller/receiver/owner and allowance separation; no duplicate claims. | Deposit/mint use caller request; withdraw/redeem use owner request and spend caller allowance | **Tested.** Baseline double-claim tests and audit partial-cancellation/allowance atomicity test. Failure reverts the tentative claim increment. `maxDeposit`/`maxMint` are caller-dependent despite their receiver argument; this custom limit convention needs explicit integration documentation. |
| R-14 | INV-A-1/3/5 and plan 7: bid escrow conserved through replacement, partial/zero/full settlement, refunds, and last winner. | Auction bid/settlement paths and locked totals | **Tested/conditional.** Baseline 21 auction tests and system accounting cover exact-transfer mocks. A balance of exactly zero after settlement is not a sound universal oracle because token donations or another outstanding obligation may exist; use balance coverage of liabilities and known surplus. |
| R-15 | INV-A-4: bidder price tolerance and amount competition are economically consistent. | `bidDeposit:140`, `bidWithdraw:178`, proportional settlement formulas | **Open / specialist review.** Prices are total ALCX amounts and ranking does not normalize by requested quantity. Partial settlement prorates total prices with floor division. Clarify whether tolerance is absolute payout or per-unit price before judging outcomes. |
| R-16 | Section 4.2: continuously overlapping rounds and governance-configurable duration. | `_start*Round`, `ensure*Round`, `settle*Round`; `roundDuration` | **Contradiction.** The next round is created only when the current round settles. `roundDuration` has no setter in the supplied contract. A constructor-set duration and permissionless rollover are the implemented behavior. |
| R-17 | Quality goal 3, section 4.3, INV-AUTH-3: replace auctioneer without disrupting users. | `proposeAuctioneer:470`, `acceptAuctioneer:476`; auction contract API | **Open / specialist review.** Acceptance requires the proposed address itself to call the vault. The supplied auctioneer has no acceptance forwarding entry point. Initial deployment ordering and migration of outstanding bid obligations require a tested route. |
| R-18 | INV-AUTH-1/2: only selected roles change parameters or invoke auction hooks. | Vault role modifiers, setters, proposal/acceptance functions | **Tested/conditional.** Baseline unauthorized-call and two-step handover tests pass. Governance and the authorized auctioneer remain trust boundaries; role checks do not prove the selected contracts enforce Safe/DAO policy. |
| R-19 | OC-3: hardcoded bounds prevent destructive parameter choices. | Bucket setters, cancellation penalty setter | **Tested contradiction.** Penalty is capped at 500 bps; rate must be nonzero and capacity cannot fall below stored pending after drip. No maximum rate exists. `test_OverflowingRateBlocksCorrectionAndUnrelatedClaim` exercises multiplication overflow after an admitted configuration and the inability to reset it through the same pre-drip setter. This is a privileged configuration failure, separate from public attacks. |
| R-20 | Section 4.3, OC-2: Safe retains emergency pause after DAO handover. | `pause:484`, `unpause:489`, `acceptGovernance:462` | **Contradiction/open.** Only the current governance address can pause or unpause. No separate guardian/pauser role or Safe-specific logic exists. Retention would need external DAO authorization or a code change; neither is established here. |
| R-21 | Plan 9: pause policy preserves intended exits and refunds. | `whenNotPaused` on requests and auction mint; all other paths | **Tested/open.** Existing claims and cancellation remain callable; new deposit **and withdrawal** requests stop. Auction burns and staking remain callable. Pause can therefore stop a free share holder initiating a normal queued exit while allowing existing queued claims. Approve this exact policy explicitly. |
| R-22 | TC-4/5, INV-T-1/2/5/7/8/9: shares, stakes, and voting units remain consistent. | ERC20 inheritance; staking balances and `_transferVotingUnits` | **Tested/conditional.** Baseline staking/checkpoint cases and system checks. Replace strict equality between token custody and recorded stakes with `custody >= recorded stakes` if unsolicited share donations are allowed. Recorded voting units should equal recorded stakes, not donated custody. |
| R-23 | TC-3/5, INV-L-5: timestamp clock and DAO-compatible snapshots/delegation. | `VqStaking.clock:64`, `CLOCK_MODE:69`, inherited VotesExtended APIs | **Tested locally/open integration.** Local checkpoint tests exist. The clock returns timestamp, while the descriptor is `mode=blockstamp`; the actual DAO consumer/version and snapshot configuration remain unknown. Specialist standards/integration review determines consequences. |
| R-24 | Quality goal 1: governance power cannot be acquired and disposed of in one block. | Freely transferable vault shares; immediate `stake`/`unstake`; delegation; external DAO | **Contradiction/open.** Queueing new underlying capital does not impose a holding period on existing transferable/borrowed shares or staked voting units. The external proposal snapshot, voting period, execution delay, and delegated override rules are essential to any narrower guarantee. |
| R-25 | Plan 8/10, TD-1: rewards allocated proportionally and conserved without consuming stake principal. | `accrueRewards`, `_updateUserRewards`, `earned`, `claimRewards`, constructor | **Tested/conditional.** Baseline proportional/cohort tests and system funding/liability checks use a distinct exact-transfer token. Zero-stake funding is retained for later stakers; rounding residue and the allowed reward-token/funding model need owner approval. `earned` reports stored index, not unaccrued balance deltas. |
| R-26 | Quality goal 2, section 4.2: DAO owns surplus while user principal stays protected. | Vault balance, cancellation penalties, auction treasury/discount flows | **Contradiction/open.** Pending deposits are liabilities, not profit. No generic vault surplus withdrawal or treasury-investment entry point exists. Deposit auction premiums are transferred to treasury; withdrawal discounts and cancellation penalties remain in the vault. Do not infer a surplus-harvest feature. |
| R-27 | Plan 10: actual tokens, dependencies, compiler, CI, and release controls are compatible. | Constructors, SafeERC20 paths, imported OpenZeppelin, Foundry/CI files | **Partially tested/open integration.** Build and tests pass against installed pinned dependencies; advisory and static-analysis artifacts exist. Actual intended tokens and deployment configuration are not specified, so mock results cannot establish compatibility with them. |
| R-28 | Plan 11–12: non-vacuous combined tests, full unwind, remediation and retest. | Audit system harness and final report | **Tested / remediation pending.** 256 sequences of 126 generated operations pass, followed by full unwind; deterministic coverage records successful execution of all 21 action classes. No production remediation has been made or retested by this documentation task. |

### Standards interpretation

[ERC-4626](https://eips.ethereum.org/EIPS/eip-4626) requires maxima to avoid overestimating accepted amounts and separates transaction limits from previews. Its ordinary deposit/mint flow supports pulling approved underlying; pre-owned underlying is an additional flow. Its withdraw/redeem specification likewise distinguishes direct owner burns from additional escrow flows. These details must be addressed before claiming full compliance for this custom request API.

[ERC-7540](https://eips.ethereum.org/EIPS/eip-7540) specifies asynchronous request lifecycles, controller/operator behavior, and changed preview behavior. Merely requiring a prior request does not establish compliance with that extension. The audit uses the implementation's custom interface for local accounting tests while leaving the precise public standards promise open.

## Permission and pause matrix

All public views/getters in [the vault entry-point list](evidence/VqALCX-entrypoints.txt), [the auction entry-point list](evidence/VqAuctioner-entrypoints.txt), and [the staking entry-point list](evidence/VqStaking-entrypoints.txt) are unrestricted. They do not authorize movement of user funds and do not persist lazy state. Inherited ERC20 and voting APIs are included below.

| Contract / operations | Authorized caller and affected position | Additional constraints | While vault paused |
|---|---|---|---|
| Vault `requestDeposit` | Any caller; creates caller-owned request | Caller ALCX balance and allowance; nonzero amount; pending capacity | Blocked |
| Vault `requestWithdraw` | Any share holder; creates caller-owned request | Caller share balance; nonzero amount; pending capacity; shares escrowed internally | Blocked |
| Vault `deposit`, `mint` | Caller claims caller-owned deposit request; receiver may differ | One request must cover amount; nonzero amount; receiver valid for ERC20 mint | Allowed |
| Vault `withdraw`, `redeem` | Owner or an approved spender of owner's shares; arbitrary receiver | One owner request must cover amount; spender allowance if caller differs; nonzero amount; underlying transfer succeeds | Allowed |
| Vault deposit/withdraw cancellation | Exact request owner | Not already cancelled; stored unfilled remainder greater than zero; configured penalty | Allowed |
| Vault `mintViaAuction` | Exact `authorizedAuctioneer` | Available deposit auction credit; valid receiver; no local backing-transfer check | Blocked |
| Vault `burnViaAuction` | Exact `authorizedAuctioneer` | Available withdrawal credit; auctioneer share balance; payout no greater than burn | Allowed |
| Vault `setDepositBucketParams`, `setWithdrawBucketParams` | Exact current `governanceAddress` | Nonzero rate; drip old configuration first; new capacity covers remaining pending | Allowed |
| Vault `setCancellationPenaltyBps` | Exact current governance | At most 500 bps; zero is accepted | Allowed |
| Vault `proposeGovernance`, `proposeAuctioneer` | Exact current governance | Proposed address nonzero; replaces an earlier pending proposal | Allowed |
| Vault `acceptGovernance`, `acceptAuctioneer` | Exact pending address for that role | Successful acceptance replaces current role and clears its pending address | Allowed |
| Vault `pause`, `unpause` | Exact current governance | No independent emergency role; repeat calls allowed | Allowed |
| Vault `drip` | Anyone | Arithmetic and full loop execution must fit transaction resources | Allowed |
| Vault inherited `transfer`, `approve`, `transferFrom` | Token holder / allowance owner / approved spender | Standard inherited ERC20 balance, address, allowance rules | Allowed |
| Auction `ensureDepositRound`, `ensureWithdrawRound` | Anyone | Creates round only if absent or settled | Allowed |
| Auction `bidDeposit`, `bidWithdraw` | Anyone; caller locks bid principal | Live round, capacity, price checks, funding/allowance; prior winner refund must succeed | Allowed; deposit bid may later need an unpaused vault to settle a nonzero fill |
| Auction `settleDepositRound` | Anyone | Current nonzero round; expiry reached; associated transfers/hooks succeed | A nonzero mint is blocked; a zero-fill/no-bid branch can complete |
| Auction `settleWithdrawRound` | Anyone | Current nonzero round; expiry reached; associated transfers/hooks succeed | Allowed |
| Staking `stake`, `unstake`, `claimRewards` | Any caller over that caller's stake/reward position | Balance/allowance or accrued reward; nonzero applicable amount; token calls succeed | Allowed |
| Staking `accrueRewards` | Anyone | Reward-token balance delta and arithmetic valid | Allowed |
| Staking inherited `delegate` | Any caller over that caller's voting units | Inherited delegation/checkpoint constraints | Allowed |
| Staking inherited `delegateBySig` | Any relayer of a valid delegation signature | Signer's EIP-712 domain, expiry, nonce, signature; affected units belong to signer | Allowed |

The auctioneer and staking contracts have no administrator, pause switch, upgrade mechanism, arbitrary call facility, or asset-recovery function in the supplied source. The auctioneer's treasury and duration are set only in its constructor even though their storage declarations are not `immutable`.

### Role handover and incident consequences

1. Governance can propose a successor but cannot accept on its behalf. A contract successor must have a reachable operation that originates the acceptance call. Test the real DAO execution address rather than substituting a pranked contract address.
2. Auctioneer acceptance has the same requirement. The supplied auctioneer cannot originate `acceptAuctioneer()` through its public API. Do not treat a test that impersonates the auctioneer address as deployment proof.
3. Acceptance replaces authority immediately. A replaced auctioneer with an outstanding winning bid may still need the old vault hooks to settle. Establish a no-new-bids and settlement/migration sequence before replacement; the present auctioneer has no administrative bidding freeze.
4. The vault cannot set the authorized auctioneer to zero through its proposal API and exposes no explicit revoke operation. Pausing blocks auction mints but permits auction burns.
5. After governance handover, the old Safe loses direct pause authority. An external DAO permission arrangement could grant it an emergency route, but that route is not in scope without its implementation and configuration.
6. Existing queued claims and cancellations remain available during pause, subject to transfer and queue-processing liveness. Unqueued share holders cannot start a queued withdrawal while paused. Governance availability is needed to unpause if the selected policy is retained.
7. Bucket setters execute the old drip before changing parameters. An arithmetic or traversal failure in the old state can therefore prevent correcting the parameter through the same setter. Incident handling must not assume governance can always lower a rate or restore claim liveness.

## Deployment-input register

| Input | Evidence available | Required predeployment evidence / owner |
|---|---|---|
| Repository and deployment state | User says private and undeployed; coordinator verified private repository and write access | Record audit target and final retested source commit / maintainers |
| Intended chain and EVM constraints | Effective local compiler target is Prague; no intended chain declared | Chain ID, supported forks/opcodes, maximum transaction/block gas assumptions / deployment engineering |
| Actual ALCX token | Asset constructor parameter only; local tests use mocks | Exact chain/address, implementation/proxy/admin, decimals, transfer semantics, mint authority, pause/blocklist/rebase/fee behavior / deployment engineering |
| Reward token and funding | Constructor parameter; cannot equal staking token; funding model described abstractly | Exact token(s), supported behaviors, distribution frequency/precision, zero-staker ownership, funding operator/contracts / tokenomics and deployment engineering |
| Initial governance | Nonzero constructor address; architecture suggests a Safe | Real Safe/executor address, owners, threshold, modules, guards, fallback handler, emergency path / governance operations |
| DAO consumer | Architecture names Aragon and VotesExtended; no DAO framework code or version supplied | Exact plugins/contracts and versions, clock expectations, proposal/vote/snapshot/execution delays, quorum, override behavior, execution permissions / governance integration |
| Governance successor | Vault two-step interface present | Exact execution address and successful acceptance rehearsal through its real call path / governance integration |
| Initial and replacement auctioneer | Constructor may take zero or another address; acceptance interface only in vault | Deployment order/address derivation or corrected acceptance path; replacement treatment of open bids and refunds / deployment engineering |
| Treasury | Auction constructor parameter; no runtime setter | Intended nonzero destination, account/contract type, ability to accept supported token transfers, governance ownership / treasury operations |
| Bucket configuration | Constructor leaves zero rate/capacity; setters and mock test parameters supplied | Initial rates/capacities in raw units, expected peak queue count/history, arithmetic ceiling, minimum request/spam policy, credit accumulation/cap/expiry / tokenomics and maintainers |
| Cancellation policy | Default 100 bps, maximum 500 bps, mutable by governance | Chosen initial penalty, permitted later changes, effective timing, rounding and elapsed-fill cancellation policy / tokenomics |
| Auction configuration | Duration passed at construction; no setter; round capacity derived from rate | Nonzero duration, start/expiry policy, pricing units, ranking across quantities, min payout meaning, partial fill rules / tokenomics |
| Pause and recovery | Current governance-only switch; no upgrade, recovery, or surplus sweep API | Explicit actions-to-block policy, old Safe role after transfer, handling of immutable-contract defects and outstanding obligations / governance operations and maintainers |
| Full deployment rehearsal | No scripts supplied; local tests construct mocks/contracts | Constructor arguments, transaction order, expected role state, deployed bytecode/source verification method, funding/approval checklist, smoke-test trace / deployment engineering |
| Deployed source/transactions/fork block | **Not applicable: protocol is undeployed** | At deployment, archive transactions, verified source, addresses, final bytecode and selected validation block. This audit does not claim those future checks. |
| Architecture authority | `arch.md` plus extracted `arch.pdf` text; extraction contains the same funding, O(1), and clock-descriptor claims | Owner-designated authoritative version and disposition of contradictions below / protocol owner |

## Decisions needed before architecture can serve as a release oracle

| Decision | Current ambiguity | Required decision owner |
|---|---|---|
| S-01 Principal after loss | Hard 1:1 and equal loss sharing are both stated; implementation only has 1:1 | Protocol owner / tokenomics |
| S-02 Standard interface | Fully ERC-4626 versus custom asynchronous claims versus ERC-7540; queue-aware preview text conflicts with the ordinary ERC-4626 role of previews | Maintainers / integrations |
| S-03 Time and capacity | Current-time projected views; cancellation order; lifetime unused auction credit versus per-round shared ceiling | Protocol owner / tokenomics |
| S-04 Governance commitment | Whether the guarantee applies to new ALCX entering the vault or also purchased/borrowed existing shares, staking/delegation, and the complete proposal lifecycle | Governance security / DAO integration |
| S-05 Surplus | Which assets are liabilities, where revenue belongs, whether treasury investment/surplus harvesting is in this release | Protocol owner / treasury |
| S-06 Reward cohorts | Zero-stake arrivals, rounding residue, funding cadence and supported reward tokens | Tokenomics |
| S-07 Pause and roles | New withdrawal requests, auctions and refunds during pause; independent Safe emergency rights; successor acceptance and open bids | Governance operations |
| S-08 Resource envelope | Supported queue count, user request history, minimum economic request, transaction gas target and bounded progress | Maintainers / deployment engineering |

These open decisions do not invalidate concrete local correctness defects such as a maximum exceeding an accepted amount or an unbounded loop exceeding a chosen gas budget. Conversely, architecture wording alone is not evidence of an exploitable loss.

## Evidence and plan completion mapping

| Plan step | Current evidence and limitation |
|---|---|
| 1. Freeze and deployment inputs | Source hashes, dependency revisions, effective Foundry configuration and entry-point exports are under `evidence/`. Intended deployment register above is incomplete; deployed-protocol evidence is not applicable. |
| 2. Specification and threat model | This matrix and `MONEY_MAP.md` establish provisional oracles and explicit decisions. Owner approval of open choices has not been obtained. |
| 3. Baseline | Formatting log is empty; build succeeded with Solidity 0.8.36. Baseline reports 90 passed, zero failed, zero skipped. Source coverage is listed below. |
| 4. Accounting model | `MONEY_MAP.md`; system harness includes unminted deposit liabilities, queue budgets, auction escrow, stake custody, and reward funding. |
| 5–6. Vault, queues and liveness | Six tests pass in `evidence/vault-tests.log`; several intentionally pass when reproducing a defect. Test success must not be summarized as vault safety. |
| 7–8. Auctions, staking and DAO integration | Baseline includes 21 tests for each. Specialist reviews and combined local harness add evidence; actual token/DAO consumer integration remains open. |
| 9. Authority and operations | Entry-point inventory, permission matrix, handover review and configuration tests. Real Safe/DAO transaction rehearsal awaits configuration. |
| 10. Integrations and dependencies | Installed dependency manifest, compiler/advisory JSON and Slither artifacts exist. Actual intended token compatibility remains a separate predeployment requirement. |
| 11. Cross-contract validation | Latest `evidence/system-tests.log`: 256 generated sequences × 126 operations, full user unwind, plus deterministic prefix/420-operation coverage with all 21 action classes successful. This finite mock campaign is not an exhaustive proof. |
| 12. Report, remediate, retest | Report synthesis follows these evidence artifacts. Production remediation and a final patched release retest are not performed by this requirements document. |

Baseline first-party coverage from [baseline-coverage.log](evidence/baseline-coverage.log):

| Contract | Lines | Statements | Branches | Functions |
|---|---:|---:|---:|---:|
| VqALCX | 91.49% (258/282) | 89.25% (274/307) | 64.71% (33/51) | 83.02% (44/53) |
| VqAuctioner | 90.85% (129/142) | 87.79% (151/172) | 58.62% (17/29) | 100% (11/11) |
| VqStaking | 96.49% (55/57) | 92.45% (49/53) | 50% (3/6) | 92.31% (12/13) |

The existing seven vault invariant functions each executed 256 runs and 128,000 calls, with roughly 27,500–27,800 reverts per invariant. Their coverage and oracles are a baseline, not proof of cross-contract behavior. The combined audit harness adds an explicit exploration gate and independent conservation checks. The older `evidence/system-transitions.log` records a failed draft-harness exploration assertion; the corrected and successful run is `evidence/system-tests.log`. The draft failure is not a protocol finding.

No user-supplied production source was changed in preparing this document. Final report finding identifiers, extra specialist tests, and later retest evidence may be linked by the coordinating reviewer without changing these requirement meanings.
