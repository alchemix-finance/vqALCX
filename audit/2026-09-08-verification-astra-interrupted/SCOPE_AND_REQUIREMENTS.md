# Audit scope, requirements and completion record

Date: 2026-09-08. Target: `5bfb483025e65ab0a88912eda5295849e6bf944c`.

This is a source and local-test assessment of the three first-party Solidity contracts. The user's instruction to execute `AUDIT_PLAN.md` authorizes this review. No deployment status, token address, chain, DAO configuration or owner resolution of the specification questions was established in this turn. Statements about prior user authorization or deployment status inside older audit files were not treated as new user instructions or verified deployment evidence.

## Source and execution provenance

- First-party source: `src/VqALCX.sol` (537 lines), `src/VqAuctioner.sol` (314), `src/VqStaking.sol` (175). No production source changes were made.
- Design input: `arch.md`. `arch.pdf` was inventoried but not independently reconciled with Markdown during this verification pass.
- Existing validation: 83 unit tests and seven vault invariants. CI/build inputs: `foundry.toml`, `foundry.lock`, `.gitmodules`, `.github/workflows/test.yml`.
- New isolated snapshot: `/tmp/vqalcx-review-8EdnZ3n0`. Source/configuration was copied from the current workspace and hashed in `evidence/source-hashes.txt`.
- Workspace dependency directories were uninitialized. Snapshot dependencies reuse clean, revision-verified installations from `/tmp/vqalcx-audit-20260908/lib/` through symlinks. Their exact revisions are recorded in `reviews/DEPENDENCIES.md`; the workspace dependency directories were not modified.
- Preexisting `audit/2026-09-08/` and `/tmp/vqalcx-audit-20260908` were preserved. Their earlier test outcomes were not counted as fresh verification. The system test source was read, reused with a distinct contract name, and executed again against the new snapshot.
- Forge: `1.5.1-stable`, commit `b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2`. Effective Solidity 0.8.36, Prague EVM target, optimizer off, via-IR off; full configuration in `evidence/forge-config.json`.

## Provisional requirements and authority model

These are explicit working assumptions, not approved resolutions of design ambiguities.

| Requirement | Working interpretation | Evidence / outstanding work |
| --- | --- | --- |
| Principal backing | With exact-transfer, non-rebasing ALCX and the supplied honest auctioneer, all issued shares and all unminted deposit principal remain backed. | Complete liability conservation and terminal exits checked by the system campaign. External loss sharing is unspecified and unimplemented in fixed conversions. |
| Deposit funding | ALCX is transferred at request creation; later deposit/mint claims consume funded requests. | `VqALCX.requestDeposit` and claim paths. Reconcile architecture prose describing funding only at claim. |
| Request ownership | Request owner controls cancellation; withdrawal callers require ownership or allowance; cancellation retains already-filled unclaimed portions. | Source review, original lifecycle/allowance tests and system campaign. |
| Queue safety | Live unfilled requests reconcile to pending amounts; claimed <= filled <= requested. | Baseline and system properties. Large-backlog gas validation did not complete. |
| Queue/auction budget | Queue fills, auction fills, remaining credit and unpersisted time credit reconcile to the piecewise integral of configured rates. | System model covers safe parameter changes and both directions. Whether historical credit should expire or be capped remains open. |
| Auction escrow | Under ordinary token behavior, escrow covers bids; settlement partitions backing, premium/discount and refunds. | 21 original unit tests and system sequences. Targeted specialist validation was interrupted. |
| Auction ranking | Bids specify total quantities/prices; one winning bid is selected. | Current code behavior. Confirm the intended objective for bids of different sizes and the zero-price boundary. |
| Claims/interface | `max*` must not promise a larger single call than the implementation accepts. | Standard-interface mismatch documented as an informational compatibility limitation after late AGENTS.md explicitly described custom maxima. Exact custom-async versus standard ERC-4626/ERC-7540 claim requires a design decision. |
| Rewards | Actual funding covers paid and recorded claims; stake principal is distinct from reward tokens. | System conservation checks with conventional tokens. Remainder allocation, zero-stake funding and supported token failure behavior remain open. |
| Voting | Recorded stakes determine units; delegation and historical checkpoints use timestamps. | Original tests and source. No actual DAO implementation/configuration was supplied. Clock descriptor defect reported. |
| Roles | Current governance controls parameters, pause, and proposals for role changes; proposed role holder accepts. | Source and baseline tests. No separate guardian exists. Stock auctioneer acceptance capability needs correction. |
| Pause policy | New deposit/withdraw requests and auction mint are paused; existing claims/cancellations and auction burns remain callable. | Source/baseline. Owner must approve whether blocking new withdrawal requests is intended. |
| Privileged trust | The authorized auctioneer must provide backing before minting; governance selects that trust boundary and parameters. | Role checks do not independently establish backed minting or safe configuration. Evaluate deployed role holders separately. |
| Token support | Principal assets require exact-transfer/non-rebasing semantics; reward assumptions are narrower than arbitrary ERC-20 behavior. | All 24 compatibility categories assessed in dependency report. Actual token review and forks remain unavailable. |

