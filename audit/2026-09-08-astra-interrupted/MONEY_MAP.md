# Money map and provisional test oracles

Target: 5bfb483025e65ab0a88912eda5295849e6bf944c. These are audit assumptions, not owner-approved specification decisions.

## Assets and liabilities
- ALCX enters vault on requestDeposit and auction settlement; exits on deposit cancellation, withdraw/redeem, burnViaAuction. Deposit requests are funded at request time, contradicting arch.md section 4.1.
- vqALCX is fixed 1:1 raw units, minted on deposit/mint claims or auction mint, burned on withdrawal claims/auction burns/cancellation penalties. Transfers preserve totalSupply. Withdraw requests escrow existing shares in vault.
- Auctioner holds ALCX for deposit high bids and vqALCX for withdrawal high bids. Deposit settlement moves backing to vault, premium to treasury, refund to bidder. Withdrawal settlement burns filled escrow via vault and refunds unfilled shares.
- Staking holds vqALCX principal and distinct rewardToken. Stake/unstake move shares, funding is direct reward transfer, claim moves rewards.

## Tracked totals and writers
| Total | Writers and movement |
|---|---|
| ERC20 supply/balances | deposit/mint/mintViaAuction + supply/receiver; withdraw/redeem/burnViaAuction - supply/escrow; cancelWithdrawRequest - penalty supply; requestWithdraw + vault/-user; cancelWithdrawRequest inverse refund; transfer/transferFrom balance movement |
| bucket.pendingAmount | request +amount; drip -take; cancellation -(amount-filled) |
| bucket.head/tail | request tail++; drip head++ across fulfilled/cancelled records |
| bucket.lastDripTime | constructor and drip replace with timestamp |
| bucket.availableAuctionCapacity | drip +(rate*elapsed - allocated); auction hooks -filled; no cap or expiry |
| request.amount/filled/claimed/cancelled | request sets amount; drip +filled; claim +claimed; cancel sets flag, leaves historical amount/filled |
| per-user request IDs | append on request; never removed |
| round capacity/totalFilled/settled/high bid | start rate*duration; bid replaces winner/amount/price; settle marks and records fill, starts next |
| depositLockedTotal/bids.price | bid +new price and -old refund; settle -clearing price, clears price |
| withdrawLockedTotal/bids.amount | bid +new amount and -old refund; settle -bid amount, clears amount |
| staking _totalStaked/_stakedBalances | stake +amount; unstake -amount |
| rewardPerShare | accrue +(balance-lastBalance)*1e18/totalStaked |
| _lastRewardBalance | accrue replaces currentBalance when new rewards and nonzero total; claim -reward |
| accruedRewards/userRewardPerSharePaid | update +balance*indexDelta/1e18 and replace paid index; claim zero accrued |
| inherited votes/balance/delegate checkpoints | stake/unstake _transferVotingUnits after balance update; delegate and delegateBySig update delegates and vote weights |

## Asymmetries and investigation targets (not findings)
- totalAssets includes pending deposit liabilities; no explicit aggregate tracks all unminted deposit principal.
- mintViaAuction trusts caller to transfer backing; only auctioner contract settlement enforces it.
- cancellation does not persist elapsed drip before computing unfilled remainder.
- unused credit goes to auctions and never back to queue; queue backlog is iteration-based, unbounded by count.
- maxima sum all requests but claim selects one; view functions do not project time.
- reward balance deltas ignore unsolicited stake-share donations correctly; zero-stake reward arrivals and rounding residue need cohort definitions.
- auction replacement authorization requires proposed contract call acceptAuctioneer; inspect actual capability.

## Independent invariants
1. With exact-transfer non-rebasing ALCX and honest auctioner, vaultBalance >= supply + depositLiability.
2. Deposit liability = sum(cancelled ? filled-claimed : amount-claimed); withdrawal escrow shares already count in supply.
3. For each request claimed <= filled <= amount. For noncancelled requests sum(amount-filled) = pendingAmount.
4. Vault share custody covers sum(cancelled ? filled-claimed : amount-claimed) for withdrawals; donations are surplus.
5. Queue allocations + consumed auction credit + remaining credit = piecewise integral of configured rate across elapsed intervals.
6. FIFO holds among noncancelled outstanding requests; each allocated unit is consumed once, claims do not spend rate again.
7. Auction token balances cover current locked totals; completed round liabilities are zero; base + premium + refund = funded bid.
8. Share supply and principal movements conserve under request/claim/cancel/auction combinations.
9. Sum user stakes = totalStaked <= actual staking share custody.
10. Paid rewards plus claim liabilities <= cumulative real reward funding; stranded rounding dust tracked separately.
11. Historical stake and vote checkpoints match timestamp snapshots and remain stable; same-time acquisition and exit are tested separately from actual DAO voting.
12. Public progression and exits should execute within an explicit gas budget, even with adversarial request counts.

## Lifecycles and cohorts
- Depositor: request (asset escrow,pending,tail), drip (filled,pending,head,credit,time), claim (claimed,supply), cancel (flag,pending,refund,penalty). Partial fill retains claim after cancellation.
- Withdrawer: request (share escrow,pending,tail), drip, claim (claimed,burn,asset payout), cancel (flag,pending,share refund,burn penalty).
- Bidder: lock, replacement/refund, expiry, settle partial/full/zero, advance round. Treat last winner, outbid bidder and treasury separately.
- Staker: update historical rewards before joining/leaving, stake/checkpoint, fund/accrue, claim, unstake/checkpoint. Test first, late, last stakers and zero-stake intervals.
- Governance can change rates/capacities, penalty, pause and roles. Auctioner is a privileged mint trust boundary. Tokens may revert or behave nonstandardly; actual token identity is unavailable.

## Unapproved questions
Loss sharing versus hard 1:1; credit cap/expiry; exact ERC4626/ERC7540 promise; current-time views; governance acquisition commitment versus transferable shares; zero-staker reward ownership; pause exits; deployment/DAO/Safe details. Test objective code behavior and report ambiguity separately.
