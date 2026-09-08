# Money map and tested properties

Target: `5bfb483025e65ab0a88912eda5295849e6bf944c`. This is an accounting model of the reviewed implementation, conditional on ordinary exact-transfer tokens and the supplied honest auctioneer. It does not settle contradictory architecture requirements.

## Asset flows

- Vault ALCX: enters through funded deposit requests and auction settlement; leaves through cancellation refunds, withdrawal/redemption and auction burns. Direct donations create surplus under this model.
- vqALCX: requests for withdrawal escrow existing shares in the vault. Deposit/mint claims and auction mints increase supply; withdrawals, auction burns and withdrawal-cancellation penalties reduce it. Ordinary transfers preserve supply.
- Auction escrow: ALCX covers the current deposit winning bid; vqALCX covers the current withdrawal winning bid. Replacement refunds the preceding bid. Deposit settlement splits charged funds between backing and treasury, returning unused funds. Withdrawal settlement burns filled shares, pays ALCX and returns unfilled shares.
- Staking: vqALCX principal is held separately from the immutable reward token. Stake/unstake change recorded principal and voting units. Reward funding is pushed into the contract; balance deltas feed the index; claims transfer rewards out.

## Tracked state and writers

| State | Writers |
| --- | --- |
| Share supply and balances | Deposit/mint/auction mint increase supply; withdrawal/redeem/auction burn/cancellation penalty decrease it. Request/cancel/ordinary ERC20 transfers move balances. |
| Bucket pending | Request adds amount; drip subtracts allocated fill; cancellation subtracts unfilled remainder. |
| Bucket head/tail | Request appends at tail; drip advances head across completed or cancelled entries. |
| Bucket time/rate/capacity | Constructor sets last time; drip replaces last time; governance updates rate/capacity after dripping the old settings. |
| Auction credit | Drip adds produced budget not assigned to queued requests; auction hook subtracts filled amount. No explicit expiry/cap exists. |
| Request amount/filled/claimed/cancelled | Creation initializes; drip increases filled; claim increases claimed; cancellation sets flag while retaining filled and claimed history. |
| User request-ID arrays | Request appends; no removal/compaction path. |
| Round/highest bid | Start initializes capacity and times; bid replaces leader; settlement marks settled, records fill and starts successor. |
| Locked bid totals | Bid adds new escrow and subtracts preceding refund; settlement subtracts the settled winning obligation. |
| Staked balances/total | Stake increases; unstake decreases. Voting checkpoints follow those updates. |
| Reward index/cache | Accrual increases index by a floored ratio and replaces cached reward balance; claim subtracts paid rewards from the cache. |
| User rewards/paid index | User update adds floored earned rewards and advances the user's index; claim clears accrued rewards. |
| Votes/delegates/history | Stake/unstake update voting units; inherited delegation APIs move delegated weight and preserve historical checkpoints. |

## Core accounting equations

For each deposit request, outstanding principal is `amount - claimed` when not cancelled, or `filled - claimed` when cancelled. Sum these to obtain `depositLiability`. With the stated assumptions:

`vault ALCX = total share supply + depositLiability + recorded surplus`.

For withdrawal requests, the same per-request outstanding expression represents shares still escrowed in the vault. Those shares already count in total supply, so do not add them to ALCX liabilities again. An unsolicited donation to a custody contract must be represented as surplus rather than fictitious user stake or bid credit.

For each bucket:

`queue fills + auction fills + available credit + time credit not yet persisted = integral of configured rate over elapsed time`.

Fulfillment allocates budget; a later token claim must not consume that budget a second time. The integral is a lifetime accounting identity, not proof of an intended per-round or per-user holding-period guarantee.

For staking:

`sum(user recorded stakes) = total recorded stake <= actual share custody`;

`paid rewards + current reward custody = cumulative real funding`;

`sum(recorded reward claims) <= reward custody`.

The last inequality tests solvency, not ideal fair distribution. It does not detect all rounding residue, timing policy disagreements, or unsupported external token behavior.

## Lifecycles and terminal checks

The system harness interleaves funded requests, drip, partial claims, cancellations, both auction directions, settlements, stake changes, reward funding/claims, share transfers, delegation, rate/penalty changes, pause transitions and vault donations. It checks accounting after each action, then unpauses, settles outstanding work, unstakes everyone, claims remaining user principal and checks that only modeled surplus remains in the vault.

The harness represents three users with exact-transfer tokens, positive bounded rates, fixed pending capacity and the original authorized auctioneer. It does not model malicious governance, token callbacks, token upgrades, auctioneer migration, real DAO proposal execution, arbitrary insolvency or chain-enforced transaction gas limits. It counts inapplicable operations separately and does not catch unexpected action reverts. A directed transition test requires each of its 21 operation categories to execute successfully.
