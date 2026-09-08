# Dependencies, build controls, and token integration review

Reviewed on 2026-09-08 against commit `5bfb483025e65ab0a88912eda5295849e6bf944c` and the independent snapshot `/tmp/vqalcx-review-8EdnZ3n0`. This review inspected the current source, gitlinks, package metadata, compiler configuration, CI workflow, current advisory evidence, and transitive imports. It did not reproduce exploits, modify production contracts, or interact with deployments. Deployment status, target chain, actual token addresses, token implementations, Safe configuration, and DAO configuration remain unverified.

## Result

The dependency revisions used by the snapshot match the workspace lock file and gitlinks. None of the 63 compiler bug records reviewed includes Solidity 0.8.36 in its affected version interval. Nineteen of the 20 OpenZeppelin advisory records exclude version 5.7.0 by their stated version bounds. The remaining Bytes advisory has an overbroad affected-range field, but its patch is present locally and the relevant function is not called by the project import closure. These conclusions concern the reviewed advisory records; they do not establish that dependencies contain no undisclosed defects.

The main delivery gap is reproducibility: the compiler version is fixed, but the Foundry binary, action revisions, runner image, EVM target, and optimizer settings are not all explicitly fixed. The main integration limitation is that the source requires stronger token behavior than “any ERC-20”: exact movement of underlying principal, stable staked balances, and reward balances that do not unexpectedly decrease. Actual deployed tokens must be checked before these assumptions can be accepted.

## Dependency reconciliation and reachability

| Component | Lock file and gitlink revision | Local package version | Assessment |
|---|---|---|---|
| OpenZeppelin Contracts | `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` | `5.7.0` | Exact match in the installed snapshot dependency tree; working tree clean. Public release points to `cab1993`. |
| forge-std | `620536fa5277db4e3fd46772d5cbc1ea0696fb43` | `1.16.1` | Exact match in the installed snapshot dependency tree; working tree clean. Test dependency, absent from first-party production import closure. |
| Solidity | `0.8.36` in `foundry.toml` and exact first-party pragmas | Effective configuration: `0.8.36` | Version fixed; retain the actual compiler binary/version output with release artifacts. |

