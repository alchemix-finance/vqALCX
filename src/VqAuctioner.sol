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
}

contract VqAuctioner is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Round {
        uint256 roundId;
        bool isDeposit;
        uint256 startTime;
        uint256 endTime;
        uint256 capacity;
        uint256 totalFilled;
        bool settled;
        address highestBidder;
        uint256 highestBidAmount;
        uint256 highestBidPrice;
    }

    struct LockedBid {
        address bidder;
        uint256 amount;
        uint256 price;
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

    mapping(uint256 => mapping(address => LockedBid)) public depositLockedBids;
    mapping(uint256 => mapping(address => LockedBid)) public withdrawLockedBids;

    mapping(uint256 => uint256) public depositLockedTotal;
    mapping(uint256 => uint256) public withdrawLockedTotal;

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

    constructor(address _alcx, address _vqALCX, address _daoTreasury, uint256 _roundDuration) {
        alcx = IERC20(_alcx);
        vqALCX = IERC20(_vqALCX);
        vault = IVqALCX(_vqALCX);
        daoTreasury = _daoTreasury;
        roundDuration = _roundDuration;
    }

    function _startDepositRound() internal returns (uint256 roundId) {
        roundId = ++currentDepositRound;
        uint256 rate = vault.depositBucketRate();
        uint256 capacity = rate * roundDuration;

        depositRounds[roundId] = Round({
            roundId: roundId,
            isDeposit: true,
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
            roundId: roundId,
            isDeposit: false,
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
        uint256 roundId = this.ensureDepositRound();
        Round storage round = depositRounds[roundId];
        
        if (block.timestamp > round.endTime) revert RoundNotActive();
        if (round.totalFilled + amount > round.capacity) revert InsufficientCapacity();

        // english style
        if (round.highestBidder != address(0) && maxPrice <= round.highestBidPrice) {
            revert BidTooLow();
        }

        // refund prev bidder
        if (round.highestBidder != address(0)) {
            address prevBidder = round.highestBidder;
            LockedBid storage prevBid = depositLockedBids[roundId][prevBidder];
            uint256 refundAmount = prevBid.price;
            prevBid.price = 0;
            depositLockedTotal[roundId] -= refundAmount;
            alcx.safeTransfer(prevBidder, refundAmount);
            emit RefundIssued(prevBidder, refundAmount);
        }

        // lock new highest bid
        alcx.safeTransferFrom(msg.sender, address(this), maxPrice);
        depositLockedBids[roundId][msg.sender] =
            LockedBid({bidder: msg.sender, amount: amount, price: maxPrice});
        depositLockedTotal[roundId] += maxPrice;

        round.highestBidder = msg.sender;
        round.highestBidAmount = amount;
        round.highestBidPrice = maxPrice;

        emit DepositBidPlaced(roundId, msg.sender, amount, maxPrice);
        return roundId;
    }

    function bidWithdraw(uint256 amount, uint256 minPrice) external nonReentrant returns (uint256 bidId) {
        if (amount == 0) revert ZeroAmount();
        uint256 roundId = this.ensureWithdrawRound();
        Round storage round = withdrawRounds[roundId];
        if (block.timestamp > round.endTime) revert RoundNotActive();

        if (round.totalFilled + amount > round.capacity) revert InsufficientCapacity();

        // For withdrawals: minPrice is the minimum ALCX the bidder wants to receive
        // A lower minPrice = more competitive (willing to accept less)
        if (round.highestBidder != address(0) && minPrice >= round.highestBidPrice) {
            revert BidTooLow();
        }

        // refund prev high bidder
        if (round.highestBidder != address(0)) {
            address prevBidder = round.highestBidder;
            LockedBid storage prevBid = withdrawLockedBids[roundId][prevBidder];
            uint256 refundAmount = prevBid.amount;
            prevBid.amount = 0;
            withdrawLockedTotal[roundId] -= refundAmount;
            vqALCX.safeTransfer(prevBidder, refundAmount);
            emit RefundIssued(prevBidder, refundAmount);
        }

        // lock new lowest bid
        vqALCX.safeTransferFrom(msg.sender, address(this), amount);
        withdrawLockedBids[roundId][msg.sender] =
            LockedBid({bidder: msg.sender, amount: amount, price: minPrice});
        withdrawLockedTotal[roundId] += amount;

        round.highestBidder = msg.sender;
        round.highestBidAmount = amount;
        round.highestBidPrice = minPrice;

        emit WithdrawBidPlaced(roundId, msg.sender, amount, minPrice);
        return roundId;
    }

    function settleDepositRound(uint256 roundId) external nonReentrant {
        Round storage round = depositRounds[roundId];
        if (round.settled) revert RoundAlreadySettled();
        if (block.timestamp < round.endTime) revert RoundNotActive();
        if (round.highestBidder == address(0)) {
            // no bids arrived
            round.settled = true;
            _startDepositRound();
            return;
        }

        round.settled = true;
        address winner = round.highestBidder;
        uint256 fillAmount = round.highestBidAmount;
        uint256 clearingPrice = round.highestBidPrice;

        LockedBid storage winningBid = depositLockedBids[roundId][winner];
        winningBid.price = 0;
        depositLockedTotal[roundId] -= clearingPrice;

        
        uint256 baseAmount = fillAmount; // 1:1 backing
        uint256 premium = clearingPrice > baseAmount ? clearingPrice - baseAmount : 0;

    
        alcx.safeTransfer(address(vault), baseAmount);

    
        if (premium > 0) {
            alcx.safeTransfer(daoTreasury, premium);
        }


        vault.mintViaAuction(winner, fillAmount);

        round.totalFilled = fillAmount;

        emit DepositRoundSettled(roundId, winner, fillAmount, clearingPrice);


        _startDepositRound();
    }

    function settleWithdrawRound(uint256 roundId) external nonReentrant {
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
        uint256 fillAmount = round.highestBidAmount;
        uint256 clearingPrice = round.highestBidPrice; // min ALCX the winner is willing to receive

        LockedBid storage winningBid = withdrawLockedBids[roundId][winner];
        winningBid.amount = 0;
        withdrawLockedTotal[roundId] -= fillAmount;


        vqALCX.approve(address(vault), fillAmount);
        vault.burnViaAuction(winner, fillAmount, clearingPrice);

        round.totalFilled = fillAmount;

        emit WithdrawRoundSettled(roundId, winner, fillAmount, clearingPrice);


        _startWithdrawRound();
    }

    function getDepositRound(uint256 roundId) external view returns (Round memory) {
        return depositRounds[roundId];
    }

    function getWithdrawRound(uint256 roundId) external view returns (Round memory) {
        return withdrawRounds[roundId];
    }
}
