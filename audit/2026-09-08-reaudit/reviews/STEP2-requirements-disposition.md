# Step 2 — Requirements and threat model disposition (re-audit 2026-09-08)

Baseline document: [../2026-09-08-astra-interrupted/REQUIREMENTS.md](../../2026-09-08-astra-interrupted/REQUIREMENTS.md) (30,970 bytes, prepared at the same commit `5bfb483`). This re-audit reviewed that matrix against the code and the arch.md invariants; no requirement ID changed. Disposition of the open design questions, resolved where the deployed code defines behavior:

| Open question (plan §2) | Code-defined resolution | Status |
|---|---|---|
| 1:1 redemption vs proportional loss sharing | Conversion functions are `pure` 1:1; loss sharing is a governance/social layer, not code | Spec gap acknowledged; watermark invariant validated |
| Escrow/fulfill/claim lifecycle | Deposit principal escrows at `requestDeposit` (doc §4.1 stale); fulfill via drip; claim via `deposit`/`mint`; `claimed <= filled <= amount` enforced | Resolved in code; doc fix required (F-12) |
| Shared queue/auction budget | Drip allocates queue first, residual to `availableAuctionCapacity`; credit accumulates unbounded, no expiry, survives rate cuts | Resolved in code; economic risk F-8 |
| Governance commitment scope | Not enforced on-chain; vqALCX freely transferable, staking instant | Accepted residual trust assumption |
| ERC-4626 promise to integrators | `max*` sums claimable but claims are single-request; previews are pure identity; views do not project drip | Non-conformance validated (F-3, F-4, F-5) |
| Pause policy | Entry blocked (requests + `mintViaAuction`); claims and `burnViaAuction` open; new withdraw *requests* also blocked | Validated (F-14); confirm intent |
| Reward tokens / zero-staker funding | Any ERC-20 accepted; zero-staker donations accrue to first staker; sub-resolution dust strands | Validated (F-7) |
| Chain/token/deployment inputs | Not supplied | Scope limitation (see report) |

Threat model: unchanged from baseline (unprivileged users, compromised auctioneer, compromised governance, accidental configuration, unavailable operators). F-2 (auctioneer replacement escrow stranding) falls in the "accidental configuration + governance action" class; F-1 (drip DoS) is an unprivileged attack.
