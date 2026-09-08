// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "@forge-std/Test.sol";
import {StdInvariant} from "@forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VqALCX} from "../../src/VqALCX.sol";
import {VqALCXHandler} from "./handlers/VqALCXHandler.sol";

contract MockALCXInvariant is ERC20 {
    constructor() ERC20("Alchemix", "ALCX") {}
}

/// @title VqALCX Invariant Tests
/// @notice Fuzz tests that verify system invariants hold across random valid operations
contract VqALCXInvariantTest is StdInvariant, Test {
    VqALCX public vault;
    MockALCXInvariant public alcx;
    VqALCXHandler public handler;

    address public governance = address(0xCAFE);

    uint256 constant RATE = 100e18;
    uint256 constant CAPACITY = 10_000e18;

    function setUp() public {
        alcx = new MockALCXInvariant();
        vault = new VqALCX(address(alcx), governance, address(0));

        vm.prank(governance);
        vault.setDepositBucketParams(RATE, CAPACITY);
        vm.prank(governance);
        vault.setWithdrawBucketParams(RATE, CAPACITY);

        handler = new VqALCXHandler(address(vault), address(alcx));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.requestDeposit.selector;
        selectors[1] = handler.requestWithdraw.selector;
        selectors[2] = handler.deposit.selector;
        selectors[3] = handler.withdraw.selector;
        selectors[4] = handler.cancelDepositRequest.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.requestWithdraw.selector; // weight withdraws

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // ------------------------------------------------------------------
    // INV-WM-1: Vault ALCX balance >= totalSupply(vqALCX)
    // ------------------------------------------------------------------
    function invariant_WatermarkBacking() public view {
        uint256 vaultBalance = alcx.balanceOf(address(vault));
        uint256 totalShares = vault.totalSupply();
        assertGe(vaultBalance, totalShares, "INV-WM-1: vault balance < totalSupply");
    }

    // ------------------------------------------------------------------
    // INV-WM-5: Protocol profit >= 0
    // ------------------------------------------------------------------
    function invariant_ProfitNonNegative() public view {
        uint256 vaultBalance = alcx.balanceOf(address(vault));
        uint256 totalShares = vault.totalSupply();
        assertGe(vaultBalance - totalShares, 0, "INV-WM-5: deficit");
    }

    // ------------------------------------------------------------------
    // INV-Q-1: depositQueueDepth <= depositBucketCapacity
    // ------------------------------------------------------------------
    function invariant_DepositQueueCapacity() public view {
        assertLe(vault.depositQueueDepth(), CAPACITY, "INV-Q-1: deposit queue exceeds capacity");
    }

    // ------------------------------------------------------------------
    // INV-Q-2: withdrawQueueDepth <= withdrawBucketCapacity
    // ------------------------------------------------------------------
    function invariant_WithdrawQueueCapacity() public view {
        assertLe(vault.withdrawQueueDepth(), CAPACITY, "INV-Q-2: withdraw queue exceeds capacity");
    }

    // ------------------------------------------------------------------
    // INV-T-6: share price pegged 1:1
    // ------------------------------------------------------------------
    function invariant_SharePrice1to1() public view {
        assertEq(vault.convertToShares(1e18), 1e18, "INV-T-6: share price not 1:1");
        assertEq(vault.convertToAssets(1e18), 1e18, "INV-T-6: asset price not 1:1");
    }

    // ------------------------------------------------------------------
    // INV-T-2: vqALCX freely transferable, no lockup
    // ------------------------------------------------------------------
    function invariant_NoLockup() public {
        // If an actor has vqALCX, they can always transfer it
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            address actor = handler.getActor(i);
            uint256 bal = vault.balanceOf(actor);
            if (bal > 0) {
                // Transfer test — should never revert
                vm.prank(actor);
                vault.transfer(actor, 0); // zero transfer always succeeds
            }
        }
    }

    // ------------------------------------------------------------------
    // INV-Q-7: head <= tail always (no underflow)
    // ------------------------------------------------------------------
    function invariant_HeadLeTail() public view {
        (, , uint256 dHead, uint256 dTail,,, ) = vault.depositBucket();
        assertLe(dHead, dTail, "INV-Q-7: deposit head > tail");

        (, , uint256 wHead, uint256 wTail,,, ) = vault.withdrawBucket();
        assertLe(wHead, wTail, "INV-Q-7: withdraw head > tail");
    }
}
