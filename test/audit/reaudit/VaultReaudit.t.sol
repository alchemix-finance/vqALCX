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
/// @notice Each test validates one suspected finding from the 2026-09-08 re-audit.
contract VaultReauditTest is Test {
    VqALCX internal vault;
    VqAuctioner internal auctioner;
    MockALCX internal alcx;

    address internal governance = address(0xCAFE);
    address internal alice = address(0x1111);

    uint256 internal constant RATE = 100e18;
    uint256 internal constant CAPACITY = 100_000_000e18;

    function setUp() public {
        alcx = new MockALCX();
        vault = new VqALCX(address(alcx), governance, address(0));
        auctioner = new VqAuctioner(address(alcx), address(vault), address(0xA11CE), 1 hours);

        vm.prank(governance);
        vault.proposeAuctioneer(address(auctioner));
        vm.prank(address(auctioner));
        vault.acceptAuctioneer();

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
    // F-1 (HIGH): drip gas scales linearly with the number of pending
    // requests. Dust-request spam pushes drip past the block gas limit,
    // permanently reverting every drip-calling entry point (requests,
    // claims, drip, and both setBucketParams functions).
    // ------------------------------------------------------------------

    function _spamDepositRequests(address who, uint256 n) internal {
        vm.startPrank(who);
        for (uint256 i = 0; i < n; i++) {
            vault.requestDeposit(1);
        }
        vm.stopPrank();
    }

    function test_F1_DripGasScaling_1000() public {
        _spamDepositRequests(alice, 1000);
        vm.warp(block.timestamp + 100);
        uint256 g0 = gasleft();
        vault.drip();
        uint256 used = g0 - gasleft();
        emit log_named_uint("drip gas, 1000 dust requests", used);
        assertGt(used, 1_000_000);
    }

    function test_F1_DripGasScaling_4000() public {
        _spamDepositRequests(alice, 4000);
        vm.warp(block.timestamp + 100);
        uint256 g0 = gasleft();
        vault.drip();
        uint256 used = g0 - gasleft();
        emit log_named_uint("drip gas, 4000 dust requests", used);
        // ~linear scaling vs the 1000-request measurement; already above
        // any realistic block-gas headroom, so the vault is bricked.
        assertGt(used, 20_000_000);
    }

    // ------------------------------------------------------------------
    // F-3 (MEDIUM, integrator impact): maxDeposit sums claimable across
    // all of a user's requests, but deposit()/mint() can only claim from
    // a single request. deposit() reverts at maxDeposit.
    // ------------------------------------------------------------------

    function test_F3_MaxDepositOverreports() public {
        vm.startPrank(alice);
        vault.requestDeposit(60e18);
        vault.requestDeposit(40e18);
        vm.warp(block.timestamp + 10);
        vm.stopPrank();

        // Views do not project elapsed drip: maxDeposit reports zero even
        // though 1000e18 of fulfillment has elapsed since the requests.
        vm.prank(alice);
        assertEq(vault.maxDeposit(alice), 0, "view does not project elapsed drip");

        vault.drip();

        // The receiver argument is ignored: read from an uninvolved caller,
        // maxDeposit(alice) reports the caller's claimable (zero).
        assertEq(vault.maxDeposit(alice), 0, "receiver parameter is ignored");

        // Read as alice: maxDeposit sums claimable across ALL requests,
        // but deposit() can only claim from a single request.
        vm.prank(alice);
        uint256 max = vault.maxDeposit(alice);
        assertEq(max, 100e18);
        vm.prank(alice);
        vm.expectRevert(VqALCX.RequestNotFulfillable.selector);
        vault.deposit(100e18, alice);
    }

    // ------------------------------------------------------------------
    // F-4 (MEDIUM, spec non-conformance): previews are pure 1:1
    // identities and do not reflect queue state, contradicting arch.md
    // sections 4.1 and 8.1. ERC-4626 integrators will expect success
    // where deposit() reverts.
    // ------------------------------------------------------------------

    function test_F4_PreviewDoesNotReflectQueue() public {
        assertEq(vault.previewDeposit(50e18), 50e18);
        assertEq(vault.previewWithdraw(50e18), 50e18);
        vm.prank(alice);
        vm.expectRevert(VqALCX.RequestNotFulfillable.selector);
        vault.deposit(50e18, alice);
    }

    // ------------------------------------------------------------------
    // F-2 (MEDIUM): replacing the auctioneer while bids are locked
    // permanently strands the escrow: the old auctioner can no longer
    // settle (vault reverts NotAuctioneer) and VqAuctioner exposes no
    // entry point that could re-accept authorization.
    // ------------------------------------------------------------------

    function test_F2_AuctioneerReplacementStrandsDepositEscrow() public {
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
        assertEq(alcx.balanceOf(address(auctioner)), 2100e18, "escrow stranded");
    }

    function test_F2_AuctioneerReplacementStrandsWithdrawEscrow() public {
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
        assertEq(vault.balanceOf(address(auctioner)), 2000e18, "share escrow stranded");
    }

    // ------------------------------------------------------------------
    // F-8 (LOW, economic): auction credit accumulates without cap or
    // expiry and survives a governance rate reduction, so a large
    // stockpile can fund a single oversized instant mint later.
    // ------------------------------------------------------------------

    function test_F8_AuctionCreditSurvivesRateCut() public {
        vm.warp(block.timestamp + 100);
        vm.prank(governance);
        vault.drip();
        assertGe(vault.depositAuctionCapacity(), 10_000e18);

        vm.prank(governance);
        vault.setDepositBucketParams(1e18, CAPACITY);
        vm.warp(block.timestamp + 10);
        vm.prank(governance);
        vault.drip();
        assertGe(vault.depositAuctionCapacity(), 10_000e18, "credit survives rate cut");
    }

    // ------------------------------------------------------------------
    // Regression confirmation: after a partial fill plus cancellation,
    // the filled portion stays claimable and the refund is exact.
    // ------------------------------------------------------------------

    function test_PartialFillClaimableAfterCancel() public {
        uint256 bal0 = alcx.balanceOf(alice);
        vm.startPrank(alice);
        vault.requestDeposit(1000e18);
        vm.warp(block.timestamp + 1);
        vm.stopPrank();

        // cancelDepositRequest does not drip first: the fulfillment that
        // elapsed since the request is not persisted before computing the
        // refund. Persist it explicitly, then cancel the remainder.
        vault.drip();
        vm.prank(alice);
        vault.cancelDepositRequest(0); // refunds 900e18 minus 1% penalty
        vm.prank(alice);
        vault.deposit(100e18, alice);

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
}
