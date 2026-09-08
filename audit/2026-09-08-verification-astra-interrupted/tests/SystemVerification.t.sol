// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VqALCX} from "../../src/VqALCX.sol";
import {VqAuctioner} from "../../src/VqAuctioner.sol";
import {VqStaking} from "../../src/VqStaking.sol";

contract SystemToken is ERC20 {
    constructor() ERC20("audit", "AUD") {}

    function mint(address to, uint256 n) external {
        _mint(to, n);
    }
}

/// @notice Valid-state stateful campaign. Every executed operation must succeed;
/// inapplicable generated operations are counted explicitly, never caught silently.
contract SystemVerificationTest is Test {
    SystemToken a;
    SystemToken r;
    VqALCX v;
    VqAuctioner q;
    VqStaking s;
    address[3] users = [address(0xA1), address(0xB2), address(0xC3)];
    address treasury = address(0xDA0);
    uint256 dProduced;
    uint256 wProduced;
    uint256 surplus;
    uint256 funded;
    uint256 paid;
    uint256[21] successes;
    uint256[21] skips;
    uint256 constant CAP = 1_000_000 ether;

    function setUp() public {
        a = new SystemToken();
        r = new SystemToken();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        v = new VqALCX(address(a), address(this), predicted);
        q = new VqAuctioner(address(a), address(v), treasury, 30);
        assertEq(address(q), predicted);
        s = new VqStaking(address(v), address(r));
        v.setDepositBucketParams(100 ether, CAP);
        v.setWithdrawBucketParams(100 ether, CAP);
        for (uint256 i; i < 3; ++i) {
            a.mint(users[i], 1_000_000_000 ether);
            vm.startPrank(users[i]);
            a.approve(address(v), type(uint256).max);
            a.approve(address(q), type(uint256).max);
            v.approve(address(q), type(uint256).max);
            v.approve(address(s), type(uint256).max);
            v.requestDeposit(1_000 ether);
            vm.stopPrank();
        }
        _advance(30);
        v.drip();
        for (uint256 i; i < 3; ++i) {
            vm.prank(users[i]);
            v.deposit(1_000 ether, users[i]);
        }
        q.ensureDepositRound();
        q.ensureWithdrawRound();
        _check();
    }

    function _advance(uint256 dt) internal {
        dProduced += v.depositBucketRate() * dt;
        wProduced += v.withdrawBucketRate() * dt;
        vm.warp(block.timestamp + dt);
    }

    function _act(uint256 op, uint256 x) internal {
        address u = users[x % 3];
        uint256 amount = 1 + (x >> 16) % (50 ether);
        bool ok = true;
        if (op == 0) {
            _advance(x % 61);
        } else if (op == 1) {
            v.drip();
        } else if (op == 2) {
            if (v.paused() || v.depositQueueDepth() + amount > CAP) {
                ok = false;
            } else {
                vm.prank(u);
                v.requestDeposit(amount);
            }
        } else if (op == 3 || op == 4) {
            bool dep = op == 3;
            v.drip();
            (,,, uint256 tail,,,) = dep ? v.depositBucket() : v.withdrawBucket();
            ok = false;
            for (uint256 i; i < tail; ++i) {
                VqALCX.Request memory req = dep ? v.getDepositRequest(i) : v.getWithdrawRequest(i);
                if (req.owner == u && req.filled > req.claimed) {
                    amount = 1 + amount % (req.filled - req.claimed);
                    vm.startPrank(u);
                    if (dep) {
                        if (x % 2 == 0) { v.deposit(amount, u); } else { v.mint(amount, u); }
                    } else {
                        if (x % 2 == 0) { v.withdraw(amount, u, u); } else { v.redeem(amount, u, u); }
                    }
                    vm.stopPrank();
                    ok = true;
                    break;
                }
            }
        } else if (op == 5) {
            uint256 bal = v.balanceOf(u);
            if (v.paused() || bal == 0) {
                ok = false;
            } else {
                amount = 1 + amount % bal;
                if (v.withdrawQueueDepth() + amount > CAP) {
                    ok = false;
                } else {
                    vm.prank(u);
                    v.requestWithdraw(amount);
                }
            }
        } else if (op == 6 || op == 7) {
            bool dep = op == 6;
            (,,, uint256 tail,,,) = dep ? v.depositBucket() : v.withdrawBucket();
            ok = false;
            if (tail > 0) {
                uint256 id = x % tail;
                VqALCX.Request memory req = dep ? v.getDepositRequest(id) : v.getWithdrawRequest(id);
                if (!req.cancelled && req.amount > req.filled) {
                    surplus += (req.amount - req.filled) * v.cancellationPenaltyBps() / 10_000;
                    vm.startPrank(req.owner);
                    if (dep) v.cancelDepositRequest(id);
                    else v.cancelWithdrawRequest(id);
                    vm.stopPrank();
                    ok = true;
                }
            }
        } else if (op == 8 || op == 9) {
            bool dep = op == 8;
            VqAuctioner.Round memory round =
                dep ? q.getDepositRound(q.currentDepositRound()) : q.getWithdrawRound(q.currentWithdrawRound());
            if (block.timestamp > round.endTime || round.capacity == 0) {
                ok = false;
            } else {
                amount = 1 + amount % round.capacity;
                if (dep) {
                    uint256 price = amount + 1 ether;
                    if (price <= round.highestBidPrice) price = round.highestBidPrice + 1;
                    vm.prank(u);
                    q.bidDeposit(amount, price);
                } else if (v.balanceOf(u) == 0 || (round.highestBidder != address(0) && round.highestBidPrice == 0)) {
                    ok = false;
                } else {
                    if (amount > v.balanceOf(u)) amount = v.balanceOf(u);
                    uint256 price = amount / 2;
                    if (round.highestBidder != address(0) && price >= round.highestBidPrice) {
                        price = round.highestBidPrice - 1;
                    }
                    vm.prank(u);
                    q.bidWithdraw(amount, price);
                }
            }
        } else if (op == 10 || op == 11) {
            bool dep = op == 10;
            VqAuctioner.Round memory round =
                dep ? q.getDepositRound(q.currentDepositRound()) : q.getWithdrawRound(q.currentWithdrawRound());
            if (block.timestamp < round.endTime || (dep && v.paused())) {
                ok = false;
            } else {
                if (dep) {
                    q.settleDepositRound(round.roundId);
                } else {
                    q.settleWithdrawRound(round.roundId);
                    uint256 fill = q.getWithdrawRound(round.roundId).totalFilled;
                    if (round.highestBidAmount > 0) {
                        surplus += fill - round.highestBidPrice * fill / round.highestBidAmount;
                    }
                }
            }
        } else if (op == 12) {
            uint256 bal = v.balanceOf(u);
            if (bal == 0) {
                ok = false;
            } else {
                vm.prank(u);
                s.stake(1 + amount % bal);
            }
        } else if (op == 13) {
            uint256 bal = s.stakedBalanceOf(u);
            if (bal == 0) {
                ok = false;
            } else {
                vm.prank(u);
                s.unstake(1 + amount % bal);
            }
        } else if (op == 14) {
            funded += amount;
            r.mint(address(s), amount);
        } else if (op == 15) {
            s.accrueRewards();
            if (s.earned(u) == 0) {
                ok = false;
            } else {
                uint256 beforeBal = r.balanceOf(u);
                vm.prank(u);
                s.claimRewards();
                paid += r.balanceOf(u) - beforeBal;
            }
        } else if (op == 16) {
            uint256 bal = v.balanceOf(u);
            if (bal == 0) {
                ok = false;
            } else {
                vm.prank(u);
                v.transfer(users[(x + 1) % 3], 1 + amount % bal);
            }
        } else if (op == 17) {
            vm.prank(u);
            s.delegate(users[(x >> 8) % 3]);
        } else if (op == 18) {
            v.setDepositBucketParams(1 ether + x % (200 ether), CAP);
            v.setWithdrawBucketParams(1 ether + (x >> 8) % (200 ether), CAP);
            v.setCancellationPenaltyBps(x % 501);
        } else if (op == 19) {
            if (v.paused()) v.unpause();
            else v.pause();
        } else if (op == 20) {
            a.mint(address(v), amount);
            surplus += amount;
        }
        if (ok) successes[op]++;
        else skips[op]++;
        _check();
    }

    function _check() internal view {
        uint256 liability;
        uint256 dPending;
        uint256 dFilled;
        (,, uint256 dh, uint256 dt,,, uint256 dc) = v.depositBucket();
        assertLe(dh, dt);
        for (uint256 i; i < dt; ++i) {
            VqALCX.Request memory z = v.getDepositRequest(i);
            assertLe(z.claimed, z.filled);
            assertLe(z.filled, z.amount);
            liability += (z.cancelled ? z.filled : z.amount) - z.claimed;
            if (!z.cancelled) dPending += z.amount - z.filled;
            dFilled += z.filled;
        }
        assertEq(a.balanceOf(address(v)), v.totalSupply() + liability + surplus, "complete backing model");
        assertEq(dPending, v.depositQueueDepth());
        uint256 escrow;
        uint256 wPending;
        uint256 wFilled;
        (,, uint256 wh, uint256 wt,,, uint256 wc) = v.withdrawBucket();
        assertLe(wh, wt);
        for (uint256 i; i < wt; ++i) {
            VqALCX.Request memory z = v.getWithdrawRequest(i);
            assertLe(z.claimed, z.filled);
            assertLe(z.filled, z.amount);
            escrow += (z.cancelled ? z.filled : z.amount) - z.claimed;
            if (!z.cancelled) wPending += z.amount - z.filled;
            wFilled += z.filled;
        }
        assertEq(escrow, v.balanceOf(address(v)), "withdraw escrow");
        assertEq(wPending, v.withdrawQueueDepth());
        for (uint256 i = 1; i <= q.currentDepositRound(); ++i) {
            dFilled += q.getDepositRound(i).totalFilled;
        }
        for (uint256 i = 1; i <= q.currentWithdrawRound(); ++i) {
            wFilled += q.getWithdrawRound(i).totalFilled;
        }
        (,,,,, uint256 dLast,) = v.depositBucket();
        (,,,,, uint256 wLast,) = v.withdrawBucket();
        assertEq(dFilled + dc + v.depositBucketRate() * (block.timestamp - dLast), dProduced, "deposit integral");
        assertEq(wFilled + wc + v.withdrawBucketRate() * (block.timestamp - wLast), wProduced, "withdraw integral");
        assertEq(a.balanceOf(address(q)), q.depositLockedTotal(q.currentDepositRound()));
        assertEq(v.balanceOf(address(q)), q.withdrawLockedTotal(q.currentWithdrawRound()));
        uint256 stakes;
        uint256 rewards;
        for (uint256 i; i < 3; ++i) {
            stakes += s.stakedBalanceOf(users[i]);
            rewards += s.earned(users[i]);
            uint256 expectedVotes;
            for (uint256 j; j < 3; ++j) {
                if (s.delegates(users[j]) == users[i]) expectedVotes += s.stakedBalanceOf(users[j]);
            }
            assertEq(s.getVotes(users[i]), expectedVotes, "delegated voting units");
        }
        assertEq(stakes, s.totalStaked());
        assertEq(stakes, v.balanceOf(address(s)));
        assertEq(paid + r.balanceOf(address(s)), funded, "reward funding conserved");
        assertLe(rewards, r.balanceOf(address(s)), "reward liabilities covered");
    }

    function _exitAll() internal {
        v.unpause();
        _advance(1_000_000);
        v.drip();
        _act(10, 0);
        _act(11, 0);
        (,,, uint256 dt,,,) = v.depositBucket();
        for (uint256 i; i < dt; ++i) {
            VqALCX.Request memory z = v.getDepositRequest(i);
            if (z.filled > z.claimed) {
                vm.prank(z.owner);
                v.deposit(z.filled - z.claimed, z.owner);
            }
        }
        for (uint256 i; i < 3; ++i) {
            uint256 bal = s.stakedBalanceOf(users[i]);
            if (bal > 0) {
                vm.prank(users[i]);
                s.unstake(bal);
            }
            if (s.earned(users[i]) > 0) {
                uint256 beforeBal = r.balanceOf(users[i]);
                vm.prank(users[i]);
                s.claimRewards();
                paid += r.balanceOf(users[i]) - beforeBal;
            }
            bal = v.balanceOf(users[i]);
            if (bal > 0) {
                vm.prank(users[i]);
                v.requestWithdraw(bal);
            }
        }
        _advance(1_000_000);
        v.drip();
        (,,, uint256 wt,,,) = v.withdrawBucket();
        for (uint256 i; i < wt; ++i) {
            VqALCX.Request memory z = v.getWithdrawRequest(i);
            if (z.filled > z.claimed) {
                vm.prank(z.owner);
                v.withdraw(z.filled - z.claimed, z.owner, z.owner);
            }
        }
        _check();
        assertEq(v.totalSupply(), 0);
        assertEq(s.totalStaked(), 0);
        assertEq(a.balanceOf(address(v)), surplus, "last user received all principal");
    }

    function testFuzz_SystemConservationAndLastUserExit(uint256 seed) public {
        for (uint256 i; i < 126; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            _act(seed % 21, seed >> 8);
        }
        _exitAll();
    }

    function test_SystemTransitionEvidence() public {
        // Explicit transition prefix prevents the coverage gate from relying on
        // randomly revisiting a cancellation before the next time advance.
        _act(2, 0);
        _act(6, 3);
        _act(5, 0);
        _act(7, 0);
        _act(12, 0);
        _act(14, 0);
        _act(15, 0);
        _act(13, 0);
        _act(8, 0);
        _act(9, 0);
        _act(0, 30);
        _act(10, 0);
        _act(11, 0);
        _act(17, 0);
        _act(16, 0);
        _act(18, 0);
        _act(19, 0);
        _act(19, 0);
        _act(20, 0);
        _act(1, 0);
        _act(2, 0);
        _act(0, 30);
        _act(3, 0);
        _act(5, 0);
        _act(0, 30);
        _act(4, 0);
        uint256 seed = 0x20260908;
        for (uint256 i; i < 420; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            _act(seed % 21, seed >> 8);
        }
        _exitAll();
        for (uint256 i; i < 21; ++i) {
            emit log_named_uint("operation", i);
            emit log_named_uint("successful", successes[i]);
            emit log_named_uint("inapplicable", skips[i]);
            assertGt(successes[i], 0, "required action not explored");
        }
    }
}
