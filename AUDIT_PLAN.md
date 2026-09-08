# veQueue / vqALCX audit plan

Prepared: 2026-09-08. Planning baseline: commit `5bfb483025e65ab0a88912eda5295849e6bf944c`.

This document plans a future security audit. Preparation consisted of reading the first-party contracts, architecture, test structure, and build/CI configuration. No audit, vulnerability validation, test execution, static analysis, fuzz campaign, deployment, or security verdict was performed. All checks below are future work; none is a finding about the current implementation.

## Scope and priorities

The repository contains three first-party Solidity contracts, totaling 1,026 physical lines including comments and whitespace. The primary review order is custody and accounting, shared rate limits and exit liveness, auction settlement, then staking/governance and external integration. Governance and permission checks apply throughout.

| Component | Planning reference | Future audit responsibility |
| --- | --- | --- |
| Vault | `src/VqALCX.sol` (537 lines) | ALCX custody, ERC-20 shares and IERC4626 interface, deposit/withdrawal requests, lazy drip, cancellations, auction mint/burn hooks, configuration, pause and role handovers |
| Auction | `src/VqAuctioner.sol` (314 lines) | Both auction directions, bid escrow, replacement bids/refunds, partial settlement, treasury payments, round transitions and shared vault capacity |
| Staking adapter | `src/VqStaking.sol` (175 lines) | Staked-share custody, balance-delta reward accrual, claims, inherited delegation/signature/checkpoint behavior, DAO voting integration |
| Design | `arch.md`, especially sections 2, 4, 7 and 10 | Intended guarantees, deployment sequence, trust assumptions and named invariants; confirm whether `arch.pdf` represents the same approved specification |
| Tests | `test/unit/*.t.sol`, `test/invariant/VqALCX.invariant.t.sol`, `test/invariant/handlers/VqALCXHandler.sol` | Existing examples, future regression tests, independent models and multi-contract stateful testing |
| Build and dependencies | `foundry.toml`, `foundry.lock`, `.gitmodules`, `.github/workflows/test.yml` | Reproducibility, imported dependency behavior, compiler settings and release controls |

Configuration declares Solidity 0.8.36, OpenZeppelin Contracts v5.7.0 and forge-std v1.16.1. These are local configuration facts, not independently verified dependency or toolchain assurances. The CI definition includes formatting, size/build and test commands; their outcomes have not been checked.

The supplied source does not include the DAO framework, Safe deployment/configuration, a frontend, or deployment scripts. Include their integration assumptions and requested deployment evidence in this audit. A full audit of external implementations or later-supplied off-chain services is additional scope. Include the imported OpenZeppelin code paths that the contracts depend on; do not equate importing a library with proving the integration safe.

## Step-by-step execution plan

### 1. Freeze the audit target and collect deployment inputs

Record the audit commit, first-party file hashes, dependency git revisions and local modifications. Reconcile the lockfile, submodule revisions and installed dependencies. Record compiler, Forge, optimizer, EVM target and other effective build settings. Inventory every external/public entry point, including inherited token and voting APIs.

Obtain the intended chain, exact ALCX and reward-token addresses, DAO framework/version, Safe owners/threshold/modules, timelocks, treasury address, constructor arguments and initial bucket/auction parameters. If deployed, request contract addresses, deployment transactions, verified source and an explicit fork block. If predeployment, request the deployment sequence and intended configuration instead. Record unavailable evidence as a scope limitation.

**Deliverable / completion criterion:** a reproducible scope manifest and deployment-input register with each external assumption named. No production transaction is needed for audit execution.

### 2. Approve the specification and threat model

Convert `arch.md` into a requirements matrix: requirement ID, intended behavior, relevant contract/functions, test or proof method, and owner for clarification. Resolve these design questions before treating the document's invariants as test oracles:

- Is the principal rule unconditional 1:1 redemption, or proportional loss sharing when backing falls? What happens to pending deposits and withdrawal requests in the latter state?
- At what point do assets/shares become escrowed, fulfilled, claimable and finally paid? What remains claimable after partial fulfillment and cancellation?
- Do queues and auctions consume one shared budget? Can unused capacity accumulate, what is its cap or expiry, and how do configuration changes affect old credit?
- What does the governance commitment guarantee cover: new vault entry, existing transferable vqALCX, borrowed shares, staking, delegation and the complete proposal lifecycle? What snapshot and execution delays are assumed?
- What ERC-4626 and asynchronous-request behavior is promised to integrators, including `max*`, previews, caller/receiver/owner and multi-request claims?
- Are view functions expected to project time-dependent state, and which transactions must persist queue progression?
- Where do deposit premiums, withdrawal discounts, penalties and donations belong? Is surplus harvesting or external treasury investment part of this release?
- Which actions should pause block, which exits must remain available, and who retains emergency authority after governance handover?
- Which reward tokens and funding flows are supported, including reward arrivals with zero stakers and direct transfers?

Classify users, bidders, stakers, delegates, searchers, token contracts, governance, treasury and replacement auctioneers by capability. Evaluate unprivileged attacks, compromised privileged components, accidental configuration and unavailable operators separately. Define unacceptable outcomes: lost or misallocated principal, inaccessible claims, unbacked shares, reward theft, broken rate limits and invalid voting power.

**Deliverable / completion criterion:** an approved requirements and trust matrix; unresolved choices remain explicit questions rather than assumed implementation defects.

### 3. Establish the build and test baseline

In an isolated checkout, run the repository's formatting check, build with contract sizes and existing tests. Record exact tool versions, commands, output, seeds and environment. Measure coverage by contract, branch and state transition, then map it to the requirements matrix. Existing tests are a starting point, not the specification itself.

The planning inventory contains 41 vault, 21 auction and 21 staking unit tests. It also contains seven vault invariant functions and a five-actor handler with requests, claims, cancellations and time advancement. The current invariant suite targets the vault handler; the future plan must add auction, staking, administrative and cross-contract sequences. Counts describe test structure, not measured coverage or passing results.

Proposed baseline commands, not executed during planning:

```sh
forge --version
forge fmt --check
forge build --sizes
forge test -vvv
forge coverage
```

**Deliverable / completion criterion:** a reproducible baseline and requirements-to-test matrix, with failures, exclusions and untested transitions classified before new audit tests are added.

### 4. Build the asset, liability and state-transition model

Map ALCX, vqALCX and the reward token across users, vault, auctioneer, staking and treasury. For every tracked total, identify all writers and all corresponding token movements. Distinguish pending requests from fulfilled/unclaimed requests, escrow from earned revenue, and recorded balance changes from actual token receipts.

Trace each lifecycle: request → partial/full fulfillment → claim or cancellation; bid → outbid/refund → partial/full settlement; stake → funding/accrual → claim → unstake. Include first entrants, later entrants, multiple simultaneous participants and the last remaining claimant. Account for direct token donations without assigning them to the wrong user's liability.

Starting properties to formalize after step 2:

| Domain | Candidate property / modeling obligation |
| --- | --- |
| Vault solvency | Under the approved 1:1 and token assumptions, actual ALCX must cover outstanding shares **plus** still-owed deposit principal not represented by shares. Do not double-count withdrawal escrow shares already in total supply. Define profit only after every liability is accounted for. |
| Requests | `claimed <= filled <= amount`; principal is minted, paid, refunded or charged as an approved penalty exactly once; live unfilled amounts reconcile to bucket pending amounts. |
| Rate budget | Queue allocations plus auction consumption obey the approved time-integrated budget, including initial/accumulated credit and each rate-change interval. Filling a queue claim and later claiming it must not count the same allocation twice. |
| Auction escrow | Actual balances cover every outstanding bid/refund obligation across live rounds; charged funds split into backing, approved revenue and refunds with explicitly bounded rounding. |
| Staking | Sum of recorded user stakes equals total recorded stake; token custody covers those stakes. Treat unsolicited share donations separately from recorded stakes. |
| Rewards | Paid rewards plus remaining liabilities and defined dust reconcile to real funding; claims cannot consume stake principal or another cohort's rewards. |
| Voting | Checkpoints represent the approved staked units and delegates at the correct time; historical snapshots remain stable after subsequent actions. |

**Deliverable / completion criterion:** a money map, transition table and independent invariant definitions that cover every value-moving entry point. These become common inputs for subsequent review tracks.

