# Dependencies, delivery controls, and static-analysis triage

Target: `5bfb483025e65ab0a88912eda5295849e6bf944c`; audit date: 2026-09-08. This report covers plan step 10 using saved audit evidence and read-only inspection of the isolated checkout. Production code was not changed. The protocol is undeployed; actual intended chain, ALCX, reward token, Safe and DAO implementation remain unspecified.

## Reproducible source and build

| Dependency | Lockfile label | Git revision | Reconciliation |
|---|---|---|---|
| OpenZeppelin Contracts | v5.7.0 | `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` | Root gitlink, `foundry.lock`, installed HEAD agree; installed package metadata is 5.7.0; dependency working tree clean. |
| forge-std | v1.16.1 | `620536fa5277db4e3fd46772d5cbc1ea0696fb43` | Root gitlink, lockfile and installed HEAD agree; dependency working tree clean. Test-only dependency. |

`.gitmodules` points to the official OpenZeppelin and Foundry repositories. The dependency manifest also records OpenZeppelin's nested test dependencies: erc4626-tests `232ff9ba8194e406967f52ecc5cb52ed764209e9`, forge-std `1801b0541f4fda118a10798fd3486bb7051c5dd6`, and halmos-cheatcodes `7328abe100445fc53885c21d0e713b95293cf14c`. These are outside the first-party production import graph. The `v4.8.0-1217-gcab19933` descriptive string in the submodule-status output is a nearest-tag description, not a conflicting dependency revision; the exact SHA and package metadata identify the audited tree. Evidence: [dependencies.txt](evidence/dependencies.txt), `foundry.lock`, root gitlinks and installed package metadata.

The recursive source import closure contains 37 Solidity files: the three first-party contracts and 34 OpenZeppelin files. Relevant implementations include ERC20, SafeERC20, ReentrancyGuard, Votes/VotesExtended, EIP712/ECDSA, Nonces, Checkpoints, SafeCast, Math, Strings/Bytes, Time and ERC6372Utils, plus their interfaces/helpers. Import presence does not imply every library function is reachable in deployed bytecode. No ERC165Checker, Base64, Governor, proxy/upgrade, ERC721, ERC1155, Multicall or ERC2771 implementation is imported by first-party production source.

| Effective setting | Audited value |
|---|---|
| Forge | 1.5.1-stable; commit `b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2` |
| Solidity | 0.8.36, explicitly configured and required by all first-party pragmas |
| EVM / compiler pipeline | Prague; optimizer disabled; via-IR disabled; optimizer-runs value 200 is inactive |
| Metadata | IPFS bytecode hash, CBOR metadata enabled |
| Local test gas | 1,073,741,824 gas; no configured block gas limit; transaction gas-limit enforcement disabled |
| Fuzz / invariants | 256 fuzz runs; 256 invariant runs at depth 500; invariant fail-on-revert disabled; no fixed baseline seed in configuration |
| Environment assumptions | No configured chain ID, RPC URL or fork block; FFI disabled |

The local gas allowance is much higher than a normal deployment transaction budget. Baseline success therefore does not establish queue liveness; the dedicated gas reproduction uses an explicit 30 million gas call limit. Intended chain compatibility with the Prague compilation target still needs confirmation. Evidence: [forge-config.json](evidence/forge-config.json).

`forge fmt --check` produced no output and the baseline build succeeded. Compiler warnings concerned a future `at` keyword in dependency Checkpoints and a test mutability annotation; lint output also included naming and test-only unchecked-return/cast suggestions. These are not confirmed runtime vulnerabilities. First-party sizes from [baseline-build.log](evidence/baseline-build.log):

| Contract | Runtime bytes | Initcode bytes | Reported runtime margin | Reported initcode margin |
|---|---:|---:|---:|---:|
| VqALCX | 20,013 | 21,696 | 4,563 | 27,456 |
| VqAuctioner | 11,634 | 12,410 | 12,942 | 36,742 |
| VqStaking | 14,476 | 16,017 | 10,100 | 33,135 |

These margins pass the size limits checked by the local build. They do not validate a particular destination chain or future patched bytecode. Baseline testing and coverage are summarized in [REQUIREMENTS.md](REQUIREMENTS.md).

## Compiler and OpenZeppelin advisories

