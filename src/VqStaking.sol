// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VotesExtended} from "@openzeppelin/contracts/governance/utils/VotesExtended.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VqStaking — DAO adapter for governance participation and reward distribution
/// @notice Users stake vqALCX here to get voting power (VotesExtended) and earn rewards.
/// @notice No receipt token — balances tracked internally (TC-5).
/// @notice Timestamp-based clock (TC-3).
/// @notice Rewards are push-based: anyone transfers reward tokens to this contract,
///         and the balance delta is lazily accrued into rewardPerShare.
contract VqStaking is VotesExtended, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable vqALCX;
    IERC20 public immutable rewardToken;

    mapping(address => uint256) private _stakedBalances;
    uint256 private _totalStaked;

    uint256 public rewardPerShare;
    uint256 public constant SHARES_PRECISION = 1e18;

    mapping(address => uint256) public userRewardPerSharePaid;
    mapping(address => uint256) public accruedRewards;

    uint256 private _lastRewardBalance;

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsAccrued(uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);

    // ------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------

    error InsufficientBalance();
    error ZeroAmount();
    error SameRewardToken();

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------

    constructor(address _vqALCX, address _rewardToken) EIP712("VqStaking", "1") {
        if (_vqALCX == _rewardToken) revert SameRewardToken();
        vqALCX = IERC20(_vqALCX);
        rewardToken = IERC20(_rewardToken);
    }

    // ------------------------------------------------------------------------
    // Timestamp clock (TC-3)
    // ------------------------------------------------------------------------

    function clock() public view virtual override returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public view virtual override returns (string memory) {
        return "mode=blockstamp";
    }

    // ------------------------------------------------------------------------
    // VotesExtended hook — returns internal staked balance
    // ------------------------------------------------------------------------

    function _getVotingUnits(address account) internal view virtual override returns (uint256) {
        return _stakedBalances[account];
    }

    // ------------------------------------------------------------------------
    // Reward accrual — lazy, balance-delta based
    // ------------------------------------------------------------------------

    /// @notice Accrues rewards based on reward token balance delta since last accrual.
    /// @dev Anyone can call this externally to update accounting at their own gas cost.
    function accrueRewards() public {
        uint256 currentBalance = rewardToken.balanceOf(address(this));
        uint256 newRewards = currentBalance - _lastRewardBalance;
        if (newRewards > 0 && _totalStaked > 0) {
            rewardPerShare += (newRewards * SHARES_PRECISION) / _totalStaked;
            _lastRewardBalance = currentBalance;
            emit RewardsAccrued(newRewards);
        }
    }

    function _updateUserRewards(address account) internal {
        accrueRewards();
        uint256 balance = _stakedBalances[account];
        accruedRewards[account] += (balance * (rewardPerShare - userRewardPerSharePaid[account])) / SHARES_PRECISION;
        userRewardPerSharePaid[account] = rewardPerShare;
    }

    // ------------------------------------------------------------------------
    // Staking
    // ------------------------------------------------------------------------

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _updateUserRewards(msg.sender);

        vqALCX.safeTransferFrom(msg.sender, address(this), amount);
        _stakedBalances[msg.sender] += amount;
        _totalStaked += amount;

        _transferVotingUnits(address(0), msg.sender, amount);

        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (_stakedBalances[msg.sender] < amount) revert InsufficientBalance();

        _updateUserRewards(msg.sender);

        _stakedBalances[msg.sender] -= amount;
        _totalStaked -= amount;

        _transferVotingUnits(msg.sender, address(0), amount);

        vqALCX.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    // ------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------

    function stakedBalanceOf(address account) external view returns (uint256) {
        return _stakedBalances[account];
    }

    function totalStaked() external view returns (uint256) {
        return _totalStaked;
    }

    function earned(address account) external view returns (uint256) {
        uint256 balance = _stakedBalances[account];
        return
            accruedRewards[account]
                + ((balance * (rewardPerShare - userRewardPerSharePaid[account])) / SHARES_PRECISION);
    }

    function lastRewardBalance() external view returns (uint256) {
        return _lastRewardBalance;
    }

    function claimRewards() external nonReentrant {
        _updateUserRewards(msg.sender);
        uint256 reward = accruedRewards[msg.sender];
        if (reward == 0) revert ZeroAmount();

        accruedRewards[msg.sender] = 0;

        // Update _lastRewardBalance to reflect tokens leaving
        _lastRewardBalance -= reward;

        rewardToken.safeTransfer(msg.sender, reward);

        emit RewardsClaimed(msg.sender, reward);
    }
}