### 5. Review vault custody and ERC-4626 behavior

Review `requestDeposit`, `requestWithdraw`, cancellation paths, `deposit`/`mint`, `withdraw`/`redeem`, conversions, previews, maximums and the claim-search helpers in `src/VqALCX.sol`.

Check sender/receiver/owner separation, allowances, escrow ownership, partial claims, requests distributed over several IDs, repeated claims, cancellation before/after drip, donations and empty-vault behavior. Trace mint/burn/transfer accounting against the independent model. Review sibling implementations together so equivalent entry points preserve the same rules. Verify claimed standard behavior against the official specification selected in step 2.

**Deliverable / completion criterion:** a completed function-by-requirement review with targeted tests for each custody transition and interface promise, including failure-path atomicity.

### 6. Review queues, shared capacity and liveness

Review both `_drip*Bucket` paths, request indexing, fulfillable/claimable calculations, `drip`, capacity accessors and parameter changes. Exercise same-timestamp actions, exact boundaries, partial fills, cancellation gaps, empty queues, long idle periods and rate/capacity changes while work is outstanding.

Model queue and auction activity on the same timeline. Distinguish capacity reserved or fulfilled from later token claims. Test fairness, queue spam, repeated tiny requests, arithmetic extremes and large per-user request histories. Measure gas for catch-up and claim operations at realistic and adversarial queue sizes. Define liveness in terms of available permissionless transactions and affordable execution, not spontaneous progression without transactions.

**Deliverable / completion criterion:** demonstrated budget conservation, defined FIFO behavior and executable exit/progression scenarios within a documented gas budget and supported parameter envelope.

### 7. Review auction bidding, escrow and settlement

Review both round-start/ensure functions, `bidDeposit`, `bidWithdraw`, both settlement functions, locked-bid mappings/totals, treasury transfers and the vault's auction hooks.

Cover first bids, replacement and self-replacement bids, changing bid quantities, price units and ranking rules, no-bid rounds, expiry boundaries, repeated settlement, and zero/partial/full fills. Reconcile each bidder's locked funds, refunds, charges and received assets. Check rounding and price tolerance when capacity changes between bidding and settlement. Include failed token transfers, callbacks, simultaneous queue consumption, pause changes and replacement of the auctioneer with funds outstanding.

**Deliverable / completion criterion:** conserved escrow and backing in both directions, with each round reaching an approved settlement/refund outcome and no obligations silently dropped during transitions.

### 8. Review staking rewards and voting integration

Review `stake`, `unstake`, `accrueRewards`, `_updateUserRewards`, `claimRewards`, `earned` and the inherited VotesExtended/EIP712 entry points in `src/VqStaking.sol` and its pinned dependencies.

Model first/last staker behavior, funding before or after stake changes, zero-staker intervals, partial unstaking, repeated tiny accruals, multiple claim orders, direct donations and rounding dust. Check actual transfers against recorded stake/reward balances and verify the supported token-behavior assumptions.

Review delegation and delegation by signature, nonce/replay/domain protections, timestamp clock declarations, same-timestamp checkpoint updates, historical balance/delegate/vote queries and supply bounds. Integrate with the exact DAO consumer to validate snapshot expectations and delegate override behavior. Assess governance acquisition and exit across transfers, borrowed existing shares, auctions, staking and the proposal lifecycle defined in step 2.

**Deliverable / completion criterion:** reward conservation and cohort-allocation tests, plus an end-to-end voting scenario against the intended DAO interface and clock semantics.

### 9. Review authority, configuration and lifecycle operations

Build a caller/permission matrix for every privileged function. Review governance and auctioneer proposal/acceptance flows, constructor validation, wrong/zero addresses, pending handovers, revocation, and replacement-contract acceptance capability. Check pause behavior across requests, claims, auctions, refunds and staking against the approved exit policy.

Analyze maximum authority for governance and the authorized auctioneer separately from public-user attacks. Test parameter changes at all lifecycle stages, including accrued capacity and open rounds. Rehearse initialization, operational ownership transfer, auctioneer replacement, incident response and recovery with pending user obligations. Confirm Safe and timelock assumptions from actual configuration when available.

**Deliverable / completion criterion:** a permissions and configuration review, tested deployment/handover sequence and incident runbook that states which operations require governance availability.

