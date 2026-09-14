# AGENTS.md

## Project

veQueue / vqALCX — a Foundry (Solidity) protocol of three first-party contracts that rate-limits ALCX entry/exit into a treasury vault, producing governance-secure share tokens for Alchemix DAO governance. No frontend, no deployment scripts, no `script/` directory — this repo is contracts + tests + docs only.

**Read `arch.md` first.** It is the authoritative arc42 specification: constraints (TC-1…TC-5, OC-1…OC-3), runtime flows, architectural decisions (§9), and the named invariants (INV-*) that tests are written against. `AUDIT_PLAN.md` and `audit/` are working documents of an in-progress security audit (commit `5bfb483` baseline).

## Commands

```sh
forge build --sizes      # build with contract size report (what CI runs)
forge test -vvv          # full suite: ~90 tests, ~20s (invariant suite is most of it)
forge fmt                # format — CI runs `forge fmt --check`, so format before committing
forge coverage
forge snapshot
```

Dependencies are git submodules (OpenZeppelin contracts v5.7.0, forge-std v1.16.1, pinned in `foundry.lock` and `.gitmodules`). After cloning: `git submodule update --init --recursive`.

CI (`.github/workflows/test.yml`) runs exactly: `forge fmt --check`, `forge build --sizes`, `forge test -vvv`.

## Architecture

Three contracts, layered (three-layer DAO separation, TC-2):

1. **`src/VqALCX.sol`** — the vault *and* the share token. ERC-20 + IERC4626 + ReentrancyGuard. Holds ALCX, mints/burns vqALCX. Contains zero DAO-specific logic. Governance and auctioneer are two addresses with two-step handovers (`proposeX` → `acceptX`). `VqAuctioner` exposes `acceptVaultAuctioneer()` so a deployed instance can complete its own acceptance (deployment-time wiring and re-authorization after a rotation).
2. **`src/VqAuctioner.sol`** — pluggable rolling English auctions selling "instant fill" capacity (bypass the queue) for deposits (bid ALCX, receive vqALCX) and withdrawals (bid vqALCX, receive ALCX at a discount). Holds bid escrow; routes premiums to `daoTreasury`.
3. **`src/VqStaking.sol`** — the DAO adapter. Users stake vqALCX here; it inherits OZ `VotesExtended` so the DAO (Aragon) reads voting power from *staked* balances. No receipt token. Push-based rewards: anyone donates reward tokens, balance-delta is lazily accrued into `rewardPerShare` over **seasoned** (post-warm-up) stake only — newly staked balances earn nothing for `REWARD_WARMUP` (1 day) so just-in-time stakes cannot capture donations (voting power and unstake remain instant); a zero-reward `claimRewards()` is a no-op that seasons a matured batch.

### Core mechanism: lazy drip + shared rate budget

- Two independent FIFO queues (deposit/withdraw), each a "leaky bucket" with `capacity` (max pending) and `rate` (per-second fulfillment).
- Queue entries are internal accounting (`Request {owner, amount, filled, claimed, cancelled}`), not tokens. Lifecycle: request → drip fills (`filled`) → user claims via `deposit()`/`withdraw()` (`claimed`).
- **Lazy drip:** `_drip*Bucket()` catches the bucket up to `block.timestamp`: each elapsed window's budget (`rate * elapsed`) is granted exactly once into a persisted `availableBudget` accumulator and `lastDripTime` always advances. Drip fills FIFO entries from `head` out of `availableBudget`; when the queue is fully caught up, the leftover banks into `availableAuctionCapacity`. It runs as a side effect of state-changing vault functions; the public `drip()` advances both queues permissionlessly. Each call touches at most `MAX_DRIP_ENTRIES` (100) entries; if the queue is longer, the unspent budget carries in `availableBudget` to the next call — drip gas is bounded, progress is not, and a time window's budget can never be re-granted (INV-Q-3). Views never drip (EVM purity).
- **Queue and auctions share one rate budget**: the queue fills for free at 1:1; the auctioneer sells leftover `availableAuctionCapacity`. This is the rate limit that makes governance power un-flash-loanable — never let auction fills bypass it.
- **Watermark accounting:** profit = `vault ALCX balance − totalSupply`. Auction premiums, withdrawal-auction discounts, and cancellation penalties accrue as profit above the watermark. Shares are always 1:1 (`convertToAssets(shares) == shares`, pure functions).

### Money flow specifics (easy to get wrong)