Evidence: [foundry.lock](/Users/deepthought/Desktop/dev/vqalcx/foundry.lock), [.gitmodules](/Users/deepthought/Desktop/dev/vqalcx/.gitmodules), [foundry.toml](/Users/deepthought/Desktop/dev/vqalcx/foundry.toml:5), and the [OpenZeppelin release](https://github.com/OpenZeppelin/openzeppelin-contracts/releases/tag/v5.7.0). The snapshot dependency paths are symlinks: `/tmp/vqalcx-review-8EdnZ3n0/lib/openzeppelin-contracts` points to `/tmp/vqalcx-audit-20260908/lib/openzeppelin-contracts`, and the analogous forge-std path points to `/tmp/vqalcx-audit-20260908/lib/forge-std`. HEAD, clean status, and package metadata were verified at those installed targets. This report does not rely on the workspace submodules being initialized; no workspace dependency installation or modification was performed. A tag-like `git describe` label is not a substitute for these exact revisions.

Recursive resolution of all first-party imports produced **37 files: 3 first-party and 34 OpenZeppelin**. The complete file/edge inventory is in [dependency-import-closure.json](/Users/deepthought/Desktop/dev/vqalcx/audit/2026-09-08-verification/evidence/dependency-import-closure.json). Principal components are ERC20, IERC4626, SafeERC20, ReentrancyGuard, Votes/VotesExtended, EIP712/ECDSA, Checkpoints, and their utility dependencies. No first-party proxy, delegatecall, external library link, ERC721 integration, or production forge-std import was found. This is an import inventory, not a proof that every function in every imported library is reachable.

OpenZeppelin 5.7.0 restricts EIP712 constructor name/version strings to at most 31 bytes. The source uses literal `VqStaking` and `1`, so the change does not prevent construction. Unrelated changed components in the release are not automatically in scope merely because the whole dependency repository is present. [Release notes](https://github.com/OpenZeppelin/openzeppelin-contracts/releases/tag/v5.7.0); [VqStaking constructor](/Users/deepthought/Desktop/dev/vqalcx/src/VqStaking.sol:54).

## Advisory triage

### Solidity

The 63 records in [solidity-bugs.json](/Users/deepthought/Desktop/dev/vqalcx/audit/2026-09-08-verification/evidence/solidity-bugs.json) were independently compared using `introduced <= 0.8.36 < fixed`, treating a missing introduction as the earliest version. **Zero match**. This agrees with the empty [solidity-advisory-triage.json](/Users/deepthought/Desktop/dev/vqalcx/audit/2026-09-08-verification/evidence/solidity-advisory-triage.json). The current official [known-bugs documentation](https://docs.soliditylang.org/en/v0.8.36/bugs.html) was also consulted. The [independent reconciliation record](/Users/deepthought/Desktop/dev/vqalcx/audit/2026-09-08-verification/evidence/dependency-review-verification.json) includes per-advisory dispositions and records two distinct comparisons: the three first-party source files match the workspace; the 34 imported dependency files match the verified installed `/tmp/vqalcx-audit-20260908` tree used by the snapshot symlinks. It does not claim those 34 dependency files exist in, or were compared with, the workspace dependency directories.

The newest records include `SOL-2026-3` (fixed in 0.8.36), `SOL-2026-2` (fixed in 0.8.36; additionally requires via-IR), and `SOL-2026-1` (fixed in 0.8.34; via-IR/Cancun conditions). Because the compiler version already excludes every recorded issue, no positive version match requires source-pattern testing. Effective optimizer/via-IR values were nevertheless inspected below. Recheck advisories at deployment and on any compiler/configuration change.

### OpenZeppelin

The [20 captured advisory records](/Users/deepthought/Desktop/dev/vqalcx/audit/2026-09-08-verification/evidence/oz-advisories.json) were inspected individually, selecting the `@openzeppelin/contracts` package entry instead of conflating it with historical or upgradeable packages.

| Advisory IDs | Assessment for this dependency |
|---|---|
| `GHSA-9rcw-c2f9-2j55` | Raw range `>=5.2.0` overlaps, but advisory explicitly identifies 5.4.0 as patched. Locally patched; relevant function not called. See below. |
| `GHSA-9vx6-7xxf-x967`, `GHSA-699g-q6qh-q4v8`, `GHSA-g4vp-m682-qqmp`, `GHSA-wprv-93r4-jj2p`, `GHSA-5h3x-9wvq-w4m2` | Each package interval ends below 5.7.0. |
| `GHSA-mx2q-35m2-x2rh`, `GHSA-93hq-5wgc-jc82`, `GHSA-878m-3g6q-594q`, `GHSA-4h98-2769-gh6h`, `GHSA-9j3m-g383-29qr` | Each package interval ends below 5.7.0. |
| `GHSA-xrc4-737v-9q75`, `GHSA-7grf-83vw-6f5x`, `GHSA-4g63-c64m-25w9`, `GHSA-qh9x-gcfh-pcrw`, `GHSA-m6w8-fq7v-ph4m` | Each `@openzeppelin/contracts` package interval ends below 5.7.0; broad intervals on other historical package names do not identify this dependency. |
| `GHSA-9c22-pwxw-p6hx`, `GHSA-wmpv-c2jp-j2xg`, `GHSA-5vp3-v4hc-gx76`, `GHSA-fg47-3c2x-m2wr` | Each package interval ends below 5.7.0. |

Bytes is transitively imported through Strings/ERC6372Utils/Votes. However, the only `lastIndexOf` references anywhere in the 37-file closure are its definitions, comments, and the two-argument wrapper inside Bytes itself. The reviewed code calls no overload. Independently, [Bytes.sol:58](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/cab19933c33c2ad1d4c7a84864a3601dddfd16f3/contracts/utils/Bytes.sol#L58) initializes the loop with `min(saturatingAdd(pos, 1), length)` and executes it only while `i > 0`. An empty buffer therefore performs no out-of-bounds read. The [maintainer advisory](https://github.com/OpenZeppelin/openzeppelin-contracts/security/advisories/GHSA-9rcw-c2f9-2j55) names 5.4.0 as the patch version despite its open-ended affected field. Mark this advisory **not applicable to the reviewed execution paths**, rather than reporting a dependency vulnerability from the raw range alone.

## Build and delivery controls

Effective values come from [forge-config.json](/Users/deepthought/Desktop/dev/vqalcx/audit/2026-09-08-verification/evidence/forge-config.json), not assumptions about Foundry defaults.

| Item | Observed state | Implication / completion requirement |
|---|---|---|
| Compiler | 0.8.36 | Correctly fixed in source and configuration. |
| EVM target | `prague` effective; absent from `foundry.toml` | Explicitly record the supported chain/fork and pin the release target before comparing deployed bytecode. No chain compatibility conclusion is possible without the chain. |
| Optimizer / runs / via-IR | `false` / `200` / `false` effective; absent from project file | Runs has no active optimizer effect while optimization is disabled. Pin intended release settings; changing them requires rebuild and relevant regression checks. |
| Metadata | IPFS bytecode hash; CBOR metadata enabled | Retain build inputs, compiler binary/version, metadata, constructor arguments, and output hashes for verification. |
| Remappings | Explicit OZ and `@forge-std`; auto-detection enabled | Production imports resolve to the pinned OZ checkout. Preserve dependency layout in the release build. |
| Fuzz / invariants | 256 fuzz runs; 256 invariant runs, depth 500; no fixed seed; invariant `fail_on_revert=false` | These are run settings, not an assertion that handlers reach every transition. Keep seeds and harness metrics with findings. |
| CI source checkout | Recursive submodules; credentials not persisted | Reproduces committed gitlinks and limits credential persistence. |
| Workflow permissions | Top-level empty; job only `contents: read` | Positive least-privilege control. No deployment job or secret use appears in this workflow. |
| Actions / runner / Foundry | `actions/checkout@v6`, `foundry-rs/foundry-toolchain@v1`, `ubuntu-latest`; no explicit Foundry version | Mutable tags and moving environments reduce reproducibility. Pin reviewed action SHAs and a tested Foundry release; record the runner/toolchain environment. |
| CI checks | Format, build with sizes, full Forge tests | No coverage threshold, static-analysis gate, fork integration, deployment smoke test, or release-artifact verification appears in this workflow. This identifies missing gates; it does not imply those tools were run by CI. |
| Deployment procedure | No first-party deployment script or deployment manifest | Confirm constructor wiring, initialized bucket parameters, governance and auctioneer acceptance flow, target chain, and bytecode against a reproducible release package. These are outstanding integration checks. |

The current toolchain action declares that its default `stable` resolves to the latest stable Foundry build, which explains why omitting `version` is not a reproducible binary pin. [Action definition](https://raw.githubusercontent.com/foundry-rs/foundry-toolchain/master/action.yml). GitHub recommends full commit SHAs for immutable action references. [Secure-use guidance](https://docs.github.com/en/actions/reference/security/secure-use). Local evidence is [.github/workflows/test.yml](/Users/deepthought/Desktop/dev/vqalcx/.github/workflows/test.yml:13).

These are delivery hardening and release-validation requirements; this review did not demonstrate a CI compromise or deployment failure.

## Token integration evidence

Scope includes an ERC20 share-token implementation and integration of constructor-selected ALCX, vqALCX, and one reward token. ALCX and reward-token deployed implementations are absent. Token identities are not interchangeable merely because their constructor ABI is `address`.

- **E1 — underlying principal and bid escrow:** [requestDeposit](/Users/deepthought/Desktop/dev/vqalcx/src/VqALCX.sol:172) credits the requested amount after `safeTransferFrom`, without a received-balance comparison. [bidDeposit](/Users/deepthought/Desktop/dev/vqalcx/src/VqAuctioner.sol:149) likewise records nominal bid escrow. Settlement transfers nominal fill amounts to the vault before minting. These paths require exact movement of principal.
- **E2 — shares:** VqALCX inherits unmodified OpenZeppelin ERC20 balance/transfer/approval behavior, including 18 decimals, no rebase, and no token transfer hooks. Conversion functions operate 1:1 in raw units. [Conversions](/Users/deepthought/Desktop/dev/vqalcx/src/VqALCX.sol:251); [ERC20](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/cab19933c33c2ad1d4c7a84864a3601dddfd16f3/contracts/token/ERC20/ERC20.sol#L77).
- **E3 — staking principal:** [stake](/Users/deepthought/Desktop/dev/vqalcx/src/VqStaking.sol:108) credits the nominal transfer amount. It is designed for this vqALCX token; constructor wiring must establish that exact implementation.
- **E4 — reward accounting:** [accrueRewards](/Users/deepthought/Desktop/dev/vqalcx/src/VqStaking.sol:87) reads actual incoming balance delta, but assumes the balance never falls below the cached value. [claimRewards](/Users/deepthought/Desktop/dev/vqalcx/src/VqStaking.sol:161) decrements the cache by nominal outgoing reward. Stake and unstake both invoke reward accrual, coupling principal access to reward-token `balanceOf` and arithmetic.
- **E5 — transfer wrappers:** All external token transfers use SafeERC20. The reviewed [safe transfer implementation](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/cab19933c33c2ad1d4c7a84864a3601dddfd16f3/contracts/token/ERC20/utils/SafeERC20.sol#L188) rejects false, bubbles failures, and accepts empty successful return data only for an address with code. It does not establish that the nominal amount moved.
- **E6 — configured token identity:** [VqStaking constructor](/Users/deepthought/Desktop/dev/vqalcx/src/VqStaking.sol:54) rejects equal reward/stake addresses, but has no zero-address, code, implementation, or alias check. [VqAuctioner constructor](/Users/deepthought/Desktop/dev/vqalcx/src/VqAuctioner.sol:76) does not validate token/vault/treasury wiring. The vault checks nonzero asset/governance, without verifying asset code. These are deployment validation requirements.

## All 24 weird-token categories

“Source-level” means a behavior follows from the reviewed source, not a fork test. “Conditional” means actual-token behavior or additional integration verification is required. “Not applicable” means the code has no relevant feature/path; it is not an assertion about an unknown external token.

| # | Pattern | Classification and support assessment |
|---|---|---|
| 1 | Reentrant transfer callbacks / ERC777 hooks | **Conditional; unsupported without further review.** Main user transfer functions have guards, but `accrueRewards()` is public and unguarded and auction vault hooks are not all guarded. A guard on the calling function does not establish cross-function accounting safety. Reward and underlying tokens should be validated as callback-free unless a separate callback-aware review is completed. E1/E4/E5. |
| 2 | Missing return values / false on success | **Source-level supported for empty success data.** SafeERC20 accepts empty success data from contracts and rejects false. Tokens returning false despite moving funds revert the entire call and are incompatible. E5. |
| 3 | Fee on transfer | **Conditional; principal unsupported.** Nominal vault/auction/staking credits can exceed receipts. Reward donation accrual observes net receipt, but a fee taken from the receiver reduces delivered rewards; a fee additionally charged to the sender breaks the cache assumption. E1/E3/E4. |
| 4 | Balance changes outside transfers | **Conditional; negative changes unsupported.** Rebasing/slashing underlying can reduce backing. Decreasing rewards below the cache reverts accrual and therefore stake/unstake; positive reward deltas are distributable by design. Shares themselves do not rebase. E2/E4. |
| 5 | Upgradeable tokens | **Conditional.** Immutable token addresses do not make external implementations immutable. No implementation-change monitoring or freeze logic exists; assess real token admin/upgrade powers and repeat token review after changes. E6. |
| 6 | Flash-mintable tokens | **Conditional.** No first-party flash mint API; the existence and size of external flash liquidity are unknown. Governance resistance requires the full queue/auction/DAO timing analysis and cannot be inferred from SafeERC20. E1/E2. |
| 7 | Blocklists | **Conditional; liveness depends on token policy.** Transfers may block refunds, claims, settlement, or principal return. Immediate refunds make auction progression depend on successful transfer to the previous bidder. No alternate refund mechanism is present. E1/E4/E5. |
| 8 | Pausable tokens | **Conditional; liveness depends on token policy.** An external pause can stop transfers; a `balanceOf` failure also blocks stake and unstake. VqALCX's own pause controls queue admission/auction minting and does not pause inherited ERC20 transfers. E2/E4. |
| 9 | Approval reset/race restrictions | **Not applicable to protocol-issued external approvals.** First-party contracts issue no external approvals; users must follow their token's approval rules. VqALCX inherits standard overwrite-style approval semantics, so integrations must manage the usual allowance-update race. E2/E5. |
| 10 | Approval to zero address reverts | **Not applicable to an internal approval flow.** No external approval is issued. Inherited VqALCX approvals reject zero spenders. E2. |
| 11 | Zero-value approvals revert | **Not applicable to an internal approval flow.** No protocol approval-reset operation exists; client approval UX remains token-specific. E5. |
| 12 | Zero-value transfers revert | **Conditional; not universally supported.** Most flows reject zero or skip zero payouts, but `burnViaAuction` always transfers `payoutAmount`, which may be zero. A winning withdrawal accepting zero payout with positive fill therefore requires zero-transfer compatibility of the underlying. [Vault hook](/Users/deepthought/Desktop/dev/vqalcx/src/VqALCX.sol:416). |
| 13 | Multiple token addresses / aliases | **Conditional.** Literal equal reward/stake addresses are rejected, but aliases sharing balances are not identified. No token rescue/alias double-accounting feature exists; deployed reward/stake identities must be economically distinct. E6. |
| 14 | Low decimals | **Conditional.** Principal accounting is raw-unit 1:1 while shares report 18 decimals; non-18-decimal underlying changes whole-token interpretation. Reward arithmetic uses raw reward units and floors; low decimals amplify visible dust. E2/E4. |
| 15 | High decimals | **Conditional.** No decimal normalization or supported-value bound exists. Large reward deltas are multiplied by 1e18 with checked arithmetic, so extreme raw balances can revert accrual. Large prices/rates also require arithmetic-bound review. E1/E4. |
| 16 | `transferFrom` with source equal to caller | **Source-level conventional.** First-party contracts use `transfer` for their own external holdings and `transferFrom` to pull users' holdings. Inherited VqALCX `transferFrom` spends allowance even for owner-as-spender, apart from infinite allowance behavior. E2/E5. |
| 17 | Non-string metadata | **Not applicable to external metadata consumption.** Contracts do not decode underlying/reward name or symbol; share metadata is locally defined. A future client must handle actual metadata encoding. E2. |
| 18 | Transfer to zero address reverts | **Source-level/conditional.** VqALCX inherited transfer/mint operations reject zero destinations; user vault withdrawals depend on the underlying token's transfer behavior. Auction treasury is not checked at construction, so zero treasury can prevent premium settlement for standard tokens. E2/E6. |
| 19 | False return instead of revert | **Source-level supported as failure.** SafeERC20 converts false into a revert so surrounding accounting rolls back. A token reporting success without moving value is not detected by a wrapper alone. E1/E5. |
| 20 | Large approvals revert | **Not applicable to protocol-issued external approvals.** Users may choose token-compatible approval amounts. VqALCX itself supports uint256 allowances with the standard infinite-allowance exception. E2/E5. |
| 21 | Code injection via name/symbol | **Not applicable to this repository's execution paths.** No frontend or metadata-rendering path exists. Future interfaces must treat token metadata as untrusted text. E2. |
| 22 | Unusual permit signatures | **Not applicable.** No external token permit path exists; VqALCX does not inherit ERC20Permit. Inherited staking `delegateBySig` is delegation, not token approval. |
| 23 | Transfer less than requested, including special max values | **Conditional; principal unsupported.** Like fee-on-transfer, nominal credit is unsafe if the actual amount moved is smaller. Reward donations use observed net receipt, while outgoing claims assume nominal debit. E1/E3/E4. |
| 24 | ERC20 representation of native currency | **Conditional / no native accounting path.** Contracts are nonpayable and have no native-currency deposit, withdrawal, or dual accounting mechanism. An ERC20/native alias must still satisfy the exact token assumptions; no supported target-chain representation has been identified. |

This completes the source-level checklist, not deployed-token certification. No ERC721 interface is used, so ERC721-specific categories are not applicable. No holder-distribution, supply-concentration, exchange-liquidity, flash-liquidity, upgrade-admin, or real-token fork result is claimed. Automated ERC property generation and `slither-check-erc` were not executed by this dependency reviewer; standard share-token methods were inspected through the pinned ERC20 implementation, and async vault conformance belongs in the separate interface review.

## Required integration decisions

1. Identify target chain and exact ALCX, reward-token, vault, staking, auctioneer, treasury, governance, and DAO addresses; record verified implementations and mutable admin powers.
2. Limit supported principal tokens to exact-transfer, non-rebasing semantics compatible with 18-decimal vqALCX accounting, or implement explicitly specified normalization/accounting changes and retest them.
3. Define the allowed reward-token behavior, including sender fees, negative rebases, freezes, callbacks, overflow bounds, and whether principal exit must remain possible when rewards malfunction.
4. Validate actual constructor wiring, role handover capability, bucket initialization, DAO clock interpretation, and normal/emergency exit flows in a fork or staging deployment.
5. Freeze the release build configuration and toolchain, retain build artifacts and constructor arguments, and compare deployment bytecode/configuration to that record.

These remain open requirements because the needed integration inputs are not supplied. They are not evidence that the project is deployed or undeployed.
