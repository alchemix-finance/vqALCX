// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VqALCX} from "../../src/VqALCX.sol";

contract MockALCX is ERC20 {
    constructor() ERC20("Alchemix", "ALCX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VqALCXTest is Test {
    VqALCX public vault;
    MockALCX public alcx;

    address public governance = address(0xCAFE);
    address public auctioneer = address(0xBEEF);
    address public alice = address(0x1111);
    address public bob = address(0x2222);

    uint256 constant RATE = 100e18; // 100 ALCX per second
    uint256 constant CAPACITY = 10_000e18; // 10,000 ALCX max pending

    function setUp() public {
        alcx = new MockALCX();
        vault = new VqALCX(address(alcx), governance, auctioneer);

        vm.prank(governance);
        vault.setDepositBucketParams(RATE, CAPACITY);

        vm.prank(governance);
        vault.setWithdrawBucketParams(RATE, CAPACITY);

        alcx.mint(alice, 100_000e18);
        alcx.mint(bob, 100_000e18);

        vm.startPrank(alice);
        alcx.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        alcx.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Construction & setup
    // ------------------------------------------------------------------

    function test_Construction() public view {
        assertEq(vault.name(), "veQueue ALCX");
        assertEq(vault.symbol(), "vqALCX");
        assertEq(vault.asset(), address(alcx));
        assertEq(vault.governanceAddress(), governance);
        assertEq(vault.authorizedAuctioneer(), auctioneer);
        assertEq(vault.decimals(), 18);
    }

    function test_RevertZeroAsset() public {
        vm.expectRevert(VqALCX.ZeroAddress.selector);
        new VqALCX(address(0), governance, auctioneer);
    }

    // ------------------------------------------------------------------
    // Queue: request deposit
    // ------------------------------------------------------------------

    function test_RequestDeposit() public {
        uint256 balanceBefore = alcx.balanceOf(alice);
        vm.prank(alice);
        uint256 requestId = vault.requestDeposit(1000e18);

        assertEq(requestId, 0);
        assertEq(vault.depositQueueDepth(), 1000e18);
        assertEq(alcx.balanceOf(alice), balanceBefore - 1000e18);
        assertEq(alcx.balanceOf(address(vault)), 1000e18);

        VqALCX.Request memory req = vault.getDepositRequest(0);
        assertEq(req.owner, alice);
        assertEq(req.amount, 1000e18);
        assertEq(req.filled, 0);
        assertEq(req.claimed, 0);
        assertFalse(req.cancelled);
    }

    function test_RequestDepositCapacityExceeded() public {
        vm.prank(alice);
        vm.expectRevert(VqALCX.CapacityExceeded.selector);
        vault.requestDeposit(CAPACITY + 1);
    }

    function test_RequestDepositRequiresAlcxBalance() public {
        address poor = address(0x5555);
        vm.prank(poor);
        vm.expectRevert();
        vault.requestDeposit(100e18);
    }

    function test_RequestDepositRejectsZero() public {
        vm.prank(alice);
        vm.expectRevert(VqALCX.ZeroAmount.selector);
        vault.requestDeposit(0);
    }

    // ------------------------------------------------------------------
    // Queue: lazy drip fulfillment
    // ------------------------------------------------------------------

    function test_LazyDripFulfillment() public {
        vm.prank(alice);
        vault.requestDeposit(1000e18);

        // Warp forward enough time: 1000 / 100 = 10 seconds
        vm.warp(block.timestamp + 11);

        // Trigger drip
        vault.drip();

        VqALCX.Request memory req = vault.getDepositRequest(0);
        assertEq(req.filled, 1000e18);
        assertEq(vault.depositQueueDepth(), 0);
    }

    function test_LazyDripPartial() public {
        vm.prank(alice);
        vault.requestDeposit(1000e18);

        // Warp only 5 seconds: 5 * 100 = 500 fulfillable out of 1000
        vm.warp(block.timestamp + 5);

        vault.drip();

        VqALCX.Request memory req = vault.getDepositRequest(0);
        assertEq(req.filled, 500e18);
        assertEq(vault.depositQueueDepth(), 500e18);

        vm.warp(block.timestamp + 5);
        vault.drip();

        req = vault.getDepositRequest(0);
        assertEq(req.filled, 1000e18);
        assertEq(vault.depositQueueDepth(), 0);
    }

    function test_PartialDripFillIsClaimable() public {
        vm.prank(alice);
        vault.requestDeposit(1000e18);

        vm.warp(block.timestamp + 5);
        vault.drip();

        assertEq(vault.maxDeposit(alice), 500e18);

        vm.prank(alice);
        vault.deposit(500e18, alice);
        assertEq(vault.balanceOf(alice), 500e18);

        vm.prank(alice);
        vm.expectRevert(VqALCX.RequestNotFulfillable.selector);
        vault.deposit(1, alice);
    }

    // ------------------------------------------------------------------
    // Deposit after drip
    // ------------------------------------------------------------------

    function test_DepositAfterFulfillment() public {
        uint256 balanceBefore = alcx.balanceOf(alice);
        vm.prank(alice);
        vault.requestDeposit(1000e18);

        vm.warp(block.timestamp + 11);

        vm.prank(alice);
        uint256 shares = vault.deposit(1000e18, alice);

        assertEq(shares, 1000e18);
        assertEq(vault.balanceOf(alice), 1000e18);
        assertEq(alcx.balanceOf(address(vault)), 1000e18);
        assertEq(alcx.balanceOf(alice), balanceBefore - 1000e18);
    }

    function test_DepositRevertsIfNotFulfillable() public {
        vm.prank(alice);
        vault.requestDeposit(1000e18);

        // No time warp — not fulfillable
        vm.prank(alice);
        vm.expectRevert(VqALCX.RequestNotFulfillable.selector);
        vault.deposit(1000e18, alice);
    }

    function test_PartialClaimRetainsRemainder() public {
        vm.prank(alice);
        vault.requestDeposit(1000e18);

        vm.warp(block.timestamp + 11);

        vm.startPrank(alice);
        vault.deposit(400e18, alice);
        assertEq(vault.maxDeposit(alice), 600e18);
        vault.deposit(600e18, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 1000e18);
    }

    // ------------------------------------------------------------------
    // Withdraw flow
    // ------------------------------------------------------------------

    function test_RequestWithdrawAndFulfill() public {
        // First deposit
        vm.prank(alice);
        vault.requestDeposit(1000e18);
        vm.warp(block.timestamp + 11);
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        assertEq(vault.balanceOf(alice), 1000e18);

        // Request withdraw: shares are escrowed in the vault
        vm.prank(alice);
        vault.requestWithdraw(1000e18);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(vault)), 1000e18);

        vm.warp(block.timestamp + 11);

        uint256 balanceBefore = alcx.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(1000e18, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(alcx.balanceOf(alice), balanceBefore + 1000e18);
    }

    function test_RequestWithdrawRequiresShareBalance() public {
        vm.prank(bob);
        vm.expectRevert();
        vault.requestWithdraw(100e18);
    }

    // ------------------------------------------------------------------
    // Cancellation
    // ------------------------------------------------------------------

    function test_CancelDepositRequest() public {
        uint256 balanceBefore = alcx.balanceOf(alice);
        vm.prank(alice);
        vault.requestDeposit(1000e18);

        vm.prank(alice);
        vault.cancelDepositRequest(0);

        VqALCX.Request memory req = vault.getDepositRequest(0);
        assertTrue(req.cancelled);
        assertEq(vault.depositQueueDepth(), 0);

        // Net effect: 1% penalty of 1000 = 10 ALCX
        assertEq(alcx.balanceOf(alice), balanceBefore - 10e18);
    }

    function test_CancelWithdrawRequest() public {
        // Deposit first
        vm.prank(alice);
        vault.requestDeposit(1000e18);
        vm.warp(block.timestamp + 11);
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        // Request withdraw
        vm.prank(alice);
        vault.requestWithdraw(1000e18);

        vm.prank(alice);
        vault.cancelWithdrawRequest(0);

        VqALCX.Request memory req = vault.getWithdrawRequest(0);
        assertTrue(req.cancelled);
        assertEq(vault.withdrawQueueDepth(), 0);

        // Escrow returned minus 1% penalty of 1000 = 10 vqALCX burned
        assertEq(vault.balanceOf(alice), 990e18);
        assertEq(vault.totalSupply(), 990e18);
    }

    function test_CancelRevertsIfNotOwner() public {
        vm.prank(alice);
        vault.requestDeposit(1000e18);

        vm.prank(bob);
        vm.expectRevert(VqALCX.NotRequestOwner.selector);
        vault.cancelDepositRequest(0);
    }

    function test_CancelRevertsAfterFullClaim() public {
        vm.prank(alice);
        vault.requestDeposit(1000e18);
        vm.warp(block.timestamp + 11);

        vm.startPrank(alice);
        vault.deposit(1000e18, alice);
        vm.expectRevert(VqALCX.AlreadyFulfilled.selector);
        vault.cancelDepositRequest(0);
        vm.stopPrank();

        assertEq(vault.depositQueueDepth(), 0);
    }

    function test_CancelAfterPartialFillKeepsClaimableAmount() public {
        uint256 balanceBefore = alcx.balanceOf(alice);
        vm.prank(alice);
        vault.requestDeposit(1000e18);
        vm.warp(block.timestamp + 5);
        vault.drip();

        vm.prank(alice);
        vault.cancelDepositRequest(0);

        assertEq(vault.depositQueueDepth(), 0);
        // 500 unfilled refunded minus 1% penalty of 500 = 5 ALCX;
        // the filled 500 stays escrowed and claimable as shares
        assertEq(alcx.balanceOf(alice), balanceBefore - 505e18);

        vm.prank(alice);
        vault.deposit(500e18, alice);
        assertEq(vault.balanceOf(alice), 500e18);
    }

    // ------------------------------------------------------------------
    // ERC-4626 views
    // ------------------------------------------------------------------

    function test_ConvertToSharesAndAssets() public {
        assertEq(vault.convertToShares(1000e18), 1000e18);
        assertEq(vault.convertToAssets(1000e18), 1000e18);
    }

    function test_TotalAssets() public {
        vm.prank(alice);
        vault.requestDeposit(1000e18);
        vm.warp(block.timestamp + 11);
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        assertEq(vault.totalAssets(), 1000e18);
    }

    // ------------------------------------------------------------------
    // Access control
    // ------------------------------------------------------------------

    function test_OnlyGovernanceCanSetParams() public {
        vm.prank(alice);
        vm.expectRevert(VqALCX.NotGovernance.selector);
        vault.setDepositBucketParams(1, 2);
    }

    function test_TwoStepGovernanceTransfer() public {
        address newGov = address(0x3333);

        vm.prank(governance);
        vault.proposeGovernance(newGov);

        vm.prank(newGov);
        vault.acceptGovernance();

        assertEq(vault.governanceAddress(), newGov);
    }

    function test_TwoStepAuctioneerTransfer() public {
        address newAuctioneer = address(0x4444);

        vm.prank(governance);
        vault.proposeAuctioneer(newAuctioneer);
        assertEq(vault.authorizedAuctioneer(), auctioneer);

        vm.prank(newAuctioneer);
        vault.acceptAuctioneer();

        assertEq(vault.authorizedAuctioneer(), newAuctioneer);
    }

    function test_AcceptAuctioneerOnlyByPending() public {
        vm.prank(governance);
        vault.proposeAuctioneer(address(0x4444));

        vm.prank(bob);
        vm.expectRevert(VqALCX.NotAuctioneer.selector);
        vault.acceptAuctioneer();
    }

    // ------------------------------------------------------------------
    // Bucket parameter bounds
    // ------------------------------------------------------------------

    function test_SetBucketParamsRejectsZeroRate() public {
        vm.prank(governance);
        vm.expectRevert(VqALCX.InvalidBucketParams.selector);
        vault.setDepositBucketParams(0, CAPACITY);
    }

    function test_SetBucketParamsRejectsCapacityBelowPending() public {
        vm.prank(alice);
        vault.requestDeposit(1000e18);

        vm.prank(governance);
        vm.expectRevert(VqALCX.InvalidBucketParams.selector);
        vault.setDepositBucketParams(RATE, 999e18);
    }

    function test_CancellationPenaltyBounds() public {
        vm.prank(governance);
        vm.expectRevert(VqALCX.InvalidPenalty.selector);
        vault.setCancellationPenaltyBps(501);

        vm.prank(governance);
        vault.setCancellationPenaltyBps(200);

        uint256 balanceBefore = alcx.balanceOf(alice);
        vm.startPrank(alice);
        vault.requestDeposit(1000e18);
        vault.cancelDepositRequest(0);
        vm.stopPrank();

        assertEq(alcx.balanceOf(alice), balanceBefore - 20e18);
    }

    // ------------------------------------------------------------------
    // Pause
    // ------------------------------------------------------------------

    function test_PauseBlocksNewEntriesAndAllowsWithdrawals() public {
        vm.prank(alice);
        vault.requestDeposit(1000e18);
        vm.warp(block.timestamp + 11);
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vm.prank(alice);
        vault.requestWithdraw(1000e18);
        vm.warp(block.timestamp + 11);

        vm.prank(governance);
        vault.pause();

        vm.startPrank(alice);
        vm.expectRevert(VqALCX.EnforcedPause.selector);
        vault.requestDeposit(100e18);
        vm.expectRevert(VqALCX.EnforcedPause.selector);
        vault.requestWithdraw(100e18);
        vm.expectRevert(VqALCX.EnforcedPause.selector);
        vault.deposit(100e18, alice);
        vm.stopPrank();

        uint256 balanceBefore = alcx.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(1000e18, alice, alice);
        assertEq(alcx.balanceOf(alice), balanceBefore + 1000e18);

        vm.prank(governance);
        vault.unpause();

        vm.prank(alice);
        vault.requestDeposit(100e18);
    }

    // ------------------------------------------------------------------
    // Auction interface
    // ------------------------------------------------------------------

    function test_MintViaAuction() public {
        // Warp to accumulate auction capacity
        vm.warp(block.timestamp + 10); // 10s * 100/s = 1000 capacity

        vm.prank(auctioneer);
        vault.mintViaAuction(alice, 500e18);

        assertEq(vault.balanceOf(alice), 500e18);
    }

    function test_MintViaAuctionCapacityExceeded() public {
        vm.warp(block.timestamp + 10); // 1000 capacity

        vm.prank(auctioneer);
        vm.expectRevert();
        vault.mintViaAuction(alice, 1001e18);
    }

    function test_MintViaAuctionOnlyAuctioneer() public {
        vm.warp(block.timestamp + 10);

        vm.prank(alice);
        vm.expectRevert(VqALCX.NotAuctioneer.selector);
        vault.mintViaAuction(alice, 500e18);
    }

    function test_BurnViaAuctionRejectsPayoutAboveBurn() public {
        vm.warp(block.timestamp + 10);

        vm.prank(auctioneer);
        vm.expectRevert(VqALCX.PayoutExceedsBurn.selector);
        vault.burnViaAuction(alice, 100e18, 101e18);
    }

    // ------------------------------------------------------------------
    // FIFO ordering
    // ------------------------------------------------------------------

    function test_FIFOOrdering() public {
        // Two deposit requests
        vm.prank(alice);
        vault.requestDeposit(500e18);
        vm.prank(bob);
        vault.requestDeposit(500e18);

        // Warp enough for both: 1000 total / 100 per sec = 10 sec
        vm.warp(block.timestamp + 11);

        vault.drip();

        VqALCX.Request memory req0 = vault.getDepositRequest(0);
        VqALCX.Request memory req1 = vault.getDepositRequest(1);
        assertEq(req0.filled, 500e18);
        assertEq(req1.filled, 500e18);
    }

    // ------------------------------------------------------------------
    // Double-claim prevention (CRITICAL security test)
    // ------------------------------------------------------------------

    function test_DepositCannotBeDoubleClaimed() public {
        vm.prank(alice);
        vault.requestDeposit(1000e18);
        vm.warp(block.timestamp + 11);

        // First deposit succeeds
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        assertEq(vault.balanceOf(alice), 1000e18);

        // Second deposit on same request must revert
        vm.prank(alice);
        vm.expectRevert(VqALCX.RequestNotFulfillable.selector);
        vault.deposit(1000e18, alice);

        // Balance unchanged
        assertEq(vault.balanceOf(alice), 1000e18);
    }

    function test_WithdrawCannotBeDoubleClaimed() public {
        // Deposit
        vm.prank(alice);
        vault.requestDeposit(1000e18);
        vm.warp(block.timestamp + 11);
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        // Request withdraw
        vm.prank(alice);
        vault.requestWithdraw(1000e18);
        vm.warp(block.timestamp + 11);

        // First withdraw succeeds
        uint256 balanceBefore = alcx.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(1000e18, alice, alice);
        assertEq(alcx.balanceOf(alice), balanceBefore + 1000e18);

        // Second withdraw must revert
        vm.prank(alice);
        vm.expectRevert(VqALCX.RequestNotFulfillable.selector);
        vault.withdraw(1000e18, alice, alice);
    }

    // ------------------------------------------------------------------
    // Mint/redeem paths
    // ------------------------------------------------------------------

    function test_MintAfterFulfillment() public {
        vm.prank(alice);
        vault.requestDeposit(500e18);
        vm.warp(block.timestamp + 11);

        vm.prank(alice);
        uint256 assets = vault.mint(500e18, alice);

        assertEq(assets, 500e18);
        assertEq(vault.balanceOf(alice), 500e18);
    }

    function test_RedeemAfterFulfillment() public {
        vm.prank(alice);
        vault.requestDeposit(1000e18);
        vm.warp(block.timestamp + 11);
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vm.prank(alice);
        vault.requestWithdraw(1000e18);
        vm.warp(block.timestamp + 11);

        uint256 before = alcx.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(1000e18, alice, alice);
        assertEq(alcx.balanceOf(alice), before + 1000e18);
        assertEq(vault.balanceOf(alice), 0);
    }
}
