// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "@forge-std/Test.sol";
import {StdInvariant} from "@forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VqALCX} from "../../../src/VqALCX.sol";
import {VqAuctioner} from "../../../src/VqAuctioner.sol";
import {VqStaking} from "../../../src/VqStaking.sol";

contract MockALCX is ERC20 {
    constructor() ERC20("Alchemix", "ALCX") {}
}

contract MockReward is ERC20 {
    constructor() ERC20("Reward", "RWD") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

/// @notice Cross-contract handler: drives vault, auctioner and staking with
///         random-but-plausible sequences across four actors.
contract CrossHandler is Test {
    VqALCX public vault;
    VqAuctioner public auctioner;
    VqStaking public staking;
    ERC20 public alcx;
    ERC20 public reward;

    address[] public actors;
    address public governance;
    address public treasury;

    uint256 public constant RATE = 50e18;
    uint256 public constant CAPACITY = 1_000_000e18;
    uint256 public constant MAX_TRACKED_DEPOSITS = 600;

    uint256[] public depositIds;
    uint256 public fundedRewards;
    uint256 public paidRewards;

    constructor(
        address _vault,
        address _auctioner,
        address _staking,
        address _alcx,
        address _reward,
        address _governance,
        address _treasury
    ) {
        vault = VqALCX(_vault);
        auctioner = VqAuctioner(_auctioner);
        staking = VqStaking(_staking);
        alcx = ERC20(_alcx);
        reward = ERC20(_reward);
        governance = _governance;
        treasury = _treasury;

        for (uint256 i = 0; i < 4; i++) {
            address actor = address(uint160(0x2000 + i));
            actors.push(actor);
            deal(_alcx, actor, 1_000_000e18);
            vm.startPrank(actor);
            alcx.approve(_vault, type(uint256).max);
            alcx.approve(_auctioner, type(uint256).max);
            vault.approve(_staking, type(uint256).max);
            vault.approve(_auctioner, type(uint256).max);
            vm.stopPrank();
        }
    }

    modifier useActor(uint256 seed) {
        vm.startPrank(actors[bound(seed, 0, actors.length - 1)]);
        _;
        vm.stopPrank();
    }

    function requestDeposit(uint256 seed, uint256 amount) public useActor(seed) {
        amount = bound(amount, 1e18, 5_000e18);
        try vault.requestDeposit(amount) returns (uint256 id) {
            if (depositIds.length < MAX_TRACKED_DEPOSITS) depositIds.push(id);
        } catch {}
    }

    function requestWithdraw(uint256 seed, uint256 amount) public useActor(seed) {
        uint256 bal = vault.balanceOf(actors[bound(seed, 0, actors.length - 1)]);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        try vault.requestWithdraw(amount) {} catch {}
    }

    function claimDeposit(uint256 seed, uint256 amount) public useActor(seed) {
        address actor = actors[bound(seed, 0, actors.length - 1)];
        amount = bound(amount, 1e18, 2_000e18);
        try vault.deposit(amount, actor) {} catch {}
    }

    function claimWithdraw(uint256 seed, uint256 amount) public useActor(seed) {
        address actor = actors[bound(seed, 0, actors.length - 1)];
        uint256 claimable = vault.maxWithdraw(actor);
        if (claimable == 0) return;
        amount = bound(amount, 1, claimable);
        try vault.withdraw(amount, actor, actor) {} catch {}
    }

    function cancelDeposit(uint256 seed, uint256 idSeed) public useActor(seed) {
        uint256 id = bound(idSeed, 0, depositIds.length);
        if (id == depositIds.length) return;
        try vault.cancelDepositRequest(depositIds[id]) {} catch {}
    }

    function cancelWithdraw(uint256 seed, uint256 idSeed) public useActor(seed) {
        uint256 id = bound(idSeed, 0, 50);
        try vault.cancelWithdrawRequest(id) {} catch {}
    }

    function bidDepositRound(uint256 seed, uint256 amount) public useActor(seed) {
        amount = bound(amount, 1e18, 2_000e18);
        try auctioner.bidDeposit(amount, amount + bound(amount, 1, amount / 10)) {} catch {}
    }

    function bidWithdrawRound(uint256 seed, uint256 amount) public useActor(seed) {
        address actor = actors[bound(seed, 0, actors.length - 1)];
        uint256 bal = vault.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        try auctioner.bidWithdraw(amount, amount - amount / 10) {} catch {}
    }

    function settleDeposit() public {
        uint256 r = auctioner.currentDepositRound();
        if (r == 0) return;
        (,,, uint256 endTime,,,,,,) = auctioner.depositRounds(r);
        if (block.timestamp < endTime) return;
        try auctioner.settleDepositRound(r) {} catch {}
    }

    function settleWithdraw() public {
        uint256 r = auctioner.currentWithdrawRound();
        if (r == 0) return;
        (,,, uint256 endTime,,,,,,) = auctioner.withdrawRounds(r);
        if (block.timestamp < endTime) return;
        try auctioner.settleWithdrawRound(r) {} catch {}
    }

    function stake(uint256 seed, uint256 amount) public useActor(seed) {
        address actor = actors[bound(seed, 0, actors.length - 1)];
        uint256 bal = vault.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        try staking.stake(amount) {} catch {}
    }

    function unstake(uint256 seed, uint256 amount) public useActor(seed) {
        address actor = actors[bound(seed, 0, actors.length - 1)];
        uint256 bal = staking.stakedBalanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        try staking.unstake(amount) {} catch {}
    }

    function fundRewards(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        reward.transfer(address(staking), amount);
        fundedRewards += amount;
    }

    function claimRewards(uint256 seed) public useActor(seed) {
        address actor = actors[bound(seed, 0, actors.length - 1)];
        uint256 before = reward.balanceOf(actor);
        try staking.claimRewards() {
            paidRewards += reward.balanceOf(actor) - before;
        } catch {}
    }

    function advanceTime(uint256 seed) public {
        vm.warp(block.timestamp + bound(seed, 1, 2 hours));
        try vault.drip() {} catch {}
        this.settleDeposit();
        this.settleWithdraw();
    }

    function togglePause() public {
        vm.startPrank(governance);
        if (vault.paused()) {
            vault.unpause();
        } else {
            vault.pause();
        }
        vm.stopPrank();
    }

    function reconfigureBuckets(uint256 rateSeed) public {
        vm.startPrank(governance);
        uint256 rate = bound(rateSeed, 1e15, RATE);
        try vault.setDepositBucketParams(rate, CAPACITY) {} catch {}
        try vault.setWithdrawBucketParams(rate, CAPACITY) {} catch {}
        vm.stopPrank();
    }

    function actorsLength() public view returns (uint256) {
        return actors.length;
    }

    function getActor(uint256 i) public view returns (address) {
        return actors[i];
    }

    function depositIdsLength() public view returns (uint256) {
        return depositIds.length;
    }

    function getDepositId(uint256 i) public view returns (uint256) {
        return depositIds[i];
    }
}

/// @title Cross-contract invariants across vault, auctioner and staking
contract CrossContractInvariantTest is StdInvariant, Test {
    CrossHandler public handler;
    VqALCX public vault;
    VqAuctioner public auctioner;
    VqStaking public staking;
    MockALCX public alcx;
    MockReward public reward;

    address public governance = address(0xCAFE);
    address public treasury = address(0xA11CE);

    function setUp() public {
        alcx = new MockALCX();
        reward = new MockReward();
        deal(address(alcx), governance, 1_000_000e18);

        vault = new VqALCX(address(alcx), governance, address(0));
        auctioner = new VqAuctioner(address(alcx), address(vault), treasury, 1 hours);
        staking = new VqStaking(address(vault), address(reward));

        vm.prank(governance);
        vault.proposeAuctioneer(address(auctioner));
        // Real activation path — no impersonation of the contract.
        auctioner.acceptVaultAuctioneer();

        vm.startPrank(governance);
        vault.setDepositBucketParams(50e18, 1_000_000e18);
        vault.setWithdrawBucketParams(50e18, 1_000_000e18);
        vm.stopPrank();

        handler = new CrossHandler(
            address(vault), address(auctioner), address(staking), address(alcx), address(reward), governance, treasury
        );
        reward.transfer(address(handler), 1_000_000_000e18);

        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = handler.requestDeposit.selector;
        selectors[1] = handler.requestWithdraw.selector;
        selectors[2] = handler.claimDeposit.selector;
        selectors[3] = handler.claimWithdraw.selector;
        selectors[4] = handler.cancelDeposit.selector;
        selectors[5] = handler.cancelWithdraw.selector;
        selectors[6] = handler.bidDepositRound.selector;
        selectors[7] = handler.bidWithdrawRound.selector;
        selectors[8] = handler.settleDeposit.selector;
        selectors[9] = handler.settleWithdraw.selector;
        selectors[10] = handler.stake.selector;
        selectors[11] = handler.unstake.selector;
        selectors[12] = handler.fundRewards.selector;
        selectors[13] = handler.claimRewards.selector;
        selectors[14] = handler.advanceTime.selector;
        selectors[15] = handler.advanceTime.selector; // weight time progression
        selectors[16] = handler.claimDeposit.selector; // weight claims

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // ------------------------------------------------------------------
    // Solvency: vault ALCX covers minted supply plus every outstanding
    // deposit obligation (unfilled noncancelled principal + unclaimed
    // filled principal, including cancelled-but-partially-filled).
    // ------------------------------------------------------------------

    function invariant_SolvencyWithDepositLiability() public view {
        uint256 liability = 0;
        uint256 n = handler.depositIdsLength();
        for (uint256 i = 0; i < n; i++) {
            VqALCX.Request memory req = vault.getDepositRequest(handler.getDepositId(i));
            uint256 claimable = req.filled - req.claimed;
            liability += claimable;
            if (!req.cancelled) {
                liability += req.amount - req.filled;
            }
        }
        assertGe(
            alcx.balanceOf(address(vault)), vault.totalSupply() + liability, "vault ALCX < supply + deposit liability"
        );
    }

    // ------------------------------------------------------------------
    // Auction escrow conservation: auctioner balances equal the live
    // locked totals of the current unsettled rounds (zero after settle).
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Non-vacuity: a fixed sequence proving every subsystem executes
    // successfully end-to-end (queue entry -> drip -> claim, auction
    // bid -> settle, stake -> fund -> accrue -> claim).
    // ------------------------------------------------------------------

    function test_NonVacuousCrossSequence() public {
        handler.requestDeposit(0, 100e18);
        assertGt(vault.depositQueueDepth(), 0, "deposit request failed");

        handler.advanceTime(0); // warp >= 1s and drip
        handler.claimDeposit(0, 40e18);
        assertEq(vault.balanceOf(handler.getActor(0)), 40e18, "deposit claim failed");

        handler.bidDepositRound(1, 100e18);
        assertGt(alcx.balanceOf(address(auctioner)), 0, "deposit bid did not lock");

        handler.advanceTime(7199); // > 1 hour round duration
        handler.settleDeposit();
        assertEq(alcx.balanceOf(address(auctioner)), 0, "settlement left escrow");
        assertEq(vault.totalSupply(), 40e18 + 100e18, "winner was not minted");

        handler.bidWithdrawRound(0, 20e18);
        handler.advanceTime(7199);
        handler.settleWithdraw();
        assertEq(vault.balanceOf(address(auctioner)), 0, "withdraw settlement left escrow");

        handler.stake(0, 40e18); // handler bounds to remaining balance
        assertEq(staking.totalStaked(), 20e18, "stake failed (20 shares left after auction burn)");

        handler.fundRewards(1_000_000);
        staking.accrueRewards();
        handler.claimRewards(0);
        assertGt(reward.balanceOf(handler.getActor(0)), 0, "reward claim failed");
    }

    function invariant_AuctionEscrowConservation() public view {
        uint256 dRound = auctioner.currentDepositRound();
        assertEq(
            alcx.balanceOf(address(auctioner)),
            auctioner.depositLockedTotal(dRound),
            "auctioner ALCX != locked deposit bids"
        );
        uint256 wRound = auctioner.currentWithdrawRound();
        assertEq(
            vault.balanceOf(address(auctioner)),
            auctioner.withdrawLockedTotal(wRound),
            "auctioner vqALCX != locked withdraw bids"
        );
    }

    // ------------------------------------------------------------------
    // Staking accounting and reward conservation.
    // ------------------------------------------------------------------

    function invariant_StakingAccounting() public view {
        uint256 sum = 0;
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            address actor = handler.getActor(i);
            sum += staking.stakedBalanceOf(actor);
        }
        assertEq(sum, staking.totalStaked(), "stake sum != totalStaked");
        assertGe(vault.balanceOf(address(staking)), staking.totalStaked(), "custody < recorded stakes");

        uint256 liabilities = 0;
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            liabilities += staking.earned(handler.getActor(i));
        }
        assertLe(handler.paidRewards() + liabilities, handler.fundedRewards(), "rewards paid + owed exceed funding");
        assertLe(
            reward.balanceOf(address(staking)),
            handler.fundedRewards() - handler.paidRewards(),
            "staking reward custody exceeds net funding"
        );
    }
}
