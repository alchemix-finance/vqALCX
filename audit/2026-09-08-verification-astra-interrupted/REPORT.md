# Security review — veQueue / vqALCX

**Target:** `5bfb483025e65ab0a88912eda5295849e6bf944c`  
**Date:** 2026-09-08  
**Scope:** three first-party contracts, their imported dependencies, tests, architecture and build/CI configuration  
**Status:** initial source/local-test assessment; planned targeted validation, deployment integration, remediation and retest are incomplete

The vault takes ALCX into funded requests and later issues fixed-conversion vqALCX shares. Withdrawals escrow and burn those shares. Auctions provide a separate execution path with bid escrow and settlement, and staking holds shares for governance units and external rewards. Unminted deposit principal is a liability in addition to issued shares; withdrawal escrow shares already belong to supply. The checked accounting model assumes exact-transfer, non-rebasing tokens and the supplied honest auctioneer. No externally supplied loss-sharing mechanism or actual DAO configuration was established.

The completed accounting campaign did not produce an uncovered principal liability under that model. This does not establish deployment readiness: auction-boundary, activation and clock-integration issues remain, governance/token assumptions are unresolved, and planned gas and specialist validation did not finish. **Do not use this report as a completed audit or a release clearance.**

## Completed evidence

| Check | Fresh result | Evidence |
| --- | --- | --- |
| Formatting | Passed | [baseline-fmt.log](evidence/baseline-fmt.log) |
| Build and sizes | Passed; runtime sizes 20,013 / 11,634 / 14,476 bytes for vault / auction / staking | [baseline-build.log](evidence/baseline-build.log) |
| Original suite | 90 passed, 0 failed: 83 unit tests + 7 vault invariants | [baseline-tests.log](evidence/baseline-tests.log) |
| Original invariant settings | 256 runs x depth 500 per property | [forge-config.json](evidence/forge-config.json), baseline log |
| New composed accounting model | 1,024 seeded sequences x 126 generated actions, each followed by terminal settlement/exit; passed | [system-tests.log](evidence/system-tests.log), [system test](tests/SystemVerification.t.sol) |
| Directed transition exploration | All 21 operation categories executed at least once; successful/inapplicable counts recorded; passed | Same system log |
| Static analysis | Slither 0.11.6, 102 detectors, 37 analyzed contracts, 27 records; JSON success true | [SLITHER_TRIAGE.md](reviews/SLITHER_TRIAGE.md) |
| Dependency advisories | No applicable issue identified in 63 retrieved compiler records and 20 OpenZeppelin records | [DEPENDENCIES.md](reviews/DEPENDENCIES.md) |
| Token behavior checklist | All 24 categories assessed at source level; actual tokens unverified | Same dependency report |

The Slither process exit code was 255 because detector results were present; its JSON reports successful analysis with no analysis error. Detector records are not a count of vulnerabilities.

Baseline coverage measured only original tests, excluding the new audit tests from execution:

| Contract | Lines | Statements | Branches | Functions |
| --- | ---: | ---: | ---: | ---: |
| VqALCX | 91.49% | 89.25% | 64.71% | 83.02% |
| VqAuctioner | 90.85% | 87.79% | 58.62% | 100.00% |
| VqStaking | 96.49% | 92.45% | 50.00% | 92.31% |

Evidence: [baseline-coverage.log](evidence/baseline-coverage.log). Coverage is execution evidence, not correctness evidence. The original no-lockup property attempts a zero-value self-transfer; it does not establish usable withdrawals or affordable queue progression. Original handlers catch failed calls and filter requests, so raw invariant call counts do not equal successful protocol transitions. The new system harness counts applicable actions and does not swallow unexpected action failures.

A specialist also completed a 19-test staking execution before its review was interrupted; [staking-tests.log](evidence/staking-tests.log) is preserved as supplemental provenance. That unfinished specialist track is not presented as an independently completed review, and its detailed validation was not reconstructed after the interruption.

## Source-level findings

The following findings and compatibility observations are established from the current source and call relationships. A late-arriving AGENTS.md explicitly documents the aggregate-maxima/single-request convention, so those two observations are informational compatibility notes rather than deviations from that newly documented custom behavior. Their targeted specialist reproductions did not complete in this pass. Severity describes the limited consequence stated here; no finding below establishes a deployed-protocol theft or governance takeover. There is one Medium finding, two Low findings, and two informational compatibility observations.

