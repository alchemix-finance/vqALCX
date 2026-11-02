// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
    using SafeERC20 for IERC20Metadata;

    IERC20Metadata public immutable vqALCX;
    IERC20 public immutable rewardToken;

    uint256 public constant REWARD_WARMUP = 1 days;
    uint256 public constant MAX_SWEEP_DAYS = 100;

    mapping(address => uint256) private _stakedBalances;
    mapping(address => uint256) private _warmingBalances;
    mapping(address => uint256) private _warmingDay;
    uint256 private _totalStaked;
    uint256 private _totalWarming;
    mapping(uint256 => uint256) private _maturing;
    mapping(uint256 => uint256) private _rpsAtDayStart;

    uint256 public rewardPerShare;
    uint256 public constant SHARES_PRECISION = 1e18;

    mapping(address => uint256) public userRewardPerSharePaid;
    mapping(address => uint256) public accruedRewards;

    uint256 private _lastRewardBalance;
    uint256 private _lastSweptDay;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsAccrued(uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);

    error InsufficientBalance();
    error ZeroAmount();
    error SameRewardToken();

    constructor(address _vqALCX, address _rewardToken) EIP712("VqStaking", "1") {
        if (_vqALCX == _rewardToken) revert SameRewardToken();
        vqALCX = IERC20Metadata(_vqALCX);
        rewardToken = IERC20(_rewardToken);
        _lastSweptDay = block.timestamp / 1 days;
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

    function _dayStartRPS(uint256 day) private view returns (uint256) {
        uint256 checkpoint = _rpsAtDayStart[day];
        return checkpoint == 0 ? rewardPerShare : checkpoint - 1;
    }

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

        uint256 today = block.timestamp / 1 days;
        uint256 last = _lastSweptDay;
        for (uint256 i = 0; i < MAX_SWEEP_DAYS && last < today; ++i) {
            ++last;
            uint256 amount = _maturing[last];
            if (amount != 0) {
                _totalStaked += amount;
                _totalWarming -= amount;
                delete _maturing[last];
            }
            _rpsAtDayStart[last] = rewardPerShare + 1;
        }
        _lastSweptDay = last;
    }

    function _updateUserRewards(address account) internal {
        accrueRewards();
        uint256 balance = _stakedBalances[account];
        accruedRewards[account] += (balance * (rewardPerShare - userRewardPerSharePaid[account])) / SHARES_PRECISION;
        uint256 warming = _warmingBalances[account];
        if (warming != 0 && _warmingDay[account] <= _lastSweptDay) {
            accruedRewards[account] += (warming * (rewardPerShare - _dayStartRPS(_warmingDay[account])))
                / SHARES_PRECISION;
            _warmingBalances[account] = 0;
            _stakedBalances[account] = balance + warming;
        }
        userRewardPerSharePaid[account] = rewardPerShare;
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _updateUserRewards(msg.sender);

        vqALCX.safeTransferFrom(msg.sender, address(this), amount);

        uint256 existing = _warmingBalances[msg.sender];
        if (existing != 0) {
            _maturing[_warmingDay[msg.sender]] -= existing;
            _totalWarming -= existing;
        }

        uint256 maturity = block.timestamp + REWARD_WARMUP;
        uint256 day = maturity / 1 days;
        if (maturity % 1 days != 0) ++day;

        uint256 total = existing + amount;
        _warmingBalances[msg.sender] = total;
        _warmingDay[msg.sender] = day;
        _maturing[day] += total;
        _totalWarming += total;

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
            _maturing[_warmingDay[msg.sender]] -= fromWarming;
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

    function balanceOf(address account) external view returns (uint256) {
        return _getVotingUnits(account);
    }

    function getTotalSupply() external view returns (uint256) {
        return _getTotalSupply();
    }

    function name() external view returns (string memory) {
        return vqALCX.name();
    }

    function symbol() external view returns (string memory) {
        return vqALCX.symbol();
    }

    function decimals() external view returns (uint8) {
        return vqALCX.decimals();
    }

    function earned(address account) external view returns (uint256) {
        uint256 total = accruedRewards[account]
            + ((_stakedBalances[account] * (rewardPerShare - userRewardPerSharePaid[account])) / SHARES_PRECISION);
        uint256 warming = _warmingBalances[account];
        if (warming != 0 && _warmingDay[account] <= block.timestamp / 1 days) {
            total += (warming * (rewardPerShare - _dayStartRPS(_warmingDay[account]))) / SHARES_PRECISION;
        }
        return total;
    }

    function lastRewardBalance() external view returns (uint256) {
        return _lastRewardBalance;
    }

    function claimRewards() external nonReentrant {
        _updateUserRewards(msg.sender);
        uint256 reward = accruedRewards[msg.sender];
        // Zero-reward claim is a no-op.
        if (reward == 0) return;

        accruedRewards[msg.sender] = 0;

        // Update _lastRewardBalance to reflect tokens leaving
        _lastRewardBalance -= reward;

        rewardToken.safeTransfer(msg.sender, reward);

        emit RewardsClaimed(msg.sender, reward);
    }
}
