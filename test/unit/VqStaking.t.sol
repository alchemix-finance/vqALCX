// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VqALCX} from "../../src/VqALCX.sol";
import {VqStaking} from "../../src/VqStaking.sol";

contract MockALCX is ERC20 {
    constructor() ERC20("Alchemix", "ALCX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VqStakingTest is Test {
    VqALCX public vault;
    VqStaking public staking;
    MockALCX public alcx;
    MockRewardToken public rewardToken;

    address public governance = address(0xCAFE);
    address public alice = address(0x1111);
    address public bob = address(0x2222);
    address public delegate1 = address(0x3333);

    uint256 constant RATE = 1000e18;
    uint256 constant CAPACITY = 1_000_000e18;

    function setUp() public {
        alcx = new MockALCX();
        rewardToken = new MockRewardToken();
        vault = new VqALCX(address(alcx), governance, address(0));
        staking = new VqStaking(address(vault), address(rewardToken));

        vm.prank(governance);
        vault.setDepositBucketParams(RATE, CAPACITY);
        vm.prank(governance);
        vault.setWithdrawBucketParams(RATE, CAPACITY);

        alcx.mint(alice, 1_000_000e18);
        alcx.mint(bob, 1_000_000e18);

        vm.startPrank(alice);
        alcx.approve(address(vault), type(uint256).max);
        vault.approve(address(staking), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        alcx.approve(address(vault), type(uint256).max);
        vault.approve(address(staking), type(uint256).max);
        vm.stopPrank();

        rewardToken.mint(address(this), 1_000_000e18);
    }

    function _depositVqALCX(address user, uint256 amount) internal {
        vm.startPrank(user);
        vault.requestDeposit(amount);
        vm.warp(block.timestamp + (amount / RATE) + 1);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    function test_Construction() public view {
        assertEq(address(staking.vqALCX()), address(vault));
        assertEq(address(staking.rewardToken()), address(rewardToken));
        assertEq(staking.clock(), block.timestamp);
        assertEq(staking.CLOCK_MODE(), "mode=blockstamp");
    }

    // ------------------------------------------------------------------
    // Staking
    // ------------------------------------------------------------------

    function test_Stake() public {
        _depositVqALCX(alice, 1000e18);

        vm.prank(alice);
        staking.stake(1000e18);

        assertEq(staking.stakedBalanceOf(alice), 1000e18);
        assertEq(staking.totalStaked(), 1000e18);
        assertEq(vault.balanceOf(address(staking)), 1000e18);
    }

    function test_Unstake() public {
        _depositVqALCX(alice, 1000e18);

        vm.startPrank(alice);
        staking.stake(1000e18);
        staking.unstake(500e18);
        vm.stopPrank();

        assertEq(staking.stakedBalanceOf(alice), 500e18);
        assertEq(vault.balanceOf(alice), 500e18);
    }

    function test_UnstakeInsufficientBalance() public {
        _depositVqALCX(alice, 1000e18);

        vm.startPrank(alice);
        staking.stake(500e18);
        vm.expectRevert(VqStaking.InsufficientBalance.selector);
        staking.unstake(501e18);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Voting power (VotesExtended)
    // ------------------------------------------------------------------

    function test_GetVotesBeforeDelegate() public {
        _depositVqALCX(alice, 1000e18);

        vm.prank(alice);
        staking.stake(1000e18);

        assertEq(staking.getVotes(alice), 0);
    }

    function test_DelegateSelf() public {
        _depositVqALCX(alice, 1000e18);

        vm.startPrank(alice);
        staking.stake(1000e18);
        staking.delegate(alice);
        vm.stopPrank();

        assertEq(staking.getVotes(alice), 1000e18);
    }

    function test_DelegateToOther() public {
        _depositVqALCX(alice, 1000e18);

        vm.startPrank(alice);
        staking.stake(1000e18);
        staking.delegate(delegate1);
        vm.stopPrank();

        assertEq(staking.getVotes(delegate1), 1000e18);
        assertEq(staking.getVotes(alice), 0);
    }

    function test_GetPastVotes() public {
        _depositVqALCX(alice, 1000e18);

        vm.startPrank(alice);
        staking.stake(1000e18);
        staking.delegate(alice);
        vm.stopPrank();

        uint256 snapshotTime = block.timestamp;
        vm.warp(block.timestamp + 100);

        assertEq(staking.getPastVotes(alice, snapshotTime), 1000e18);
    }

    function test_GetPastBalanceOf() public {
        _depositVqALCX(alice, 1000e18);

        vm.startPrank(alice);
        staking.stake(1000e18);
        vm.stopPrank();

        uint256 snapshotTime = block.timestamp;
        vm.warp(block.timestamp + 100);

        assertEq(staking.getPastBalanceOf(alice, snapshotTime), 1000e18);
    }

    function test_GetPastDelegate() public {
        _depositVqALCX(alice, 1000e18);

        vm.startPrank(alice);
        staking.stake(1000e18);
        staking.delegate(delegate1);
        vm.stopPrank();

        uint256 snapshotTime = block.timestamp;
        vm.warp(block.timestamp + 100);

        assertEq(staking.getPastDelegate(alice, snapshotTime), delegate1);
    }

    // ------------------------------------------------------------------
    // Checkpoint on stake/unstake
    // ------------------------------------------------------------------

    function test_CheckpointOnStake() public {
        _depositVqALCX(alice, 1000e18);

        vm.prank(alice);
        staking.stake(1000e18);

        uint256 snapshotTime = block.timestamp;
        vm.warp(block.timestamp + 50);

        _depositVqALCX(alice, 500e18);
        vm.prank(alice);
        staking.stake(500e18);

        assertEq(staking.getPastBalanceOf(alice, snapshotTime), 1000e18);
        assertEq(staking.stakedBalanceOf(alice), 1500e18);
    }

    function test_CheckpointOnUnstake() public {
        _depositVqALCX(alice, 1000e18);

        vm.startPrank(alice);
        staking.stake(1000e18);
        vm.stopPrank();

        uint256 snapshotTime = block.timestamp;
        vm.warp(block.timestamp + 50);

        vm.prank(alice);
        staking.unstake(400e18);

        assertEq(staking.getPastBalanceOf(alice, snapshotTime), 1000e18);
        assertEq(staking.stakedBalanceOf(alice), 600e18);
    }

    // ------------------------------------------------------------------
    // Rewards — push-based, lazy accrual
    // ------------------------------------------------------------------

    function test_PushRewardsDetectedOnNextInteraction() public {
        _depositVqALCX(alice, 1000e18);
        _depositVqALCX(bob, 1000e18);

        vm.prank(alice);
        staking.stake(1000e18);

        vm.prank(bob);
        staking.stake(1000e18);

        // Push reward tokens via plain transfer — no function call needed
        rewardToken.transfer(address(staking), 100e18);

        // Alice should earn ~50
        vm.prank(alice);
        staking.claimRewards();
        assertApproxEqAbs(rewardToken.balanceOf(alice), 50e18, 1);

        // Bob should earn ~50
        vm.prank(bob);
        staking.claimRewards();
        assertApproxEqAbs(rewardToken.balanceOf(bob), 50e18, 1);
    }

    function test_AccrueRewardsCallableByAnyone() public {
        _depositVqALCX(alice, 1000e18);

        vm.prank(alice);
        staking.stake(1000e18);

        // Push rewards
        rewardToken.transfer(address(staking), 100e18);

        // Anyone can accrue — updates global rewardPerShare
        address randomCaller = address(0x9999);
        vm.prank(randomCaller);
        staking.accrueRewards();

        // rewardPerShare should be updated
        assertGt(staking.rewardPerShare(), 0);

        // Alice can claim the full amount
        vm.prank(alice);
        staking.claimRewards();
        assertApproxEqAbs(rewardToken.balanceOf(alice), 100e18, 1);
    }

    function test_RewardsAccrueBeforeStake() public {
        // Push rewards when nobody is staked — should be ignored (no shares)
        rewardToken.transfer(address(staking), 100e18);

        _depositVqALCX(alice, 1000e18);

        vm.prank(alice);
        staking.stake(1000e18);

        // Alice should NOT get the pre-stake rewards
        assertEq(staking.earned(alice), 0);

        // New rewards should accrue to Alice
        rewardToken.transfer(address(staking), 50e18);

        vm.prank(alice);
        staking.claimRewards();
        assertApproxEqAbs(rewardToken.balanceOf(alice), 50e18, 1);
    }

    function test_RewardsProportionalToStake() public {
        _depositVqALCX(alice, 3000e18);
        _depositVqALCX(bob, 1000e18);

        vm.prank(alice);
        staking.stake(3000e18);

        vm.prank(bob);
        staking.stake(1000e18);

        // Push 400 reward tokens — Alice should get 75%, Bob 25%
        rewardToken.transfer(address(staking), 400e18);

        vm.prank(alice);
        staking.claimRewards();
        assertApproxEqAbs(rewardToken.balanceOf(alice), 300e18, 1);

        vm.prank(bob);
        staking.claimRewards();
        assertApproxEqAbs(rewardToken.balanceOf(bob), 100e18, 1);
    }

    // ------------------------------------------------------------------
    // Non-rebalancing invariant check
    // ------------------------------------------------------------------

    function test_VqALCXBalanceDoesNotChangeOnStake() public {
        _depositVqALCX(alice, 1000e18);

        uint256 balanceBefore = vault.balanceOf(alice);

        vm.prank(alice);
        staking.stake(500e18);

        assertEq(vault.balanceOf(alice), balanceBefore - 500e18);
    }

    // ------------------------------------------------------------------
    // INV-T-9: sum of staked balances = vqALCX held by staking contract
    // ------------------------------------------------------------------

    function test_StakingAccountingInvariant() public {
        _depositVqALCX(alice, 1000e18);
        _depositVqALCX(bob, 2000e18);

        vm.prank(alice);
        staking.stake(800e18);

        vm.prank(bob);
        staking.stake(1500e18);

        vm.prank(alice);
        staking.unstake(300e18);

        uint256 totalStaked = staking.totalStaked();
        uint256 heldByStaking = vault.balanceOf(address(staking));
        assertEq(totalStaked, heldByStaking, "INV-T-9: staked sum != held vqALCX");

        assertEq(staking.stakedBalanceOf(alice), 500e18);
        assertEq(staking.stakedBalanceOf(bob), 1500e18);
        assertEq(totalStaked, 2000e18);
    }

    // ------------------------------------------------------------------
    // Delegate checkpoint consistency
    // ------------------------------------------------------------------

    function test_DelegateCheckpointConsistency() public {
        _depositVqALCX(alice, 1000e18);
        _depositVqALCX(bob, 500e18);

        vm.startPrank(alice);
        staking.stake(1000e18);
        staking.delegate(alice);
        vm.stopPrank();

        vm.startPrank(bob);
        staking.stake(500e18);
        staking.delegate(bob);
        vm.stopPrank();

        assertEq(staking.getVotes(alice), 1000e18);
        assertEq(staking.getVotes(bob), 500e18);

        uint256 snap = block.timestamp;
        vm.warp(block.timestamp + 50);

        assertEq(staking.getPastBalanceOf(alice, snap), 1000e18);
        assertEq(staking.getPastVotes(alice, snap), 1000e18);
    }
}