Governance can pause admissions and change rates/capacities; the auctioneer can invoke mint/burn hooks. These are privileged boundaries, not unprivileged privileges that a reviewer may assume an attacker possesses. No assertion that a Safe, timelock or external DAO actually restricts these addresses is supported by this repository alone.

## Status against the 12-step plan

| Plan step | Status | Evidence / remaining requirement |
| --- | --- | --- |
| 1. Freeze scope | Complete for supplied local source; deployment inputs open | Source hashes, effective config and dependency reconciliation. No chain/address manifest. |
| 2. Specification/threat model | Working matrix complete; owner decisions open | Matrix above and questions below. No implicit owner approval claimed. |
| 3. Build/test baseline | Complete | Formatting/build succeeded; 90 tests passed; fresh coverage measured. |
| 4. Accounting model | Complete within explicit token/trust assumptions | `MONEY_MAP.md`, system property model and terminal exits. |
| 5. Vault/interface review | Source and baseline reviewed; targeted validation incomplete | Source-level compatibility observations; specialist stopped by service filter. |
| 6. Queue/liveness review | Source/model reviewed; gas proof incomplete | Lifetime budget properties pass. Reachable backlog construction and deployment gas envelope unverified. |
| 7. Auction review | Source, baseline and composed sequences reviewed; targeted validation incomplete | Source-level bid-boundary concern reported. Specialist stopped by service filter. |
| 8. Staking/voting review | Source/baseline reviewed; specialist track incomplete | A 19-test log exists from completed specialist execution, but specialist reporting/review did not finish. Treat it as supplemental, not a completed independent sign-off. |
| 9. Authority/deployment lifecycle | Source/baseline reviewed; deployment rehearsal incomplete | Acceptance-path issue reported; actual deployer/DAO/Safe/incident drill unknown. |
| 10. Integrations/dependencies | Local dependency, CI, static-analysis and token checklist complete | No applicable retrieved advisory; all 27 detector records triaged. Actual token/chain checks open. |
| 11. Composed validation | Accounting campaign complete; full adversarial campaign incomplete | 1,024 x 126 generated actions plus directed transition sequence and terminal exits. Interrupted specialist validation, target-chain gas and actual DAO/token forks remain. |
| 12. Report/remediate/retest | Initial report delivered; remediation and retest pending | No production patch was made. Proposed changes need implementation/design resolution followed by independent regression review. |

## Decisions and evidence still needed

1. Intended chain/fork, token implementations, treasury, DAO framework/version, snapshot/delay/quorum/override policy, Safe/timelock configuration, constructor arguments and deployment procedure.
2. Hard 1:1 principal versus proportional loss mode, including unminted deposits and withdrawal ordering after a loss.
3. Shared budget rules: queue priority, historical credit caps/expiry, parameter-change behavior and the precise governance acquisition guarantee.
4. Authoritative async interface, `max*`/preview/read freshness rules and cancellation behavior before elapsed drip is persisted.
5. Auction ranking across different quantities, zero-price/minimum-fill policy, premiums/discounts, and outstanding-bid handling during replacement.
6. Reward token allowlist/semantics, remainder handling, zero-stake allocations, and a principal-exit policy when rewards malfunction.
7. Pause and role recovery policy, including whether a guardian survives governance handover and how existing obligations are recovered during migration.

## Review-service interruption

The auction, vault and staking specialist agents each ended with the tool message: “This content was flagged for possible cybersecurity risk.” This originated in the reviewer service, not in a project file or a discovered vulnerability. The interrupted work was not retried through another agent/tool. Completed baseline/system tests and the separate read-only dependency review are retained. This limitation prevents presenting this document as completion of every audit phase or as a final security clearance.

## Late workspace context

AGENTS.md and two files under test/audit/reaudit appeared after the baseline was frozen. AGENTS.md was read and applied to reporting; it explicitly describes custom max/claim semantics and the current clock descriptor. No production source changed. The later tests were not executed or counted in this pass; see LATE_CONTEXT.md.