### M-1. A zero-price withdrawal bid prevents further competition for the round

**Location:** [VqAuctioner.bidWithdraw](/Users/deepthought/Desktop/dev/vqalcx/src/VqAuctioner.sol:178), comparison at line 189.

**Description:** `minPrice` can be zero. After such a bid becomes the leader, the replacement condition requires a strictly smaller unsigned price, so no subsequent bid can replace it. Because a winning bid may request only a small part of round capacity and each direction selects only one winner, a zero-price leader can exclude other prospective withdrawal bidders for the rest of that round without purchasing the full capacity. This concerns the auction path; it does not prove that normal queued withdrawal is unavailable. The duration is bounded by round expiry and successful settlement, so the consequence is rated Medium, not permanent loss of all user principal.

**Recommended mitigation:** define quantity-aware competition and explicit zero-price/floor behavior. A minimum fill or an allocation rule for unused capacity is needed if a small winning bid must not monopolize the round. Merely requiring a positive price can move the same problem to the smallest allowed price. Add regression cases for minimum-price bids, different requested quantities, and completion/refunds at expiry after the economic rule is selected.

**Fix review:** pending; no patch or fresh targeted reproduction is claimed.

### L-1. The supplied auctioneer cannot accept its proposed vault role

**Location:** [VqALCX.acceptAuctioneer](/Users/deepthought/Desktop/dev/vqalcx/src/VqALCX.sol:476), [VqAuctioner](/Users/deepthought/Desktop/dev/vqalcx/src/VqAuctioner.sol:20).

**Description:** acceptance requires the proposed auctioneer address itself to call the vault. The supplied auctioneer has no method that forwards that call. Consequently, deploying the vault with no auctioneer and then proposing a stock `VqAuctioner` does not provide a complete activation route; replacing an existing auctioneer with another stock instance has the same integration gap. Initial address prediction can configure an instance in the vault constructor, as used by the system harness, but does not complete the advertised later replacement lifecycle. Existing authorized auctions are not automatically broken by this missing method, hence Low severity.

**Recommended mitigation:** provide an acceptance method on the auctioneer that calls its immutable vault, retaining the vault's governance-controlled proposal check, or implement an explicitly specified governance activation protocol. Add an integration test using the actual auctioneer contract rather than impersonating an auctioneer EOA. Specify disposition of outstanding bids before changing authorization.

**Fix review:** pending.

### L-2. The staking clock descriptor does not describe its timestamp clock

**Location:** [VqStaking.CLOCK_MODE](/Users/deepthought/Desktop/dev/vqalcx/src/VqStaking.sol:69).

