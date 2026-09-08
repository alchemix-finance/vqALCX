// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract VqALCX is ERC20, IERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Bucket {
        uint256 capacity;
        uint256 rate;
        uint256 head;
        uint256 tail;
        uint256 pendingAmount;
        uint256 lastDripTime;
        uint256 availableAuctionCapacity;
    }

    struct Request {
        address owner;
        uint256 amount;
        uint256 filled;
        uint256 claimed;
        bool cancelled;
    }

    IERC20 internal immutable _asset;

    function asset() public view returns (address) {
        return address(_asset);
    }

    address public governanceAddress;
    address public authorizedAuctioneer;
    address private _pendingGovernance;
    address private _pendingAuctioneer;

    uint256 public constant MAX_CANCELLATION_PENALTY_BPS = 500;
    uint256 public constant MAX_BPS = 10000;
    uint256 public cancellationPenaltyBps = 100;

    bool public paused;

    Bucket public depositBucket;
    Bucket public withdrawBucket;

    mapping(uint256 => Request) public depositRequests;
    mapping(uint256 => Request) public withdrawRequests;
    mapping(address => uint256[]) public depositRequestIds;
    mapping(address => uint256[]) public withdrawRequestIds;

    event DepositRequested(uint256 indexed requestId, address indexed owner, uint256 amount);
    event WithdrawRequested(uint256 indexed requestId, address indexed owner, uint256 amount);
    event DepositRequestCancelled(uint256 indexed requestId, uint256 penalty);
    event WithdrawRequestCancelled(uint256 indexed requestId, uint256 penalty);
    event GovernanceAddressChanged(address indexed oldAddress, address indexed newAddress);
    event AuthorizedAuctioneerChanged(address indexed oldAuctioneer, address indexed newAuctioneer);
    event BucketParamsUpdated(bool isDeposit, uint256 rate, uint256 capacity);
    event AuctionFillExecuted(address indexed to, uint256 amount);
    event AuctionBurnExecuted(address indexed from, uint256 amount);
    event PendingGovernanceProposed(address indexed newGovernance);
    event GovernanceAccepted(address indexed newGovernance);
    event PendingAuctioneerProposed(address indexed newAuctioneer);
    event AuctioneerAccepted(address indexed newAuctioneer);
    event CancellationPenaltyUpdated(uint256 penaltyBps);
    event PauseChanged(bool paused);

    error NotGovernance();
    error NotAuctioneer();
    error CapacityExceeded();
    error NotRequestOwner();
    error AlreadyFulfilled();
    error AlreadyCancelled();
    error RequestNotFulfillable();
    error ZeroAddress();
    error ZeroAmount();
    error EnforcedPause();
    error PayoutExceedsBurn();
    error InvalidBucketParams();
    error InvalidPenalty();

    constructor(address asset_, address governance_, address auctioneer_) ERC20("veQueue ALCX", "vqALCX") {
        if (asset_ == address(0) || governance_ == address(0)) revert ZeroAddress();
        _asset = IERC20(asset_);
        governanceAddress = governance_;
        // auctioneer can be address(0) initially
        authorizedAuctioneer = auctioneer_;

        // Buckets start empty
        depositBucket.lastDripTime = block.timestamp;
        withdrawBucket.lastDripTime = block.timestamp;
    }

    modifier onlyGovernance() {
        if (msg.sender != governanceAddress) revert NotGovernance();
        _;
    }

    modifier onlyAuctioneer() {
        if (msg.sender != authorizedAuctioneer) revert NotAuctioneer();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert EnforcedPause();
        _;
    }

    function _dripDepositBucket() internal {
        Bucket storage b = depositBucket;
        uint256 elapsed = block.timestamp - b.lastDripTime;
        if (elapsed == 0) return;

        uint256 fulfillable = b.rate * elapsed;
        b.lastDripTime = block.timestamp;

        while (fulfillable > 0 && b.head < b.tail) {
            Request storage req = depositRequests[b.head];
            uint256 remaining = req.amount - req.filled;
            if (req.cancelled || remaining == 0) {
                b.head++;
                continue;
            }
            uint256 take = remaining > fulfillable ? fulfillable : remaining;
            req.filled += take;
            fulfillable -= take;
            b.pendingAmount -= take;
            if (req.filled == req.amount) {
                b.head++;
            }
        }

        // remaining fulfillable is available for auctions
        b.availableAuctionCapacity += fulfillable;
    }

    function _dripWithdrawBucket() internal {
        Bucket storage b = withdrawBucket;
        uint256 elapsed = block.timestamp - b.lastDripTime;
        if (elapsed == 0) return;

        uint256 fulfillable = b.rate * elapsed;
        b.lastDripTime = block.timestamp;

        while (fulfillable > 0 && b.head < b.tail) {
            Request storage req = withdrawRequests[b.head];
            uint256 remaining = req.amount - req.filled;
            if (req.cancelled || remaining == 0) {
                b.head++;
                continue;
            }
            uint256 take = remaining > fulfillable ? fulfillable : remaining;
            req.filled += take;
            fulfillable -= take;
            b.pendingAmount -= take;
            if (req.filled == req.amount) {
                b.head++;
            }
        }

        b.availableAuctionCapacity += fulfillable;
    }

    function _drip() internal {
        _dripDepositBucket();
        _dripWithdrawBucket();
    }

    function requestDeposit(uint256 assets) external nonReentrant whenNotPaused returns (uint256 requestId) {
        if (assets == 0) revert ZeroAmount();
        _dripDepositBucket();
        Bucket storage b = depositBucket;
        if (b.pendingAmount + assets > b.capacity) revert CapacityExceeded();

        _asset.safeTransferFrom(msg.sender, address(this), assets);

        requestId = b.tail++;
        depositRequests[requestId] =
            Request({owner: msg.sender, amount: assets, filled: 0, claimed: 0, cancelled: false});
        depositRequestIds[msg.sender].push(requestId);
        b.pendingAmount += assets;

        emit DepositRequested(requestId, msg.sender, assets);
    }

    function requestWithdraw(uint256 assets) external nonReentrant whenNotPaused returns (uint256 requestId) {
        if (assets == 0) revert ZeroAmount();
        _dripWithdrawBucket();
        Bucket storage b = withdrawBucket;
        if (b.pendingAmount + assets > b.capacity) revert CapacityExceeded();

        _transfer(msg.sender, address(this), assets);

        requestId = b.tail++;
        withdrawRequests[requestId] =
            Request({owner: msg.sender, amount: assets, filled: 0, claimed: 0, cancelled: false});
        withdrawRequestIds[msg.sender].push(requestId);
        b.pendingAmount += assets;

        emit WithdrawRequested(requestId, msg.sender, assets);
    }

    function cancelDepositRequest(uint256 requestId) external nonReentrant {
        Request storage req = depositRequests[requestId];
        if (req.owner != msg.sender) revert NotRequestOwner();
        if (req.cancelled) revert AlreadyCancelled();
        uint256 remaining = req.amount - req.filled;
        if (remaining == 0) revert AlreadyFulfilled();

        req.cancelled = true;
        depositBucket.pendingAmount -= remaining;

        uint256 penalty = (remaining * cancellationPenaltyBps) / MAX_BPS;
        uint256 refund = remaining - penalty;
        if (refund > 0) {
            _asset.safeTransfer(msg.sender, refund);
        }

        emit DepositRequestCancelled(requestId, penalty);
    }

    function cancelWithdrawRequest(uint256 requestId) external nonReentrant {
        Request storage req = withdrawRequests[requestId];
        if (req.owner != msg.sender) revert NotRequestOwner();
        if (req.cancelled) revert AlreadyCancelled();
        uint256 remaining = req.amount - req.filled;
        if (remaining == 0) revert AlreadyFulfilled();

        req.cancelled = true;
        withdrawBucket.pendingAmount -= remaining;

        uint256 penalty = (remaining * cancellationPenaltyBps) / MAX_BPS;
        uint256 refund = remaining - penalty;
        if (penalty > 0) {
            _burn(address(this), penalty);
        }
        if (refund > 0) {
            _transfer(address(this), msg.sender, refund);
        }

        emit WithdrawRequestCancelled(requestId, penalty);
    }

    function totalAssets() public view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public pure returns (uint256) {
        return assets; // 1:1 at watermark
    }

    function convertToAssets(uint256 shares) public pure returns (uint256) {
        return shares; // 1:1 at watermark
    }

    function maxDeposit(address receiver) public view returns (uint256) {
        return _getFulfillableDepositAmount(receiver);
    }

    function previewDeposit(uint256 assets) public pure returns (uint256) {
        return assets; // 1:1
    }

    function deposit(uint256 assets, address receiver) public nonReentrant whenNotPaused returns (uint256) {
        if (assets == 0) revert ZeroAmount();
        _drip();
        (bool found, uint256 requestId) = _findClaimableDepositRequest(msg.sender, assets);
        if (!found) revert RequestNotFulfillable();

        depositRequests[requestId].claimed += assets;

        _mint(receiver, assets);
        emit Deposit(msg.sender, receiver, assets, assets);
        return assets;
    }

    function maxMint(address receiver) public view returns (uint256) {
        return maxDeposit(receiver);
    }

    function previewMint(uint256 shares) public pure returns (uint256) {
        return shares; // 1:1
    }

    function mint(uint256 shares, address receiver) public nonReentrant whenNotPaused returns (uint256) {
        if (shares == 0) revert ZeroAmount();
        _drip();
        (bool found, uint256 requestId) = _findClaimableDepositRequest(msg.sender, shares);
        if (!found) revert RequestNotFulfillable();

        depositRequests[requestId].claimed += shares;

        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, shares, shares);
        return shares;
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        return _getFulfillableWithdrawAmount(owner);
    }

    function previewWithdraw(uint256 assets) public pure returns (uint256) {
        return assets; // 1:1
    }

    function withdraw(uint256 assets, address receiver, address owner) public nonReentrant returns (uint256) {
        if (assets == 0) revert ZeroAmount();
        _drip();
        (bool found, uint256 requestId) = _findClaimableWithdrawRequest(owner, assets);
        if (!found) revert RequestNotFulfillable();

        withdrawRequests[requestId].claimed += assets;

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, assets);
        }

        _burn(address(this), assets);
        _asset.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, assets);
        return assets;
    }

    function maxRedeem(address owner) public view returns (uint256) {
        return maxWithdraw(owner);
    }

    function previewRedeem(uint256 shares) public pure returns (uint256) {
        return shares; // 1:1
    }

    function redeem(uint256 shares, address receiver, address owner) public nonReentrant returns (uint256) {
        if (shares == 0) revert ZeroAmount();
        _drip();
        (bool found, uint256 requestId) = _findClaimableWithdrawRequest(owner, shares);
        if (!found) revert RequestNotFulfillable();

        withdrawRequests[requestId].claimed += shares;

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        _burn(address(this), shares);
        _asset.safeTransfer(receiver, shares);
        emit Withdraw(msg.sender, receiver, owner, shares, shares);
        return shares;
    }

    function _findClaimableDepositRequest(address owner, uint256 minAmount)
        internal
        view
        returns (bool found, uint256 requestId)
    {
        uint256[] memory ids = depositRequestIds[owner];
        for (uint256 i = 0; i < ids.length; i++) {
            Request storage req = depositRequests[ids[i]];
            uint256 claimable = req.filled - req.claimed;
            if (claimable >= minAmount && claimable > 0) {
                return (true, ids[i]);
            }
        }
        return (false, 0);
    }

    function _findClaimableWithdrawRequest(address owner, uint256 minAmount)
        internal
        view
        returns (bool found, uint256 requestId)
    {
        uint256[] memory ids = withdrawRequestIds[owner];
        for (uint256 i = 0; i < ids.length; i++) {
            Request storage req = withdrawRequests[ids[i]];
            uint256 claimable = req.filled - req.claimed;
            if (claimable >= minAmount && claimable > 0) {
                return (true, ids[i]);
            }
        }
        return (false, 0);
    }

    function _getFulfillableDepositAmount(address owner) internal view returns (uint256 total) {
        uint256[] memory ids = depositRequestIds[owner];
        for (uint256 i = 0; i < ids.length; i++) {
            Request storage req = depositRequests[ids[i]];
            if (req.filled > req.claimed) {
                total += req.filled - req.claimed;
            }
        }
    }

    function _getFulfillableWithdrawAmount(address owner) internal view returns (uint256 total) {
        uint256[] memory ids = withdrawRequestIds[owner];
        for (uint256 i = 0; i < ids.length; i++) {
            Request storage req = withdrawRequests[ids[i]];
            if (req.filled > req.claimed) {
                total += req.filled - req.claimed;
            }
        }
    }

    function mintViaAuction(address to, uint256 amount) external onlyAuctioneer whenNotPaused {
        _dripDepositBucket();
        Bucket storage b = depositBucket;
        require(b.availableAuctionCapacity >= amount, "auction capacity exceeded");
        b.availableAuctionCapacity -= amount;

        _mint(to, amount);
        emit AuctionFillExecuted(to, amount);
        emit Deposit(msg.sender, to, amount, amount);
    }

    function burnViaAuction(address winner, uint256 burnAmount, uint256 payoutAmount) external onlyAuctioneer {
        if (payoutAmount > burnAmount) revert PayoutExceedsBurn();
        _dripWithdrawBucket();
        Bucket storage b = withdrawBucket;
        require(b.availableAuctionCapacity >= burnAmount, "auction capacity exceeded");
        b.availableAuctionCapacity -= burnAmount;

        // burn vqALCX from auctioneer's locked balance
        _burn(authorizedAuctioneer, burnAmount);
        // send only payoutAmount to winner
        // discount stays in vault as protocol profit
        _asset.safeTransfer(winner, payoutAmount);
        emit AuctionBurnExecuted(winner, burnAmount);
        emit Withdraw(msg.sender, winner, authorizedAuctioneer, burnAmount, payoutAmount);
    }

    function setDepositBucketParams(uint256 rate, uint256 capacity) external onlyGovernance {
        if (rate == 0) revert InvalidBucketParams();
        _dripDepositBucket();
        if (capacity < depositBucket.pendingAmount) revert InvalidBucketParams();
        depositBucket.rate = rate;
        depositBucket.capacity = capacity;
        emit BucketParamsUpdated(true, rate, capacity);
    }

    function setWithdrawBucketParams(uint256 rate, uint256 capacity) external onlyGovernance {
        if (rate == 0) revert InvalidBucketParams();
        _dripWithdrawBucket();
        if (capacity < withdrawBucket.pendingAmount) revert InvalidBucketParams();
        withdrawBucket.rate = rate;
        withdrawBucket.capacity = capacity;
        emit BucketParamsUpdated(false, rate, capacity);
    }

    function setCancellationPenaltyBps(uint256 penaltyBps) external onlyGovernance {
        if (penaltyBps > MAX_CANCELLATION_PENALTY_BPS) revert InvalidPenalty();
        cancellationPenaltyBps = penaltyBps;
        emit CancellationPenaltyUpdated(penaltyBps);
    }

    function proposeGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();
        _pendingGovernance = newGovernance;
        emit PendingGovernanceProposed(newGovernance);
    }

    function acceptGovernance() external {
        if (msg.sender != _pendingGovernance) revert NotGovernance();
        emit GovernanceAddressChanged(governanceAddress, msg.sender);
        emit GovernanceAccepted(msg.sender);
        governanceAddress = msg.sender;
        _pendingGovernance = address(0);
    }

    function proposeAuctioneer(address newAuctioneer) external onlyGovernance {
        if (newAuctioneer == address(0)) revert ZeroAddress();
        _pendingAuctioneer = newAuctioneer;
        emit PendingAuctioneerProposed(newAuctioneer);
    }

    function acceptAuctioneer() external {
        if (msg.sender != _pendingAuctioneer) revert NotAuctioneer();
        emit AuthorizedAuctioneerChanged(authorizedAuctioneer, msg.sender);
        emit AuctioneerAccepted(msg.sender);
        authorizedAuctioneer = msg.sender;
        _pendingAuctioneer = address(0);
    }

    function pause() external onlyGovernance {
        paused = true;
        emit PauseChanged(true);
    }

    function unpause() external onlyGovernance {
        paused = false;
        emit PauseChanged(false);
    }

    function drip() external {
        _drip();
    }

    function depositQueueDepth() external view returns (uint256) {
        return depositBucket.pendingAmount;
    }

    function withdrawQueueDepth() external view returns (uint256) {
        return withdrawBucket.pendingAmount;
    }

    function depositBucketRate() external view returns (uint256) {
        return depositBucket.rate;
    }

    function depositBucketCapacity() external view returns (uint256) {
        return depositBucket.capacity;
    }

    function withdrawBucketRate() external view returns (uint256) {
        return withdrawBucket.rate;
    }

    function withdrawBucketCapacity() external view returns (uint256) {
        return withdrawBucket.capacity;
    }

    function depositAuctionCapacity() external view returns (uint256) {
        return depositBucket.availableAuctionCapacity;
    }

    function withdrawAuctionCapacity() external view returns (uint256) {
        return withdrawBucket.availableAuctionCapacity;
    }

    function getDepositRequest(uint256 requestId) external view returns (Request memory) {
        return depositRequests[requestId];
    }

    function getWithdrawRequest(uint256 requestId) external view returns (Request memory) {
        return withdrawRequests[requestId];
    }
}