- `requestDeposit` **escrows ALCX at request time** (`safeTransferFrom` in `requestDeposit`). Cancellation refunds the unfilled remainder minus `cancellationPenaltyBps`; the filled part stays claimable.
- `requestWithdraw` escrows vqALCX at request time. Cancellation refunds minus `cancellationPenaltyBps` (capped at 500 bps); deposit-cancellation penalty is ALCX, withdraw-cancellation penalty is burned vqALCX.
- `mintViaAuction` (deposit side, `whenNotPaused`) mints to the winner against ALCX the auctioneer already transferred to the vault. `burnViaAuction` (no pause guard) burns from the **auctioneer's own balance** (it holds the locked winning bid) and pays the winner `payoutAmount ≤ burnAmount`; the discount stays in the vault. If the vault is paused at deposit-round settlement, the settle path does not attempt the mint: it refunds the winner's full locked price, settles the round empty, and rotates — a pause never strands the winner's principal (withdraw-side settlement is unpaused by design).
- `maxDeposit`/`maxWithdraw`/`maxMint`/`maxRedeem` are **non-standard**: they return the claimant's **largest single-request claimable** (`filled − claimed`) — not a liquidity cap and not an aggregate — so `deposit(maxDeposit())` always succeeds. `deposit`/`mint`/`withdraw`/`redeem` find a single request with `claimable >= amount` via a linear scan of the user's request-ID array (gas grows with per-user request count; claims are per single request — you cannot claim across multiple requests in one call). `maxDeposit`/`maxMint` quote `msg.sender` (the claimant), not the `receiver` argument; `maxWithdraw`/`maxRedeem` quote `owner`.
- Deposit auctions: higher `maxPrice` wins. Withdrawal auctions are **reverse-ranked**: a *lower* `minPrice` wins (bidder accepts a bigger discount); at equal `minPrice`, a strictly larger amount replaces the leader (keeps floor-price bids outbiddable). Bids lock assets in the auctioneer; outbid users are refunded immediately.

## Hard constraints (violating these breaks the design)

- **TC-3:** all timing uses `block.timestamp`, never `block.number` — Aragon's governance clock depends on it. `VqStaking.clock()` returns the timestamp and `CLOCK_MODE()` returns `"mode=timestamp"` (the ERC-6372 canonical string for a timestamp clock).
- **TC-4:** vqALCX never rebases/accrues yield. `balanceOf` changes only via explicit mint/burn/transfer; share price is pegged 1:1 forever. Protocol profit is *balance surplus*, never share-price appreciation.
- **TC-5:** in `VqStaking`, `_getVotingUnits` returns the internal staked balance, and `_transferVotingUnits` must be called **after** every stake/unstake balance update so checkpoints reflect post-operation state.
- **Vault stays DAO-agnostic;** all DAO-specific code belongs in the staking adapter.
- Compiler is pinned exactly: `pragma solidity 0.8.36;` and `solc = "0.8.36"` in `foundry.toml`. Do not bump casually.

## Conventions

- Imports use remappings `@openzeppelin/contracts/` and `@forge-std/` (note the `@forge-std/` spelling, not `forge-std/`).
- OZ v5 style: custom errors for reverts (`error NotGovernance()`, etc.), `SafeERC20`, `ReentrancyGuard` from `utils/`. (Two legacy `require(..., "auction capacity exceeded")` strings exist in the vault's auction hooks.)
- Formatting (`[fmt]` in foundry.toml): 120-char lines, 4-space tabs, long int types (`uint256`).
- Prefix contracts with `Vq`; two-step role changes follow the `proposeX`/`acceptX` pattern.

## Testing

- Unit tests in `test/unit/<Contract>.t.sol`, one file per contract; invariant tests in `test/invariant/` with a handler contract in `test/invariant/handlers/`.
- Tests use the shared `MockALCX`/`MockReward` from `test/mocks/Mocks.sol` (real ALCX is not in the repo), `vm.prank`/`vm.startPrank`, and named actors: `governance = 0xCAFE`, `auctioneer = 0xBEEF`, `alice`, `bob`. Standard bucket params: `RATE = 100e18`, `CAPACITY = 10_000e18`.
- Invariant pattern: handler wraps vault calls with `bound()` inputs and `try/catch` to swallow expected reverts (so reverts don't abort the run); `advanceTime` uses `vm.warp`. Invariant functions are named `invariant_<Name>` and tagged with the spec's INV- IDs (e.g. `INV-WM-1: vault balance >= totalSupply`).
- Invariant tests target only the vault today; there is no auctioner/staking/cross-contract invariant harness yet (the audit plan calls for one).
- Always write regression tests against `arch.md` invariant IDs when fixing behavior the spec names.

## Gotchas

- `README.md` is the untouched Foundry template — its deploy example references a `script/Counter.s.sol` that does not exist. Ignore it.
- `arch.md` occasionally lags the code. When doc and code disagree, check `AUDIT_PLAN.md` and `audit/` notes — the audit already catalogued several doc/code deltas.
- `audit/` contains dated evidence directories (entry-point inventories, storage layout, dependency/advisory triage, money map) from the ongoing audit; `AUDIT_PLAN.md` is the 12-step execution plan. Treat them as context, not as passing/failing test results.
- Bucket `capacity` is checked against `pendingAmount` (live queued amount), not cumulative; cancelled requests decrement `pendingAmount` immediately, so capacity frees up on cancel.
- Bucket params (`setDepositBucketParams`/`setWithdrawBucketParams`) require `rate > 0` and `capacity >= pendingAmount`, and drip first — changing params mid-queue is safe but consumes accrued time in one lump.
- The audit plan's stated baseline commit is `5bfb483`; recent commits already fix "double-cancel and cap enforcement" and "round settlement" issues — re-verify behavior on HEAD rather than trusting older notes.