**Description:** `clock()` returns `block.timestamp`, while `CLOCK_MODE()` returns `mode=blockstamp`. Timestamp clocks must identify themselves with `mode=timestamp`. Consumers interpreting the descriptor can reject or misinterpret the integration. The numeric clock and checkpoint hooks alone do not establish a governance exploit, and the actual DAO consumer was not supplied, so severity is Low. [ERC-6372 clock specification](https://eips.ethereum.org/EIPS/eip-6372#clock_mode).

**Recommended mitigation:** resolve the conflict between the late AGENTS.md instruction naming `mode=blockstamp` and ERC-6372; update the documented requirement and implementation to `mode=timestamp`, and check both the numeric clock and descriptor against the actual DAO consumer in an integration regression.

**Fix review:** pending.

### I-1. Deposit maxima aggregate requests that a single claim cannot consume

**Location:** [VqALCX._getFulfillableDepositAmount](/Users/deepthought/Desktop/dev/vqalcx/src/VqALCX.sol:385), [deposit request selection](/Users/deepthought/Desktop/dev/vqalcx/src/VqALCX.sol:353). Affected APIs: `maxDeposit`, `maxMint`, `deposit`, `mint`.

**Description:** the maximum helper sums claimable amounts across all the owner's requests, while claim selection requires the entire requested amount to fit in one request. With multiple partially or fully claimable requests, the advertised maximum can therefore exceed what any single call accepts. Integrators that claim the quoted maximum can revert even though individual requests remain claimable. Smaller separate claims remain possible, so this is a documented custom-interface compatibility limitation rather than evidence of lost backing. ERC-4626 requires maximum methods not to overstate accepted amounts. [Standard](https://eips.ethereum.org/EIPS/eip-4626#maxdeposit).

**Recommended mitigation:** if ERC-4626-compatible maximum semantics are required, either consume a bounded collection of claimable requests in one claim, or conservatively quote the largest amount the current single-request claim path can execute. Keep `deposit` and `mint` consistent and add multiple-request regressions. Resolve the broader custom asynchronous interface separately.

**Fix review:** pending.

### I-2. Withdrawal maxima aggregate requests that a single withdrawal cannot consume

**Location:** [VqALCX._getFulfillableWithdrawAmount](/Users/deepthought/Desktop/dev/vqalcx/src/VqALCX.sol:395), [withdrawal request selection](/Users/deepthought/Desktop/dev/vqalcx/src/VqALCX.sol:369). Affected APIs: `maxWithdraw`, `maxRedeem`, `withdraw`, `redeem`.

**Description:** withdrawal maxima sum multiple claimable requests, but each withdrawal/redemption selects only one request large enough to satisfy the whole call. A consumer following the quoted maximum can fail even with sufficient aggregate claimable escrow. Individual smaller claims remain possible. This is the withdrawal counterpart of I-1. AGENTS.md now explicitly describes that custom convention; compatibility with callers expecting ERC-4626 maxima remains a separate requirement decision. [ERC-4626 withdrawal limits](https://eips.ethereum.org/EIPS/eip-4626#maxwithdraw).

**Recommended mitigation:** if ERC-4626-compatible maxima are required, align maximum calculation and claim aggregation in both withdrawal entry points, preserving owner/allowance checks and atomic accounting. Prefer bounded processing or direct request selection over introducing another unbounded loop.

**Fix review:** pending.

## Unresolved safety concerns and design decisions

These are not additional confirmed vulnerability counts. Some are clear source properties whose practical severity depends on configuration; others need the targeted validation that was interrupted.

| Area / source | Observed property | Required next evidence or decision |
| --- | --- | --- |
| Both `_drip*Bucket` functions; claim paths | Queue traversal is unbounded, and `_drip()` touches both directions before claims. Cancelled entries still require traversal. | A reachable multi-block backlog under realistic gas/capital costs, proof of progression/recovery, and the target chain's gas envelope. A single oversized setup transaction is not sufficient evidence. Prior audit-directory gas claims were not adopted as newly verified findings. |
| Both user-ID search/aggregation helpers | Every claim/maximum can scan the owner's historical request IDs. | Long-history gas measurements and a bounded direct-claim/compaction design. Do not confuse this with the global-queue concern. |
| Both bucket parameter setters | Rate is positive but has no upper bound; setters drip old state before replacing parameters. Multiplications use checked arithmetic. | Supported parameter envelope and recovery tests for erroneous configuration. Checked overflow reverts; it does not wrap into fabricated credit. Treat operator failure separately from public-user compromise. |
| Auction credit and round capacity | Unused credit is retained; round capacity uses rate x duration; rate/round state can span configuration changes. | Approve lifetime versus per-round limits and historical credit policy. The passed integral invariant proves conservation under its model, not every possible governance-delay promise. |
| Bid ranking / settlement price | Ranking compares total prices for bids that may request different quantities. Partial settlement prorates totals with floor division. | Specify unit-price versus total-price objective, minimum fill, rounding, and quantity-dependent price tolerance before declaring revenue misranking a separate defect. |
| Replacement during pending bids | Settlement still needs vault authorization; outstanding bid escrow belongs to the old auctioneer. | Migration/refund design and old/new-instance integration tests. Restore/replace procedures must not assume a method the stock auctioneer lacks. |
| Public `accrueRewards`; cached balance | Index increments and user updates floor fractions; the balance cache can recognize funding not fully represented in allocated reward claims. | Define retained remainders/dust and token precision limits; verify entitlement as well as solvency for realistic funding intervals and stake supply. Aggregate backing tests do not prove fair distribution. |
| Stake/unstake reward update | Principal exit invokes reward-token balance querying and reward arithmetic. Negative reward balance deltas or a failed query can prevent it. | Select supported token semantics and decide whether principal exit must remain available independently of reward accounting; validate supported failure/recovery paths. |
| Token transfers and callbacks | SafeERC20 checks return behavior, not exact amounts or stable external balances. Main guards do not automatically cover all public helper calls. | Actual token implementation review, callback/fee/rebase/blacklist compatibility and targeted cross-function validation. No claim about a particular unspecified token is made. |
| Fixed conversions versus loss-sharing prose | Payouts/conversions are fixed 1:1 and no proportional-loss branch exists. | Approve hard-floor assumptions or design loss allocation including pending deposit claims. Do not silently treat pending principal as available DAO profit. |
| Pause and privileged minting | Governance can stop new withdrawal requests. Authorized auctioneer minting relies on backing transferred by that caller. | Approve exact emergency exit policy and privileged trust boundaries; inspect intended role holders and recovery mechanisms. These powers are not evidence of an unprivileged access-control bypass. |
| Governance acquisition/security goal | Existing shares are transferable and staking/unstaking is immediate; security depends on historical snapshots and external proposal rules. | Actual DAO, delays, quorum, delegation override and token liquidity assumptions. No demonstrated flash-loan governance takeover is claimed. |
| Custom async and view semantics | Requests fund/escrow before claims; views return stored values; previews are fixed conversions. | Reconcile architecture with selected interface. A preview that ignores limits is not by itself an ERC-4626 defect. If ERC-7540 compatibility is intended, its request/controller/preview requirements require explicit implementation review. [ERC-7540](https://eips.ethereum.org/EIPS/eip-7540). |
| Initialization / treasury / duration | Some constructor addresses/duration lack validity bounds; actual deployment script is absent. | Validate nonzero/code/address relationships, duration and bucket initialization in the intended deployment sequence. Do not label a wrong deployer input an attacker-controlled action. |

## Static-analysis and dependency disposition

All 27 Slither results were classified: five equality checks, two non-ETH reentrancy leads, two zero-address checks, two benign reentrancy records, twelve timestamp records, one interface-inheritance suggestion, one naming record and two immutable suggestions. Several identify places needing integration analysis, but none independently proves escrow theft. The mandated `CLOCK_MODE` name is correct even though its returned value is not. Details: [static-analysis triage](reviews/SLITHER_TRIAGE.md).

Pinned dependencies match the recorded git revisions. No retrieved compiler advisory includes version 0.8.36; OpenZeppelin 5.7.0 is outside the applicable advisory versions or has the patch in the inspected tree. This is a dated advisory check, not proof against undisclosed defects. Pin CI action commits, Foundry and the release EVM/compiler settings to improve reproducibility. Details and primary references: [dependency review](reviews/DEPENDENCIES.md).

## Remediation and completion order

1. Resolve auction quantity/floor behavior, async interface rules, loss policy, credit policy and supported reward-token behavior.
2. Correct M-1, L-1 and L-2; resolve the intended compatibility policy for I-1/I-2; and address any additional concern that targeted validation confirms. Each fix should have a regression for its own entry point and sibling paths.
3. Complete realistic queue/claim gas validation, outstanding-bid migration, adversarial token compatibility, and principal-exit failure recovery.
4. Supply actual deployment inputs and exercise the complete DAO/governance, constructor/handover and incident lifecycle in a suitable local/fork environment.
5. Rerun affected unit tests, the full composed accounting model and relevant static checks on the patched commit. Retain source/dependency hashes and deployment configuration. Perform an independent fix review before a release recommendation.

No production patch was made, no deployment transaction was sent, and no remediation retest is claimed. Open questions are enumerated in [SCOPE_AND_REQUIREMENTS.md](SCOPE_AND_REQUIREMENTS.md); the accounting model is in [MONEY_MAP.md](MONEY_MAP.md); commands and evidence provenance are in [REPRODUCE.md](REPRODUCE.md).

## Review-service limitation

The auction, vault and staking specialists stopped with the automatic tool message “This content was flagged for possible cybersecurity risk.” This is a restriction from the reviewer service, **not text found in the project folder and not a finding about project security**. The rejected work was not retried through another tool or reconstructed. Additional AGENTS.md and test/audit/reaudit files appeared late in this pass; their provenance and scope are recorded in LATE_CONTEXT.md, and their test results are not included in the baseline. Completed local checks and safe source/dependency review were retained; unfinished targeted validation is marked above. Consequently the full 12-step plan, including remediation and final sign-off, remains incomplete.
