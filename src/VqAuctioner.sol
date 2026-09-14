// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IVqALCX {
    function mintViaAuction(address to, uint256 amount) external;
    function burnViaAuction(address winner, uint256 burnAmount, uint256 payoutAmount) external;
    function depositBucketCapacity() external view returns (uint256);
    function depositBucketRate() external view returns (uint256);
    function withdrawBucketCapacity() external view returns (uint256);
    function withdrawBucketRate() external view returns (uint256);
    function drip() external;
    function depositAuctionCapacity() external view returns (uint256);
    function withdrawAuctionCapacity() external view returns (uint256);
    function acceptAuctioneer() external;
    function paused() external view returns (bool);
}

contract VqAuctioner is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Round {
        uint256 startTime;
        uint256 endTime;
        uint256 capacity;
        uint256 totalFilled;
        bool settled;
        address highestBidder;
        uint256 highestBidAmount;
        uint256 highestBidPrice;
    }

    IERC20 public immutable alcx;
    IERC20 public immutable vqALCX;
    IVqALCX public immutable vault;

    address public daoTreasury;
    uint256 public roundDuration;

    uint256 public currentDepositRound;
    uint256 public currentWithdrawRound;

    mapping(uint256 => Round) public depositRounds;
    mapping(uint256 => Round) public withdrawRounds;

    event DepositBidPlaced(uint256 indexed roundId, address indexed bidder, uint256 amount, uint256 price);
    event WithdrawBidPlaced(uint256 indexed roundId, address indexed bidder, uint256 amount, uint256 price);
    event DepositRoundSettled(uint256 indexed roundId, address winner, uint256 amount, uint256 clearingPrice);
    event WithdrawRoundSettled(uint256 indexed roundId, address winner, uint256 amount, uint256 clearingPrice);
    event RefundIssued(address indexed bidder, uint256 amount);
    event RoundStarted(uint256 indexed roundId, bool isDeposit, uint256 capacity);

    error RoundNotActive();
    error RoundAlreadySettled();
    error BidTooLow();
    error InsufficientCapacity();
    error NotRoundWinner();
    error ZeroAmount();
    error InvalidPrice();
    error InvalidConstructorParams();

    constructor(address _alcx, address _vqALCX, address _daoTreasury, uint256 _roundDuration) {
        if (_alcx == address(0) || _vqALCX == address(0) || _daoTreasury == address(0) || _roundDuration == 0) {
            revert InvalidConstructorParams();
        }
        alcx = IERC20(_alcx);
        vqALCX = IERC20(_vqALCX);
        vault = IVqALCX(_vqALCX);
        daoTreasury = _daoTreasury;
        roundDuration = _roundDuration;
    }

    /// @notice Lets this contract accept the vault's auctioneer role after governance proposed it.
    /// @dev Permissionless: only succeeds while the vault's pending auctioneer is this contract.
    function acceptVaultAuctioneer() external {
        vault.acceptAuctioneer();
    }

    function _startDepositRound() internal returns (uint256 roundId) {
        roundId = ++currentDepositRound;
        uint256 rate = vault.depositBucketRate();
        uint256 capacity = rate * roundDuration;

        depositRounds[roundId] = Round({
            startTime: block.timestamp,
            endTime: block.timestamp + roundDuration,
            capacity: capacity,
            totalFilled: 0,
            settled: false,
            highestBidder: address(0),
            highestBidAmount: 0,
            highestBidPrice: 0
        });

        emit RoundStarted(roundId, true, capacity);
    }

    function _startWithdrawRound() internal returns (uint256 roundId) {
        roundId = ++currentWithdrawRound;
        uint256 rate = vault.withdrawBucketRate();
        uint256 capacity = rate * roundDuration;

        withdrawRounds[roundId] = Round({
            startTime: block.timestamp,
            endTime: block.timestamp + roundDuration,
            capacity: capacity,
            totalFilled: 0,
            settled: false,
            highestBidder: address(0),
            highestBidAmount: 0,
            highestBidPrice: 0
        });

        emit RoundStarted(roundId, false, capacity);
    }

    function ensureDepositRound() external returns (uint256) {
        if (currentDepositRound == 0 || depositRounds[currentDepositRound].settled) {
            return _startDepositRound();
        }
        return currentDepositRound;
    }

    function ensureWithdrawRound() external returns (uint256) {
        if (currentWithdrawRound == 0 || withdrawRounds[currentWithdrawRound].settled) {
            return _startWithdrawRound();
        }
        return currentWithdrawRound;
    }

    function bidDeposit(uint256 amount, uint256 maxPrice) external nonReentrant returns (uint256 bidId) {
        if (amount == 0) revert ZeroAmount();
        if (maxPrice < amount) revert InvalidPrice();
        uint256 roundId = this.ensureDepositRound();
        Round storage round = depositRounds[roundId];

        if (block.timestamp > round.endTime) revert RoundNotActive();
        if (round.totalFilled + amount > round.capacity) revert InsufficientCapacity();

        if (round.highestBidder != address(0) && maxPrice <= round.highestBidPrice) {
            revert BidTooLow();
        }

        if (round.highestBidder != address(0)) {
            uint256 refundAmount = round.highestBidPrice;
            alcx.safeTransfer(round.highestBidder, refundAmount);
            emit RefundIssued(round.highestBidder, refundAmount);
        }

        alcx.safeTransferFrom(msg.sender, address(this), maxPrice);

        round.highestBidder = msg.sender;
        round.highestBidAmount = amount;
        round.highestBidPrice = maxPrice;

        emit DepositBidPlaced(roundId, msg.sender, amount, maxPrice);
        return roundId;
    }

    function bidWithdraw(uint256 amount, uint256 minPrice) external nonReentrant returns (uint256 bidId) {
        if (amount == 0) revert ZeroAmount();
        if (minPrice > amount) revert InvalidPrice();
        uint256 roundId = this.ensureWithdrawRound();
        Round storage round = withdrawRounds[roundId];
        if (block.timestamp > round.endTime) revert RoundNotActive();

        if (round.totalFilled + amount > round.capacity) revert InsufficientCapacity();

        // For withdrawals: minPrice is the minimum ALCX the bidder wants to receive
        // A lower minPrice = more competitive (willing to accept less).
        // A strictly lower price always outbids; at equal price, a strictly larger
        // amount outbids. Without the equal-price escape hatch, a floor-price bid
        // (e.g. minPrice = 0) could never be replaced and a dust bid would
        // monopolize the round.
        if (round.highestBidder != address(0)) {
            if (minPrice > round.highestBidPrice) {
                revert BidTooLow();
            }
            if (minPrice == round.highestBidPrice && amount <= round.highestBidAmount) {
                revert BidTooLow();
            }
        }

        if (round.highestBidder != address(0)) {
            uint256 refundAmount = round.highestBidAmount;
            vqALCX.safeTransfer(round.highestBidder, refundAmount);
            emit RefundIssued(round.highestBidder, refundAmount);
        }

        vqALCX.safeTransferFrom(msg.sender, address(this), amount);

        round.highestBidder = msg.sender;
        round.highestBidAmount = amount;
        round.highestBidPrice = minPrice;

        emit WithdrawBidPlaced(roundId, msg.sender, amount, minPrice);
        return roundId;
    }

    function settleDepositRound(uint256 roundId) external nonReentrant {
        if (roundId == 0 || roundId != currentDepositRound) revert RoundNotActive();
        Round storage round = depositRounds[roundId];
        if (round.settled) revert RoundAlreadySettled();
        if (block.timestamp < round.endTime) revert RoundNotActive();
        if (round.highestBidder == address(0)) {
            round.settled = true;
            _startDepositRound();
            return;
        }

        round.settled = true;
        address winner = round.highestBidder;
        uint256 bidAmount = round.highestBidAmount;
        uint256 clearingPrice = round.highestBidPrice;

        vault.drip();
        uint256 fill = bidAmount;
        uint256 available = vault.depositAuctionCapacity();
        if (fill > available) fill = available;

        if (fill > 0 && vault.paused()) {
            // Pause gates minting in the vault; the winner's locked bid must not be
            // stranded. Settle the round empty and make the winner whole (principal,
            // no fill -> no premium). Competition resumes after unpause.
            alcx.safeTransfer(winner, clearingPrice);
            emit DepositRoundSettled(roundId, winner, 0, clearingPrice);
            _startDepositRound();
            return;
        }

        uint256 charged = (clearingPrice * fill) / bidAmount;
        uint256 premium = charged > fill ? charged - fill : 0;
        uint256 refund = clearingPrice - charged;

        if (fill > 0) {
            alcx.safeTransfer(address(vault), fill);
            vault.mintViaAuction(winner, fill);
        }
        if (premium > 0) {
            alcx.safeTransfer(daoTreasury, premium);
        }
        if (refund > 0) {
            alcx.safeTransfer(winner, refund);
        }

        round.totalFilled = fill;

        emit DepositRoundSettled(roundId, winner, fill, clearingPrice);

        _startDepositRound();
    }

    function settleWithdrawRound(uint256 roundId) external nonReentrant {
        if (roundId == 0 || roundId != currentWithdrawRound) revert RoundNotActive();
        Round storage round = withdrawRounds[roundId];
        if (round.settled) revert RoundAlreadySettled();
        if (block.timestamp < round.endTime) revert RoundNotActive();
        if (round.highestBidder == address(0)) {
            round.settled = true;
            _startWithdrawRound();
            return;
        }

        round.settled = true;
        address winner = round.highestBidder;
        uint256 bidAmount = round.highestBidAmount;
        uint256 clearingPrice = round.highestBidPrice;

        vault.drip();
        uint256 fill = bidAmount;
        uint256 available = vault.withdrawAuctionCapacity();
        if (fill > available) fill = available;

        uint256 payout = (clearingPrice * fill) / bidAmount;
        uint256 refundAmount = bidAmount - fill;

        if (fill > 0) {
            vault.burnViaAuction(winner, fill, payout);
        }
        if (refundAmount > 0) {
            vqALCX.safeTransfer(winner, refundAmount);
        }

        round.totalFilled = fill;

        emit WithdrawRoundSettled(roundId, winner, fill, clearingPrice);

        _startWithdrawRound();
    }

    function getDepositRound(uint256 roundId) external view returns (Round memory) {
        return depositRounds[roundId];
    }

    function getWithdrawRound(uint256 roundId) external view returns (Round memory) {
        return withdrawRounds[roundId];
    }
}
