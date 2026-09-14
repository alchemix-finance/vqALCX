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

    /// @notice Newly staked balances earn no rewards for this long (anti-sniping):
    /// a warm-up batch only joins the earning pool at the first reward update after
    /// its maturity, applied after that update's distribution, so just-in-time
    /// stakes can never capture distributions that arrive during the warm-up.
    /// ponytail: single merged batch per account (a top-up re-arms the pending
    /// batch's maturity); per-deposit maturities if top-up patterns ever matter.
    uint256 public constant REWARD_WARMUP = 1 days;

    mapping(address => uint256) private _stakedBalances;
    mapping(address => uint256) private _warmingBalances;
    mapping(address => uint256) private _warmingUntil;
    uint256 private _totalStaked;
    uint256 private _totalWarming;

    uint256 public rewardPerShare;
    uint256 public constant SHARES_PRECISION = 1e18;

    mapping(address => uint256) public userRewardPerSharePaid;
    mapping(address => uint256) public accruedRewards;

    uint256 private _lastRewardBalance;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsAccrued(uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);

    error InsufficientBalance();
    error ZeroAmount();
    error SameRewardToken();

    constructor(address _vqALCX, address _rewardToken) EIP712("VqStaking", "1") {
        if (_vqALCX == _rewardToken) revert SameRewardToken();
        vqALCX = IERC20(_vqALCX);
        rewardToken = IERC20(_rewardToken);
    }

    // Timestamp clock (TC-3)

    function clock() public view virtual override returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public view virtual override returns (string memory) {
        // ERC-6372 canonical descriptor for a block.timestamp clock
        return "mode=timestamp";
    }

    // TC-5: voting units are the internal staked balance (warming included)
    function _getVotingUnits(address account) internal view virtual override returns (uint256) {
        return _stakedBalances[account] + _warmingBalances[account];
    }

    function _seasonWarming(address account) internal {
        uint256 warming = _warmingBalances[account];
        if (warming != 0 && block.timestamp >= _warmingUntil[account]) {
            _warmingBalances[account] = 0;
            _stakedBalances[account] += warming;
            _totalWarming -= warming;
            _totalStaked += warming;
        }
    }

    /// @notice Accrues rewards based on reward token balance delta since last accrual.
    /// @dev Anyone can call this externally to update accounting at their own gas cost.
    ///      Distribution base is seasoned (post-warm-up) stake only; seasoning happens
    ///      in _updateUserRewards after the caller's snapshot, so a maturing batch
    ///      earns from that point onward and never retroactively.
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
        _seasonWarming(account);
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _updateUserRewards(msg.sender);

        vqALCX.safeTransferFrom(msg.sender, address(this), amount);
        _warmingBalances[msg.sender] += amount;
        _totalWarming += amount;
        _warmingUntil[msg.sender] = block.timestamp + REWARD_WARMUP;

        _transferVotingUnits(address(0), msg.sender, amount);

        // Staked-but-undelegated accounts hold zero votes in OZ Votes. Default to
        // self-delegation on first stake so voting power is live without a separate
        // delegate() call; explicit prior delegations are preserved.
        if (delegates(msg.sender) == address(0)) {
            _delegate(msg.sender, msg.sender);
        }

        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (_stakedBalances[msg.sender] + _warmingBalances[msg.sender] < amount) revert InsufficientBalance();

        _updateUserRewards(msg.sender);

        // Deduct from the seasoned balance first so the (immature) warm-up batch
        // keeps its place in line; unstake itself stays instant — no lockup.
        uint256 fromSeasoned = amount > _stakedBalances[msg.sender] ? _stakedBalances[msg.sender] : amount;
        _stakedBalances[msg.sender] -= fromSeasoned;
        _totalStaked -= fromSeasoned;
        uint256 fromWarming = amount - fromSeasoned;
        if (fromWarming > 0) {
            _warmingBalances[msg.sender] -= fromWarming;
            _totalWarming -= fromWarming;
        }

        _transferVotingUnits(msg.sender, address(0), amount);

        vqALCX.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    function stakedBalanceOf(address account) external view returns (uint256) {
        return _stakedBalances[account] + _warmingBalances[account];
    }

    function totalStaked() external view returns (uint256) {
        return _totalStaked + _totalWarming;
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
        // Zero-reward claim is a no-op (it still seasons a matured warm-up batch).
        if (reward == 0) return;

        accruedRewards[msg.sender] = 0;

        // Update _lastRewardBalance to reflect tokens leaving
        _lastRewardBalance -= reward;

        rewardToken.safeTransfer(msg.sender, reward);

        emit RewardsClaimed(msg.sender, reward);
    }
}
