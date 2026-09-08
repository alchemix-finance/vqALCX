// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VqALCX} from "../../../src/VqALCX.sol";
import {VqStaking} from "../../../src/VqStaking.sol";

contract MockALCX is ERC20 {
    constructor() ERC20("Alchemix", "ALCX") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

contract MockReward is ERC20 {
    constructor() ERC20("Reward", "RWD") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

/// @title Re-audit validation tests for VqStaking
contract StakingReauditTest is Test {
    VqALCX internal vault;
    VqStaking internal staking;
    MockALCX internal alcx;
    MockReward internal reward;

    address internal governance = address(0xCAFE);
    address internal alice = address(0x1111);
    address internal bob = address(0x2222);

    uint256 internal constant RATE = 100e18;
    uint256 internal constant CAPACITY = 100_000_000e18;

    function setUp() public {
        alcx = new MockALCX();
        reward = new MockReward();
        vault = new VqALCX(address(alcx), governance, address(0));
        staking = new VqStaking(address(vault), address(reward));

        vm.prank(governance);
        vault.setDepositBucketParams(RATE, CAPACITY);
        vm.prank(governance);
        vault.setWithdrawBucketParams(RATE, CAPACITY);

        address[2] memory users = [alice, bob];
        for (uint256 i = 0; i < users.length; i++) {
            alcx.transfer(users[i], 1_000_000e18);
            vm.startPrank(users[i]);
            alcx.approve(address(vault), type(uint256).max);
            vault.approve(address(staking), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _stakeAs(address who, uint256 amount) internal {
        vm.startPrank(who);
        vault.requestDeposit(amount);
        vm.warp(block.timestamp + 30);
        vault.deposit(amount, who);
        staking.stake(amount);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // F-INT-1 (LOW, integration): CLOCK_MODE() returns the nonstandard
    // string "mode=blockstamp". ERC-6372 canonical timestamp clocks
    // return "mode=timestamp" (see OZ ERC6372Utils.timestampClockMode).
    // Consumers that validate the mode string will reject the contract.
    // ------------------------------------------------------------------

    function test_FINT1_ClockModeStringNonstandard() public view {
        assertEq(staking.clock(), block.timestamp);
        assertEq(staking.CLOCK_MODE(), "mode=blockstamp");
        assertTrue(
            keccak256(bytes(staking.CLOCK_MODE())) != keccak256(bytes("mode=timestamp")),
            "mode string is not the ERC-6372 canonical timestamp mode"
        );
    }

    // ------------------------------------------------------------------
    // F-STAKE-1 (LOW, design): reward tokens donated while no one has
    // staked are never distributed then, and accrue in full to the
    // first staker once anyone stakes.
    // ------------------------------------------------------------------

    function test_FSTAKE1_PreStakeDonationsGoToFirstStaker() public {
        reward.transfer(address(staking), 1000e18);

        _stakeAs(alice, 1000e18);
        staking.accrueRewards();

        assertEq(staking.earned(alice), 1000e18, "first staker captures pre-stake donation");
    }

    // ------------------------------------------------------------------
    // F-STAKE-2 (INFO): earned() does not include unaccrued funding;
    // it only moves after someone triggers accrueRewards().
    // ------------------------------------------------------------------

    function test_FSTAKE2_EarnedStaleUntilAccrual() public {
        _stakeAs(alice, 1000e18);
        staking.accrueRewards();

        reward.transfer(address(staking), 500e18);
        assertEq(staking.earned(alice), 0, "stale before accrual");

        staking.accrueRewards();
        assertEq(staking.earned(alice), 500e18, "updated after accrual");
    }

    // ------------------------------------------------------------------
    // Voting integration: undelegated stakers hold zero votes (standard
    // OZ Votes semantics, delegates() has no self-default), but
    // balance checkpoints are kept regardless, so getPastBalanceOf
    // works for Aragon-style delegate override.
    // ------------------------------------------------------------------

    function test_UndelegatedStakerHasZeroVotesButBalanceCheckpoints() public {
        _stakeAs(alice, 1000e18);
        assertEq(staking.getVotes(alice), 0, "undelegated stake carries no votes");
        assertEq(staking.stakedBalanceOf(alice), 1000e18);

        vm.warp(block.timestamp + 12);
        uint48 ts = uint48(block.timestamp - 1);

        assertEq(staking.getPastBalanceOf(alice, ts), 1000e18, "balance checkpoint kept");
        assertEq(staking.getPastVotes(alice, ts), 0, "delegate checkpoint empty");

        vm.prank(alice);
        staking.delegate(alice);
        assertEq(staking.getVotes(alice), 1000e18, "self-delegation activates votes");
    }

    // ------------------------------------------------------------------
    // Reward conservation and rounding residue: accrual floors per-share
    // and per-user, so donation dust below the share resolution is
    // stranded in the contract permanently (favors stakers as a body,
    // bounded residue per claim).
    // ------------------------------------------------------------------

    function test_SubResolutionDonationsStranded() public {
        _stakeAs(alice, 1000e18);
        _stakeAs(bob, 1000e18);
        staking.accrueRewards();

        reward.transfer(address(staking), 999);
        staking.accrueRewards();

        assertEq(staking.earned(alice), 0, "donation below share resolution accrues nothing");
        assertEq(staking.earned(bob), 0);
        assertEq(reward.balanceOf(address(staking)), 999, "donation stranded in contract");
    }

    function test_RewardConservationAndDust() public {
        _stakeAs(alice, 1000e18);
        _stakeAs(bob, 1000e18);
        staking.accrueRewards();

        reward.transfer(address(staking), 3001);
        staking.accrueRewards();

        assertEq(staking.earned(alice), 1000);
        assertEq(staking.earned(bob), 1000);

        vm.prank(alice);
        staking.claimRewards();
        vm.prank(bob);
        staking.claimRewards();

        assertEq(reward.balanceOf(alice), 1000);
        assertEq(reward.balanceOf(bob), 1000);
        assertEq(reward.balanceOf(address(staking)), 1001, "rounding residue stuck in contract");
        assertEq(staking.totalStaked(), 2000e18);
    }
}