### 10. Review token integrations, dependencies and delivery controls

For the actual ALCX and reward tokens, verify decimals, transfer/return semantics, fees, rebasing, callbacks, blocklists, pausing and upgrade authority where applicable. Use representative adversarial mocks for accepted behaviors and verify explicit rejection or documented exclusion of unsupported behaviors. Review external calls and cross-function/cross-contract reentrancy, including public helper paths and settlement refunds.

Inspect imported OpenZeppelin behavior and current official compiler/dependency advisories for the pinned revisions. Review CI action provenance, dependency pinning, workflow permissions, build reproducibility and release/source-verification procedure. Assess secret handling and deployment credentials if deployment tooling is supplied; avoid reproducing any discovered credential in reports.

**Deliverable / completion criterion:** a token/dependency compatibility matrix, triaged relevant advisories and reproducible build/deployment evidence. Unsupported or unavailable integrations remain explicit residual scope.

### 11. Execute cross-contract adversarial validation

Combine all three contracts in a stateful harness driven by multiple actors and an independent accounting model. Include both auction directions, transfers, delegation, reward funding/claims, administrative changes, pause transitions and time advancement. Track successful action counts, revert reasons and transition coverage so a campaign cannot appear successful merely because most generated calls revert.

Run targeted boundary and regression tests alongside stateful fuzzing. Choose and record run/depth/seed budgets based on reachable transitions; require adequate successful exploration rather than an arbitrary coverage percentage. Use static analysis as a separate source of leads and manually triage its output. Use pinned-block fork tests for actual token/DAO integrations when deployment inputs are available. Retain minimal reproductions of any confirmed defects.

Exercise interleaved queue/auction settlement, stake/fund/claim ordering, same-block governance acquisition, transaction reordering, round-end competition, large backlogs and disappearance of operators. Follow selected scenarios until all participants have exited or claimed, accounting for any legitimate residual dust and explicitly checking the last participant's outcome. If a defect is confirmed, search sibling paths for the same root cause.

**Deliverable / completion criterion:** repeatable validation evidence tied to requirements, non-vacuous invariant campaigns, completed gas/liveness experiments and documented limitations. Tools producing no findings alone do not satisfy this step.

### 12. Report, remediate and independently retest

Report confirmed issues separately from specification questions, privileged trust assumptions, operational constraints and unsupported integrations. Each finding should identify the affected revision/function/line, root cause, preconditions, reproducible sequence, affected assets/users, practical impact and minimal mitigation. Calibrate severity by demonstrated impact and prerequisites.

After remediation, review the patch and related paths, add regression coverage and rerun affected tests and system invariants. Record accepted residual risks with the project owner, and issue the final report against the actual retested commit and deployment configuration.

**Deliverable / completion criterion:** a final report, evidence index, remediation status and requirements-coverage matrix. A release recommendation requires resolved critical/high-impact defects, explicit disposition of other issues and design questions, successful relevant retesting, and review of the intended deployment configuration. Audit completion is not a guarantee of security.

## Scheduling and parallel work

Steps 1–4 establish the common specification, baseline and accounting model before detailed review. Afterwards, separate reviewers can work on vault/queue (5–6), auctions (7), and staking/voting (8). Authority and integration work (9–10) can proceed in parallel using the same approved assumptions. Reserve a shared pass for composition tests (11), followed by reporting and retesting (12); separate module reviews do not replace that pass.

A planning allowance is **12–18 reviewer-days for the initial audit and report**, plus **2–4 reviewer-days for remediation review**, assuming stable scope and prompt access to specifications and integration inputs. This is an estimate, not a booked schedule. Re-estimate after steps 1–3; undocumented deployment systems, external DAO implementation review, major design decisions or substantial fixes add work.

## Evidence to retain during the future audit

- Scope/revision manifest, dependency revisions and deployment inputs.
- Approved requirements, trust matrix, money map and candidate invariants.
- Baseline logs, transition/coverage matrix, campaign configuration and seeds.
- Targeted and system-level tests, minimized reproductions and gas measurements.
- Findings, specification decisions, accepted risks and remediation/retest records.

Preparation stops at this plan. Executing any of these audit phases is a separate task.