The saved Solidity known-bug list contains 63 records. The corresponding [version triage](evidence/solidity-advisory-triage.json) is an empty array: **zero saved affected-version ranges matched Solidity 0.8.36**. In particular, saved SOL-2026-3 and SOL-2026-2 list 0.8.36 as their fixed version; SOL-2026-1 lists 0.8.34. This is a result against that captured advisory dataset, not a claim that the compiler has no unknown defects or that future advisories cannot apply. Primary upstream reference: [Solidity known compiler bugs](https://github.com/ethereum/solidity/blob/develop/docs/bugs.json); saved snapshot: [solidity-bugs.json](evidence/solidity-bugs.json).

The saved [OpenZeppelin advisory response](evidence/oz-advisories.json) contains 20 records. Triage considers the correct package, fixed versions, and imported code, rather than using a vulnerable-range string alone:

| Advisory group | Applicability to this target |
|---|---|
| [GHSA-9rcw-c2f9-2j55: Bytes `lastIndexOf`](https://github.com/OpenZeppelin/openzeppelin-contracts/security/advisories/GHSA-9rcw-c2f9-2j55) | The API's broad `>=5.2.0` range omits an upper bound, but its patch field and description specify 5.4.0. The installed 5.7.0 code bounds its loop by buffer length; an empty buffer performs no read and returns the sentinel. Bytes is imported transitively, but no first-party/other imported caller invokes this `lastIndexOf` overload. **Not an applicable vulnerability at the pinned tree.** |
| [GHSA-4h98-2769-gh6h: ECDSA malleability](https://github.com/OpenZeppelin/openzeppelin-contracts/security/advisories/GHSA-4h98-2769-gh6h) | ECDSA is imported for delegation signatures. Saved affected range ends before 4.7.3; 5.7.0 is beyond that fixed release. This does not waive review of the project's domain, nonce, expiry and signature integration. |
| [GHSA-7grf-83vw-6f5x: ERC165Checker gas consumption](https://github.com/OpenZeppelin/openzeppelin-contracts/security/advisories/GHSA-7grf-83vw-6f5x), [GHSA-qh9x-gcfh-pcrw: ERC165Checker revert](https://github.com/OpenZeppelin/openzeppelin-contracts/security/advisories/GHSA-qh9x-gcfh-pcrw) | Both concern ERC165Checker, which is absent from the production import graph. The scoped `@openzeppelin/contracts` affected ranges also end at earlier 4.x patches. Broad ranges for legacy `openzeppelin-solidity`/`openzeppelin-eth` package names do not describe this dependency. |
| [GHSA-9vx6-7xxf-x967: Base64 dirty memory](https://github.com/OpenZeppelin/openzeppelin-contracts/security/advisories/GHSA-9vx6-7xxf-x967) | Base64 is not imported; saved patch versions are 5.0.2/4.9.6, before this pinned version. |
| Remaining 15 saved records | Cover Multicall; ERC2771Context; MerkleProof; Governor and GovernorCompatibilityBravo/QuorumFraction; TransparentUpgradeableProxy; ERC721Consecutive; Arbitrum cross-chain helpers; SignatureChecker; Initializable; ERC1155Supply; UUPSUpgradeable; TimelockController. Those implementations are absent from the production import graph and the saved affected `@openzeppelin/contracts` versions are older 3.x/4.x ranges. No applicable first-party runtime advisory path was identified in this captured set. Full IDs, patch versions and primary URLs remain in the saved JSON. |

## Slither: all 27 results triaged

Slither 0.11.6 analyzed 37 contracts with 102 detectors. Its JSON reports `success: true`, `error: null`, and **27 detector results**, which are leads rather than 27 vulnerabilities. Both descriptions and affected code were read. Evidence: [slither.log](evidence/slither.log), [slither.json](evidence/slither.json); detector semantics: [Slither's official documentation](https://github.com/crytic/slither/wiki/Detector-Documentation).

| Detector / count | Locations and disposition |
|---|---|
| `incorrect-equality` / 5 | Two elapsed-zero checks, two exact request-completion checks, and staking's zero-reward check. **Rejected as vulnerability claims.** Same-timestamp no-op is deliberate; `take <= remaining` bounds fulfillment and makes exact completion reachable; zero reward is an intended error. Queue gas failures and reward rounding require their own concrete paths and are not proved by these equalities. |
| `reentrancy-no-eth` / 2 | Both auction settlements. **Token-conditional leads retained.** Settled state is set before token interactions; guarded bid/settlement entry points prevent a same-contract reentrant bid or second settlement. However, unguarded `ensureDepositRound`/`ensureWithdrawRound` can be reached by a callback-capable underlying/recipient during settlement, starting a round before the outer settlement starts another. This can skip an empty round/change event ordering. Ordinary supplied vault `drip` and ERC20 mint do not themselves call arbitrary user code. No escrow theft was established by these results; token/recipient callback compatibility needs a dedicated test before allowing that class. Guarding `ensure*` consistently or making rollover idempotent removes the state discrepancy. |
| `missing-zero-check` / 2 | Vault constructor auctioneer: **intentional**, source explicitly allows zero during initialization. Auction constructor treasury: **configuration-validation lead**, because zero is accepted and there is no setter; a positive-premium transfer may revert or send value to an unintended address depending on the underlying token. Require a valid treasury during deployment and add constructor validation. This requires a bad deployment argument, not an unprivileged postdeployment change. |
| `reentrancy-benign` / 2 | Both bidding functions' external self-call to `ensure*`. **Rejected as a demonstrated exploit.** This enters the supplied contract, creates/reads the round, and reads the known vault's rate getter before bid writes. The outer bid's guard remains active. External token callback concerns during other phases are treated separately above. |
| `timestamp` / 12 | Two drip functions, auction hooks, both bucket setters, two `ensure*`, two bid methods, two settlement methods. **Informational / expected time dependency.** Timestamp is the required queue/auction clock. At exact expiry both bidding and settlement are permitted, so ordering decides which executes first; this deserves explicit auction policy but is not randomness misuse or proof of theft. Unbounded rate arithmetic and banked capacity have separate audit evidence. |
| `missing-inheritance` / 1 | VqALCX structurally implements the auctioneer's IVqALCX calls without inheriting that interface. **Informational.** Selectors/signatures agree; absence of explicit inheritance does not break dispatch. |
| `naming-convention` / 1 | `VqStaking.CLOCK_MODE`. **Rejected naming warning.** The uppercase API name is required by the clock interface. Its returned descriptor's correctness is a separate standards finding, not this warning. |
| `immutable-states` / 2 | Auction treasury and duration are assigned only in construction. **Informational optimization/intent note.** No public setter or unintended mutation path exists. The architecture's promise of mutable duration is tracked separately. |

Count reconciliation: 24 results rejected or informational, one constructor-configuration lead, and two callback-dependent settlement leads. No Slither result alone establishes a public-user asset-loss finding. This classification does not suppress separately reproduced logic/accounting findings in the audit report.

## CI and token integration limits

The workflow at `.github/workflows/test.yml` uses default `permissions: {}`, grants the check job only `contents: read`, disables checkout credential persistence, fetches recursive submodules, and runs formatting, build sizes and tests. It has no deployment step, secret reference, write-token grant or artifact publication step in the supplied file.

Delivery controls need hardening for reproducibility: `actions/checkout@v6` and `foundry-rs/foundry-toolchain@v1` are movable tags rather than commit SHAs; `ubuntu-latest` is also moving; the Foundry installer has no explicit toolchain version. Pin action commits and the intended Foundry release, explicitly set EVM/optimizer/via-IR choices, and retain the effective configuration and source/dependency hashes alongside release bytecode. These are delivery-control recommendations, not evidence that an upstream action or credential is compromised. No production deployment scripts were supplied for verification.

SafeERC20 in the pinned tree accepts successful empty-return calls only when the token address has code, rejects false returns, and bubbles failed token calls. Therefore a generic claim that SafeERC20 silently succeeds against an EOA is false for this dependency. It does **not** establish received-amount equality or prevent transfer fees, rebases, blacklist/pausing, callbacks, unusual decimals, malicious return data, or later token upgrades.

Vault requests and auction escrow book requested amounts rather than measured net receipts. Fee-on-transfer or rebasing underlying tokens can invalidate principal/escrow accounting. A negative reward-token rebase can make `currentBalance - _lastRewardBalance` revert; callback-capable tokens add the settlement paths noted above; blocked transfers can prevent claims/refunds. Share decimals are fixed at inherited ERC20's 18 while raw-unit conversions are 1:1. These are **unsupported/conditional integration behaviors until exact token implementations and supported behaviors are selected**, not assertions about an unspecified real ALCX/reward deployment. Complete the token and chain register in [REQUIREMENTS.md](REQUIREMENTS.md) before release.
