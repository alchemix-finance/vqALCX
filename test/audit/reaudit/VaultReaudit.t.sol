// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VqALCX} from "../../../src/VqALCX.sol";
import {VqAuctioner} from "../../../src/VqAuctioner.sol";

contract MockALCX is ERC20 {
    constructor() ERC20("Alchemix", "ALCX") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

/// @title Re-audit validation tests for the VqALCX vault and VqAuctioner
/// @notice Regression tests for vault and auctioner audit remediations.
contract VaultReauditTest is Test {
    VqALCX internal vault;
    VqAuctioner internal auctioner;
    MockALCX internal alcx;

    address internal governance = address(0xCAFE);
    address internal alice = address(0x1111);
    address internal bob = address(0x2222);

    uint256 internal constant RATE = 100e18;
    uint256 internal constant CAPACITY = 100_000_000e18;

    function setUp() public {
        alcx = new MockALCX();
        vault = new VqALCX(address(alcx), governance, address(0));
        auctioner = new VqAuctioner(address(alcx), address(vault), address(0xA11CE), 1 hours);

        vm.prank(governance);
        vault.proposeAuctioneer(address(auctioner));
        // Real activation path: the auctioneer accepts through its own entry
        // point — no vm.prank impersonation of the contract.
        auctioner.acceptVaultAuctioneer();

        vm.startPrank(governance);
        vault.setDepositBucketParams(RATE, CAPACITY);
        vault.setWithdrawBucketParams(RATE, CAPACITY);
        vm.stopPrank();

        alcx.transfer(alice, 1_000_000e18);
        vm.startPrank(alice);
        alcx.approve(address(vault), type(uint256).max);
        alcx.approve(address(auctioner), type(uint256).max);
        vault.approve(address(auctioner), type(uint256).max);
        vm.stopPrank();
    }

    function _giveAliceVqALCX(uint256 amount) internal {
        vm.startPrank(alice);
        vault.requestDeposit(amount);
        vm.warp(block.timestamp + 41);
        vault.deposit(amount, alice);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Drip work is bounded to MAX_DRIP_ENTRIES per call
    // and unspent fulfillment budget carries over (lastDripTime is only
    // advanced once the queue is caught up), so dust spam can never brick
    // the vault — repeated drip calls always make progress.
    // ------------------------------------------------------------------

    function _spamDepositRequests(address who, uint256 n) internal {
        vm.startPrank(who);
        for (uint256 i = 0; i < n; i++) {
            vault.requestDeposit(1);
        }
        vm.stopPrank();
    }

    function test_DripGasIsBounded() public {
        _spamDepositRequests(alice, 4000);
        vm.warp(block.timestamp + 100);
        uint256 g0 = gasleft();
        vault.drip();
        uint256 used = g0 - gasleft();
        emit log_named_uint("drip gas, 4000 dust requests (bounded)", used);
        // One call touches at most MAX_DRIP_ENTRIES (100) entries regardless
        // of queue length: gas stays far below any block gas limit.
        assertLt(used, 3_500_000);
    }

    function test_DripBudgetCarriesOverUntilQueueCaughtUp() public {
        _spamDepositRequests(alice, 250);
        vm.warp(block.timestamp + 100);

        // 250 entries > 100 per call: three drips walk the whole queue,
        // and the time bucket is only consumed once it is drained.
        vault.drip();
        assertGt(vault.depositQueueDepth(), 0, "queue not fully drained in one call");
        vault.drip();
        assertGt(vault.depositQueueDepth(), 0, "queue not fully drained in two calls");
        vault.drip();
        assertEq(vault.depositQueueDepth(), 0, "queue drained after three calls");

        // Budget did not leak to auctions while queued dust was pending…
        uint256 midCredit = vault.depositAuctionCapacity();
        // …and once caught up, residual credit accrues normally.
        vm.warp(block.timestamp + 10);
        vault.drip();
        assertGt(vault.depositAuctionCapacity(), midCredit + RATE * 10 - 2);

        // Claims work again after spam: vault is not bricked.
        vm.prank(alice);
        uint256 max = vault.maxDeposit(alice);
        assertEq(max, 1, "largest single dust claimable");
        vm.prank(alice);
        vault.deposit(1, alice);
        assertEq(vault.balanceOf(alice), 1);
    }

    // ------------------------------------------------------------------
    // maxDeposit quotes the largest single-request
    // claimable, so deposit(maxDeposit()) always succeeds even when the
    // claimable spans multiple requests.
    // ------------------------------------------------------------------

    function test_MaxDepositQuotesExecutableAmount() public {
        vm.startPrank(alice);
        vault.requestDeposit(60e18);
        vault.requestDeposit(40e18);
        vm.warp(block.timestamp + 10);
        vm.stopPrank();

        // Views do not project elapsed drip (documented: views are pure reads).
        vm.prank(alice);
        assertEq(vault.maxDeposit(alice), 0, "view does not project elapsed drip");

        vault.drip();

        // Quoted for the caller (the claimant), not the receiver argument.
        assertEq(vault.maxDeposit(alice), 0, "quoted for msg.sender, uninvolved caller");

        // Largest single request is 60e18 — deposit(maxDeposit) must succeed.
        vm.startPrank(alice);
        uint256 max = vault.maxDeposit(alice);
        assertEq(max, 60e18);
        vault.deposit(max, alice);
        assertEq(vault.balanceOf(alice), 60e18);

        // Then the second request becomes quotable and executable.
        assertEq(vault.maxDeposit(alice), 40e18);
        vault.deposit(40e18, alice);
        assertEq(vault.balanceOf(alice), 100e18);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Previews are pure 1:1 conversions and
    // views do not advance the queue — EVM views cannot mutate state. The
    // spec (arch.md) documents this; executability is signalled by max*.
    // ------------------------------------------------------------------

    function test_PreviewDoesNotReflectQueue() public {
        assertEq(vault.previewDeposit(50e18), 50e18);
        assertEq(vault.previewWithdraw(50e18), 50e18);
        vm.prank(alice);
        vm.expectRevert(VqALCX.RequestNotFulfillable.selector);
        vault.deposit(50e18, alice);
    }

    // ------------------------------------------------------------------
    // Replacing the auctioneer still blocks the old
    // instance from settling (NotAuctioneer), but escrow is no longer
    // stranded: governance re-proposes the old instance and its
    // acceptVaultAuctioneer() entry point completes the re-authorization,
    // after which settlement releases the escrow.
    // ------------------------------------------------------------------

    function test_AuctioneerReplacementRecoversDepositEscrow() public {
        _giveAliceVqALCX(2000e18);
        vm.prank(alice);
        auctioner.bidDeposit(2000e18, 2100e18);

        (,,, uint256 endTime,,,,,,) = auctioner.depositRounds(auctioner.currentDepositRound());
        vm.warp(endTime);

        address auctioner2 = address(0xD00D);
        vm.prank(governance);
        vault.proposeAuctioneer(auctioner2);
        vm.prank(auctioner2);
        vault.acceptAuctioneer();

        assertEq(alcx.balanceOf(address(auctioner)), 2100e18, "escrow locked");
        uint256 r = auctioner.currentDepositRound();
        vm.expectRevert(VqALCX.NotAuctioneer.selector);
        auctioner.settleDepositRound(r);

        // Recovery: re-propose the old instance; anyone can trigger its
        // acceptance through the real entry point.
        vm.prank(governance);
        vault.proposeAuctioneer(address(auctioner));
        auctioner.acceptVaultAuctioneer();
        assertEq(vault.authorizedAuctioneer(), address(auctioner));

        uint256 aliceVqBefore = vault.balanceOf(alice);
        auctioner.settleDepositRound(r);
        assertEq(alcx.balanceOf(address(auctioner)), 0, "escrow released");
        assertGt(vault.balanceOf(alice), aliceVqBefore, "winner minted");
    }

    function test_AuctioneerReplacementRecoversWithdrawEscrow() public {
        _giveAliceVqALCX(4000e18);
        vm.startPrank(alice);
        vault.requestWithdraw(2000e18);
        vm.warp(block.timestamp + 30);
        vault.withdraw(2000e18, alice, alice);
        auctioner.bidWithdraw(2000e18, 1900e18);
        vm.stopPrank();

        (,,, uint256 endTime,,,,,,) = auctioner.withdrawRounds(auctioner.currentWithdrawRound());
        vm.warp(endTime);

        address auctioner2 = address(0xD00D);
        vm.prank(governance);
        vault.proposeAuctioneer(auctioner2);
        vm.prank(auctioner2);
        vault.acceptAuctioneer();

        assertEq(vault.balanceOf(address(auctioner)), 2000e18, "share escrow locked");
        uint256 r = auctioner.currentWithdrawRound();
        vm.expectRevert(VqALCX.NotAuctioneer.selector);
        auctioner.settleWithdrawRound(r);

        vm.prank(governance);
        vault.proposeAuctioneer(address(auctioner));
        auctioner.acceptVaultAuctioneer();

        uint256 aliceAlcxBefore = alcx.balanceOf(alice);
        auctioner.settleWithdrawRound(r);
        assertEq(vault.balanceOf(address(auctioner)), 0, "escrow released");
        assertEq(alcx.balanceOf(alice), aliceAlcxBefore + 1900e18, "winner paid");
    }

    // ------------------------------------------------------------------
    // Auction credit is rebased when governance changes
    // the rate, so accumulated credit cannot outlive a rate cut.
    // ------------------------------------------------------------------

    function test_AuctionCreditRebasesOnRateCut() public {
        vm.warp(block.timestamp + 100);
        vm.prank(governance);
        vault.drip();
        uint256 creditBefore = vault.depositAuctionCapacity();
        assertGe(creditBefore, 10_000e18);

        // Cut the rate 100x: credit is rebased to the new rate's denomination.
        vm.prank(governance);
        vault.setDepositBucketParams(1e18, CAPACITY);
        uint256 rebased = vault.depositAuctionCapacity();
        assertEq(rebased, creditBefore / 100, "credit rebased by rate ratio");

        vm.warp(block.timestamp + 10);
        vm.prank(governance);
        vault.drip();
        assertEq(vault.depositAuctionCapacity(), rebased + 10e18, "new credit accrues at new rate");
    }

    // ------------------------------------------------------------------
    // Cancellation drips first, so the refund reflects the
    // fulfillment persisted up to block.timestamp without a manual drip,
    // and the filled portion stays claimable afterwards.
    // ------------------------------------------------------------------

    function test_CancelPersistsElapsedDrip() public {
        uint256 bal0 = alcx.balanceOf(alice);
        vm.startPrank(alice);
        vault.requestDeposit(1000e18);
        vm.warp(block.timestamp + 1); // 1s * RATE = 100e18 filled
        vm.stopPrank();

        // No manual drip: cancel itself persists the elapsed fulfillment.
        vm.prank(alice);
        vault.cancelDepositRequest(0); // refunds 900e18 minus 1% penalty = 891e18
        vm.prank(alice);
        vault.deposit(100e18, alice); // filled portion still claimable

        assertEq(vault.balanceOf(alice), 100e18);
        // alice: -1000 escrow at request, +891 refund; the remaining 100e18
        // is now backed by 100 minted shares and 9e18 stays as penalty.
        assertEq(bal0 - alcx.balanceOf(alice), 109e18);
    }

    // ------------------------------------------------------------------
    // Pause matrix: entry blocked under pause; claims stay open; new
    // withdraw requests are blocked too (exits = claims only); the
    // deposit-auction mint is blocked while the withdrawal-auction burn
    // remains open.
    // ------------------------------------------------------------------

    function test_PauseBlocksEntryKeepsExits() public {
        vm.startPrank(alice);
        vault.requestDeposit(2000e18);
        vm.warp(block.timestamp + 30);
        vault.deposit(1000e18, alice);
        vm.stopPrank();

        vm.prank(governance);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(VqALCX.EnforcedPause.selector);
        vault.requestDeposit(1e18);

        vm.prank(alice);
        vm.expectRevert(VqALCX.EnforcedPause.selector);
        vault.requestWithdraw(1e18);

        vm.prank(alice);
        vault.deposit(1000e18, alice);
        assertEq(vault.balanceOf(alice), 2000e18, "claims open under pause");

        vm.prank(address(auctioner));
        vm.expectRevert(VqALCX.EnforcedPause.selector);
        vault.mintViaAuction(alice, 1e18);

        vm.prank(alice);
        auctioner.bidWithdraw(1000e18, 1000e18);
        (,,, uint256 endTime,,,,,,) = auctioner.withdrawRounds(auctioner.currentWithdrawRound());
        vm.warp(endTime);
        auctioner.settleWithdrawRound(auctioner.currentWithdrawRound());
        assertEq(alcx.balanceOf(alice), 1_000_000e18 - 2000e18 + 1000e18, "burn auction open under pause");
    }

    // ------------------------------------------------------------------
    // Floor-price withdrawal bids remain replaceable. A
    // strictly lower price always outbids; at equal price a strictly
    // larger amount outbids, so a zero-price dust bid can no longer
    // monopolize a round.
    // ------------------------------------------------------------------

    function test_FloorPriceWithdrawBidIsReplaceable() public {
        _giveAliceVqALCX(4_000e18);
        _giveAliceVqALCX(4_000e18);
        vm.startPrank(alice);
        vault.transfer(bob, 4_000e18);
        vm.stopPrank();
        vm.prank(bob);
        vault.approve(address(auctioner), type(uint256).max);

        // Strictly lower price replaces a positive-price leader (unchanged).
        vm.prank(bob);
        auctioner.bidWithdraw(3_000e18, 1_000e18);
        vm.prank(alice);
        auctioner.bidWithdraw(3_000e18, 999e18);
        (,,,,,,, address bidder,,) = auctioner.withdrawRounds(auctioner.currentWithdrawRound());
        assertEq(bidder, alice, "lower price replaces");

        // Settle to open a fresh round.
        (,,, uint256 endTime,,,,,,) = auctioner.withdrawRounds(auctioner.currentWithdrawRound());
        vm.warp(endTime);
        auctioner.settleWithdrawRound(auctioner.currentWithdrawRound());

        // alice locks the fresh round with a dust bid at the uint floor price.
        vm.prank(alice);
        auctioner.bidWithdraw(1, 0);

        // Equal price + strictly larger amount replaces the floor bid.
        vm.prank(bob);
        auctioner.bidWithdraw(4_000e18, 0);
        (,,,,,,, bidder,,) = auctioner.withdrawRounds(auctioner.currentWithdrawRound());
        assertEq(bidder, bob, "equal price + larger amount replaces floor-price dust bid");

        // Equal price with equal-or-smaller amount still reverts.
        vm.prank(alice);
        vm.expectRevert(VqAuctioner.BidTooLow.selector);
        auctioner.bidWithdraw(4_000e18, 0);
        vm.prank(alice);
        vm.expectRevert(VqAuctioner.BidTooLow.selector);
        auctioner.bidWithdraw(3_000e18, 0);
    }

    // ------------------------------------------------------------------
    // The auctioneer constructor rejects zero addresses
    // and a zero round duration.
    // ------------------------------------------------------------------

    function test_AuctionerConstructorRejectsInvalidParams() public {
        vm.expectRevert(VqAuctioner.InvalidConstructorParams.selector);
        new VqAuctioner(address(0), address(vault), address(0xA11CE), 1 hours);
        vm.expectRevert(VqAuctioner.InvalidConstructorParams.selector);
        new VqAuctioner(address(alcx), address(0), address(0xA11CE), 1 hours);
        vm.expectRevert(VqAuctioner.InvalidConstructorParams.selector);
        new VqAuctioner(address(alcx), address(vault), address(0), 1 hours);
        vm.expectRevert(VqAuctioner.InvalidConstructorParams.selector);
        new VqAuctioner(address(alcx), address(vault), address(0xA11CE), 0);
    }
}
