# Evidence and reproduction

Report target: `5bfb483025e65ab0a88912eda5295849e6bf944c`. Fresh verification snapshot: `/tmp/vqalcx-review-8EdnZ3n0`.

## What was executed

The following commands ran in the isolated snapshot. Logs reside in `evidence/` beside this document.

```sh
forge --version
forge fmt --check
forge build --sizes
forge test --no-match-path 'test/audit/*' -vvv
forge coverage --no-match-path 'test/audit/*'
forge config --json

FOUNDRY_OUT=/tmp/vqalcx-review-system-out \
FOUNDRY_CACHE_PATH=/tmp/vqalcx-review-system-cache \
forge test --match-path test/audit/SystemVerification.t.sol \
  --fuzz-runs 1024 --fuzz-seed 0x20260908 -vv

FOUNDRY_OUT=/tmp/vqalcx-review-slither-out \
FOUNDRY_CACHE_PATH=/tmp/vqalcx-review-slither-cache \
/tmp/vqalcx-audit-tools-20260908/bin/slither . \
  --filter-paths 'lib/|test/' --exclude-dependencies \
  --json /Users/deepthought/Desktop/dev/vqalcx/audit/2026-09-08-verification/evidence/slither.json
```

Baseline tests and coverage used the recorded default 256 invariant runs and depth 500; their random seed was not explicitly fixed. The new system campaign used the explicit seed above. Its single fuzzed test executes 126 actions for each of 1,024 inputs (129,024 generated actions before terminal cleanup), and a separate directed test confirms successful execution of every one of 21 action categories. These are simulated state transitions, not production transaction-count or gas-throughput measurements.

The system harness uses three users, exact-transfer mock asset/reward tokens, the actual three first-party contracts and a funded-request entry lifecycle. It models all principal liabilities, surplus, queue/auction budget consumption, escrow, recorded stakes, reward funding and delegated votes. It then closes remaining participant positions. Its generator avoids unsupported token behavior and invalid configurations. It does not claim coverage of every state, ideal reward fairness, realistic worst-case queue gas, migrated auctioneers, or the actual external DAO.

## Recreate a clean local test checkout

Use the pinned source and dependency revisions and the recorded tool versions. For example, from the repository root:

```sh
audit_replay_dir=$(mktemp -d /tmp/vqalcx-replay-XXXXXXXX)
git clone --no-checkout . "$audit_replay_dir"
git -C "$audit_replay_dir" checkout --detach 5bfb483025e65ab0a88912eda5295849e6bf944c
git -C "$audit_replay_dir" submodule update --init --recursive
mkdir -p "$audit_replay_dir/test/audit"
cp audit/2026-09-08-verification/tests/SystemVerification.t.sol "$audit_replay_dir/test/audit/"
cd "$audit_replay_dir"
forge test --no-match-path 'test/audit/*' -vvv
forge test --match-path test/audit/SystemVerification.t.sol --fuzz-runs 1024 --fuzz-seed 0x20260908 -vv
```

These reproduction instructions were not themselves run as a second clone. They recreate the recorded checkout layout and test command. Inspect the resulting dependency revisions against `foundry.lock` and compare effective build settings to `evidence/forge-config.json`. Forge version changes may alter generated sequences even with a fixed seed.

## Provenance and limitations

- `verification-manifest.json`: hashes, first-party/configuration snapshot equality, unchanged production diff and system campaign settings.
- `source-hashes.txt`, `dependency-import-closure.json`, `dependency-review-verification.json`: exact source/dependency inputs and provenance.
- `baseline-*.log`: fresh formatting/build/test/coverage output. Audit-test source present during coverage instrumentation was excluded from execution; use the three `src/` rows when assessing production coverage.
- `system-tests.log`: accepted composed-model and directed-transition results. `tests/SystemVerification.t.sol` is the reviewed/re-executed harness retained for replay.
- `slither.json` and `slither.log`: raw detector evidence; `reviews/SLITHER_TRIAGE.md` classifies all 27 records. Nonzero detector exit status is not an analysis failure when JSON success is true.
- `solidity-bugs.json`, `solidity-advisory-triage.json`, `oz-advisories.json`: fresh upstream advisory snapshots and version triage. A Python download attempt failed certificate validation; normal verified-TLS curl downloads succeeded. TLS verification was not disabled.
- `staking-tests.log`: supplemental completed specialist-run output, 19 tests passed. The specialist's final review was interrupted by a service filter; this is not a completed independent sign-off. Its unfinished targeted work was not reconstructed or incorporated into the accepted system-test deliverable.
- No new vault/auction specialist reproduction log or completed report was delivered after those reviewers were stopped. Earlier files under `audit/2026-09-08/` are older artifacts, not freshly verified outcomes for this pass.
- No live chain transaction, fork against specified real contracts, deployment configuration verification, production remediation or patch retest occurred.

The automatic “possible cybersecurity risk” message came from the reviewer service. It did not originate in repository source or establish any project vulnerability. See `SCOPE_AND_REQUIREMENTS.md` for the complete plan-status matrix.
