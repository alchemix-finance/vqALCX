// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VqALCX} from "../../../src/VqALCX.sol";

/// @notice Handler for invariant testing of VqALCX vault
/// @dev Called by the invariant test fuzzer. Each function performs random but valid actions.
contract VqALCXHandler is Test {
    VqALCX public vault;
    ERC20 public alcx;

    address[] public actors;
    address public currentActor;

    uint256 public constant RATE = 100e18;
    uint256 public constant CAPACITY = 10_000e18;
    uint256 public constant INITIAL_MINT = 1_000_000e18;

    constructor(address _vault, address _alcx) {
        vault = VqALCX(_vault);
        alcx = ERC20(_alcx);

        for (uint256 i = 0; i < 5; i++) {
            address actor = address(uint160(0x1000 + i));
            actors.push(actor);
            alcx.approve(address(vault), type(uint256).max);
            vm.startPrank(actor);
            alcx.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }

        // Mint tokens to each actor
        for (uint256 i = 0; i < actors.length; i++) {
            // Use vm.deal for ETH, or directly write storage for ERC20
            deal(address(alcx), actors[i], INITIAL_MINT);
        }
    }

    modifier useActor(uint256 actorSeed) {
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        _;
    }

    function requestDeposit(uint256 actorSeed, uint256 amount) public useActor(actorSeed) {
        amount = bound(amount, 1e18, CAPACITY);
        // Check capacity
        if (vault.depositQueueDepth() + amount > CAPACITY) return;

        vm.startPrank(currentActor);
        try vault.requestDeposit(amount) {} catch {}
        vm.stopPrank();
    }

    function requestWithdraw(uint256 actorSeed, uint256 amount) public useActor(actorSeed) {
        amount = bound(amount, 1e18, vault.balanceOf(currentActor));
        if (amount == 0) return;
        if (vault.withdrawQueueDepth() + amount > CAPACITY) return;

        vm.startPrank(currentActor);
        try vault.requestWithdraw(amount) {} catch {}
        vm.stopPrank();
    }

    function deposit(uint256 actorSeed, uint256 amount) public useActor(actorSeed) {
        amount = bound(amount, 1e18, 1000e18);
        if (alcx.balanceOf(currentActor) < amount) return;

        vm.startPrank(currentActor);
        try vault.deposit(amount, currentActor) {} catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 amount) public useActor(actorSeed) {
        amount = bound(amount, 1e18, vault.balanceOf(currentActor));
        if (amount == 0) return;

        vm.startPrank(currentActor);
        try vault.withdraw(amount, currentActor, currentActor) {} catch {}
        vm.stopPrank();
    }

    function cancelDepositRequest(uint256 actorSeed, uint256 requestId) public useActor(actorSeed) {
        requestId = bound(requestId, 0, 100);
        vm.startPrank(currentActor);
        try vault.cancelDepositRequest(requestId) {} catch {}
        vm.stopPrank();
    }

    function advanceTime(uint256 timeSeed) public {
        uint256 time = bound(timeSeed, 1, 1 hours);
        vm.warp(block.timestamp + time);
        try vault.drip() {} catch {}
    }

    function actorsLength() public view returns (uint256) {
        return actors.length;
    }

    function getActor(uint256 i) public view returns (address) {
        return actors[i];
    }
}
