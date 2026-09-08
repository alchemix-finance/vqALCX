// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VqALCX} from "../../src/VqALCX.sol";
import {VqAuctioner} from "../../src/VqAuctioner.sol";

contract MockALCX is ERC20 {
    constructor() ERC20("Alchemix", "ALCX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VqAuctionerTest is Test {
    VqALCX public vault;
    VqAuctioner public auctioner;
    MockALCX public alcx;

    address public governance = address(0xCAFE);
    address public treasury = address(0xDEAD);
    address public alice = address(0x1111);
    address public bob = address(0x2222);

    uint256 constant RATE = 100e18;
    uint256 constant CAPACITY = 10_000e18;
    uint256 constant ROUND_DURATION = 3600; // 1 hour

    function setUp() public {
        alcx = new MockALCX();
        vault = new VqALCX(address(alcx), governance, address(0)); // no auctioneer yet

        auctioner = new VqAuctioner(address(alcx), address(vault), treasury, ROUND_DURATION);

        // Set auctioneer on vault
        vm.prank(governance);
        vault.setAuthorizedAuctioneer(address(auctioner));

        // Set bucket params
        vm.prank(governance);
        vault.setDepositBucketParams(RATE, CAPACITY);
        vm.prank(governance);
        vault.setWithdrawBucketParams(RATE, CAPACITY);

        // Mint tokens
        alcx.mint(alice, 1_000_000e18);
        alcx.mint(bob, 1_000_000e18);

        vm.startPrank(alice);
        alcx.approve(address(vault), type(uint256).max);
        alcx.approve(address(auctioner), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        alcx.approve(address(vault), type(uint256).max);
        alcx.approve(address(auctioner), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    function test_Construction() public view {
        assertEq(address(auctioner.alcx()), address(alcx));
        assertEq(address(auctioner.vqALCX()), address(vault));
        assertEq(auctioner.daoTreasury(), treasury);
        assertEq(auctioner.roundDuration(), ROUND_DURATION);
    }

    // ------------------------------------------------------------------
    // Deposit auction
    // ------------------------------------------------------------------

    function test_DepositBid() public {
        // Warp to accumulate vault auction capacity
        vm.warp(block.timestamp + 100); // 100 * 100 = 10,000 capacity

        uint256 roundId = auctioner.ensureDepositRound();
        assertEq(roundId, 1);

        vm.prank(alice);
        auctioner.bidDeposit(1000e18, 1050e18); // pay 1050 for 1000 vqALCX

        VqAuctioner.Round memory round = auctioner.getDepositRound(1);
        assertEq(round.highestBidder, alice);
        assertEq(round.highestBidAmount, 1000e18);
        assertEq(round.highestBidPrice, 1050e18);
    }

    function test_DepositBidOutbids() public {
        vm.warp(block.timestamp + 100);

        auctioner.ensureDepositRound();

        // Alice bids 1050
        vm.prank(alice);
        auctioner.bidDeposit(1000e18, 1050e18);

        uint256 aliceBalBefore = alcx.balanceOf(alice);

        // Bob outbids with 1100
        vm.prank(bob);
        auctioner.bidDeposit(1000e18, 1100e18);

        // Alice should be refunded
        assertEq(alcx.balanceOf(alice), aliceBalBefore + 1050e18);

        VqAuctioner.Round memory round = auctioner.getDepositRound(1);
        assertEq(round.highestBidder, bob);
        assertEq(round.highestBidPrice, 1100e18);
    }

    function test_DepositBidTooLow() public {
        vm.warp(block.timestamp + 100);
        auctioner.ensureDepositRound();

        vm.prank(alice);
        auctioner.bidDeposit(1000e18, 1050e18);

        vm.prank(bob);
        vm.expectRevert(VqAuctioner.BidTooLow.selector);
        auctioner.bidDeposit(1000e18, 1050e18); // same price, not higher
    }

    function test_DepositAuctionSettlement() public {
        vm.warp(block.timestamp + 100);
        auctioner.ensureDepositRound();

        vm.prank(alice);
        auctioner.bidDeposit(1000e18, 1050e18);

        // Warp past round end
        vm.warp(block.timestamp + ROUND_DURATION + 1);

        uint256 treasuryBefore = alcx.balanceOf(treasury);
        auctioner.settleDepositRound(1);

        // Alice gets 1000 vqALCX
        assertEq(vault.balanceOf(alice), 1000e18);

        // Treasury gets 50 ALCX premium
        assertEq(alcx.balanceOf(treasury), treasuryBefore + 50e18);

        // Vault gets 1000 ALCX backing
        assertEq(alcx.balanceOf(address(vault)), 1000e18);
    }

    function test_DepositRoundStartsNextAfterSettlement() public {
        vm.warp(block.timestamp + 100);
        auctioner.ensureDepositRound();

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        auctioner.settleDepositRound(1);

        // Next round should be active
        assertEq(auctioner.currentDepositRound(), 2);
    }

    // ------------------------------------------------------------------
    // Withdraw auction
    // ------------------------------------------------------------------

    function test_WithdrawBid() public {
        // First get some vqALCX for bob via deposit auction
        vm.warp(block.timestamp + 100);
        auctioner.ensureDepositRound();

        vm.prank(alice);
        auctioner.bidDeposit(1000e18, 1050e18);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        auctioner.settleDepositRound(1);

        // Alice now has 1000 vqALCX
        assertEq(vault.balanceOf(alice), 1000e18);

        // Alice approves auctioneer for vqALCX
        vm.startPrank(alice);
        vault.approve(address(auctioner), type(uint256).max);

        // Bid in withdraw auction: burn 1000 vqALCX, want at least 970 ALCX
        auctioner.ensureWithdrawRound();
        auctioner.bidWithdraw(1000e18, 970e18);
        vm.stopPrank();

        VqAuctioner.Round memory round = auctioner.getWithdrawRound(1);
        assertEq(round.highestBidder, alice);
        assertEq(round.highestBidAmount, 1000e18);
        assertEq(round.highestBidPrice, 970e18);
    }

    function test_WithdrawAuctionSettlement() public {
        // Setup: get alice vqALCX via deposit
        vm.warp(block.timestamp + 100);
        auctioner.ensureDepositRound();
        vm.prank(alice);
        auctioner.bidDeposit(1000e18, 1050e18);
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        auctioner.settleDepositRound(1);

        assertEq(vault.balanceOf(alice), 1000e18);

        // Withdraw auction
        vm.warp(block.timestamp + 100);
        vm.startPrank(alice);
        vault.approve(address(auctioner), type(uint256).max);
        auctioner.ensureWithdrawRound();
        auctioner.bidWithdraw(1000e18, 970e18);
        vm.stopPrank();

        vm.warp(block.timestamp + ROUND_DURATION + 1);

        uint256 aliceAlcxBefore = alcx.balanceOf(alice);
        auctioner.settleWithdrawRound(1);

        // Alice gets 970 ALCX
        assertEq(alcx.balanceOf(alice), aliceAlcxBefore + 970e18);

        // Alice's vqALCX burned
        assertEq(vault.balanceOf(alice), 0);

        // 30 ALCX stays in vault (discount = protocol profit)
        assertGe(alcx.balanceOf(address(vault)), 30e18);
    }

    // ------------------------------------------------------------------
    // Round expiry
    // ------------------------------------------------------------------

    function test_BidAfterRoundExpiry() public {
        vm.warp(block.timestamp + 100);
        auctioner.ensureDepositRound();

        vm.warp(block.timestamp + ROUND_DURATION + 1);

        vm.prank(alice);
        vm.expectRevert(VqAuctioner.RoundNotActive.selector);
        auctioner.bidDeposit(1000e18, 1050e18);
    }

    function test_NoBidsSettlement() public {
        vm.warp(block.timestamp + 100);
        auctioner.ensureDepositRound();

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        auctioner.settleDepositRound(1); // no bids

        // Next round starts
        assertEq(auctioner.currentDepositRound(), 2);
    }

    // ------------------------------------------------------------------
    // Auction capacity bounded by bucket rate
    // ------------------------------------------------------------------

    function test_AuctionCapacityBoundedByRate() public {
        vm.warp(block.timestamp + 100); // 100s * 100/s = 10,000 capacity

        auctioner.ensureDepositRound();

        VqAuctioner.Round memory round = auctioner.getDepositRound(1);
        assertEq(round.capacity, RATE * ROUND_DURATION);
    }

    // ------------------------------------------------------------------
    // INV-A-3: Auctioneer ALCX balance = 0 after settlement
    // ------------------------------------------------------------------

    function test_AuctioneerAlcxBalanceZeroAfterDepositSettlement() public {
        vm.warp(block.timestamp + 100);
        auctioner.ensureDepositRound();

        vm.prank(alice);
        auctioner.bidDeposit(1000e18, 1050e18);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        auctioner.settleDepositRound(1);

        assertEq(alcx.balanceOf(address(auctioner)), 0, "INV-A-3: ALCX left in auctioneer");
    }

    function test_AuctioneerVqALCXBalanceZeroAfterWithdrawSettlement() public {
        // Setup: alice gets vqALCX
        vm.warp(block.timestamp + 100);
        auctioner.ensureDepositRound();
        vm.prank(alice);
        auctioner.bidDeposit(1000e18, 1050e18);
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        auctioner.settleDepositRound(1);

        // Withdraw auction
        vm.warp(block.timestamp + 100);
        vm.startPrank(alice);
        vault.approve(address(auctioner), type(uint256).max);
        auctioner.ensureWithdrawRound();
        auctioner.bidWithdraw(1000e18, 970e18);
        vm.stopPrank();

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        auctioner.settleWithdrawRound(1);

        assertEq(vault.balanceOf(address(auctioner)), 0, "INV-A-3: vqALCX left in auctioneer");
    }
}
