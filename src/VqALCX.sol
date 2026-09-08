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
        bool fulfilled;
        bool cancelled;
    }

    IERC20 internal immutable _asset;

    function asset() public view returns (address) {
        return address(_asset);
    }

    address public governanceAddress;
    address public authorizedAuctioneer;

    uint256 public constant CANCELLATION_PENALTY_BPS = 100; // 1%
    uint256 public constant MAX_BPS = 10000;

    Bucket public depositBucket;
    Bucket public withdrawBucket;

    mapping(uint256 => Request) public depositRequests;
    mapping(uint256 => Request) public withdrawRequests;

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

    error NotGovernance();
    error NotAuctioneer();
    error CapacityExceeded();
    error NotRequestOwner();
    error AlreadyFulfilled();
    error AlreadyCancelled();
    error RequestNotFulfillable();
    error ZeroAddress();

    address private _pendingGovernance;

    constructor(address asset_, address governance_, address auctioneer_)
        ERC20("veQueue ALCX", "vqALCX")
    {
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

    function _dripDepositBucket() internal {
        Bucket storage b = depositBucket;
        uint256 elapsed = block.timestamp - b.lastDripTime;
        if (elapsed == 0) return;

        uint256 fulfillable = b.rate * elapsed;
        b.lastDripTime = block.timestamp;

        while (fulfillable > 0 && b.head < b.tail) {
            Request storage req = depositRequests[b.head];
            if (req.cancelled) {
                b.head++;
                continue;
            }
            if (req.fulfilled) {
                b.head++;
                continue;
            }
            if (req.amount > fulfillable) {
                break; // not enough budget for this request, wait
            }
            req.fulfilled = true;
            fulfillable -= req.amount;
            b.pendingAmount -= req.amount;
            b.head++;
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
            if (req.cancelled) {
                b.head++;
                continue;
            }
            if (req.fulfilled) {
                b.head++;
                continue;
            }
            if (req.amount > fulfillable) {
                break;
            }
            req.fulfilled = true;
            fulfillable -= req.amount;
            b.pendingAmount -= req.amount;
            b.head++;
        }

        b.availableAuctionCapacity += fulfillable;
    }

    function _drip() internal {
        _dripDepositBucket();
        _dripWithdrawBucket();
    }

    function requestDeposit(uint256 assets) external returns (uint256 requestId) {
        _dripDepositBucket();
        Bucket storage b = depositBucket;
        if (b.pendingAmount + assets > b.capacity) revert CapacityExceeded();

        requestId = b.tail++;
        depositRequests[requestId] = Request({owner: msg.sender, amount: assets, fulfilled: false, cancelled: false});
        b.pendingAmount += assets;

        emit DepositRequested(requestId, msg.sender, assets);
    }

    function requestWithdraw(uint256 assets) external returns (uint256 requestId) {
        _dripWithdrawBucket();
        Bucket storage b = withdrawBucket;
        if (b.pendingAmount + assets > b.capacity) revert CapacityExceeded();

        requestId = b.tail++;
        withdrawRequests[requestId] =
            Request({owner: msg.sender, amount: assets, fulfilled: false, cancelled: false});
        b.pendingAmount += assets;

        emit WithdrawRequested(requestId, msg.sender, assets);
    }

    function cancelDepositRequest(uint256 requestId) external {
        Request storage req = depositRequests[requestId];
        if (req.owner != msg.sender) revert NotRequestOwner();
        if (req.fulfilled) revert AlreadyFulfilled();
        if (req.cancelled) revert AlreadyCancelled();

        req.cancelled = true;
        depositBucket.pendingAmount -= req.amount;

        // penalty: charge cancellation fee in ALCX
        uint256 penalty = (req.amount * CANCELLATION_PENALTY_BPS) / MAX_BPS;
        if (penalty > 0) {
            _asset.safeTransferFrom(msg.sender, address(this), penalty);
        }

        emit DepositRequestCancelled(requestId, penalty);
    }

    function cancelWithdrawRequest(uint256 requestId) external {
        Request storage req = withdrawRequests[requestId];
        if (req.owner != msg.sender) revert NotRequestOwner();
        if (req.fulfilled) revert AlreadyFulfilled();
        if (req.cancelled) revert AlreadyCancelled();

        req.cancelled = true;
        withdrawBucket.pendingAmount -= req.amount;

        // penalty: burn equivalent vqALCX
        uint256 penalty = (req.amount * CANCELLATION_PENALTY_BPS) / MAX_BPS;
        if (penalty > 0) {
            _burn(msg.sender, penalty);
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

    function deposit(uint256 assets, address receiver) public nonReentrant returns (uint256) {
        _drip();
        (bool found, uint256 requestId) = _findFulfillableDepositRequest(msg.sender, assets);
        if (!found) revert RequestNotFulfillable();

        // Consume the request to prevent double-claim
        depositRequests[requestId].fulfilled = false;

        _deposit(msg.sender, receiver, assets);
        return assets;
    }

    function maxMint(address receiver) public view returns (uint256) {
        return maxDeposit(receiver);
    }

    function previewMint(uint256 shares) public pure returns (uint256) {
        return shares; // 1:1
    }

    function mint(uint256 shares, address receiver) public nonReentrant returns (uint256) {
        _drip();
        (bool found, uint256 requestId) = _findFulfillableDepositRequest(msg.sender, shares);
        if (!found) revert RequestNotFulfillable();

        depositRequests[requestId].fulfilled = false;

        _deposit(msg.sender, receiver, shares);
        return shares;
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        return _getFulfillableWithdrawAmount(owner);
    }

    function previewWithdraw(uint256 assets) public pure returns (uint256) {
        return assets; // 1:1
    }

    function withdraw(uint256 assets, address receiver, address owner) public nonReentrant returns (uint256) {
        _drip();
        (bool found, uint256 requestId) = _findFulfillableWithdrawRequest(owner, assets);
        if (!found) revert RequestNotFulfillable();

        // Consume the request to prevent double-claim
        withdrawRequests[requestId].fulfilled = false;

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, assets);
        }

        _withdraw(receiver, owner, assets);
        return assets;
    }

    function maxRedeem(address owner) public view returns (uint256) {
        return maxWithdraw(owner);
    }

    function previewRedeem(uint256 shares) public pure returns (uint256) {
        return shares; // 1:1
    }

    function redeem(uint256 shares, address receiver, address owner) public nonReentrant returns (uint256) {
        _drip();
        (bool found, uint256 requestId) = _findFulfillableWithdrawRequest(owner, shares);
        if (!found) revert RequestNotFulfillable();

        withdrawRequests[requestId].fulfilled = false;

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        _withdraw(receiver, owner, shares);
        return shares;
    }

    function _deposit(address payer, address receiver, uint256 assets) internal {
        _asset.safeTransferFrom(payer, address(this), assets);
        _mint(receiver, assets);
        emit Deposit(payer, receiver, assets, assets);
    }

    function _withdraw(address receiver, address owner, uint256 assets) internal {
        _burn(owner, assets);
        _asset.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, assets);
    }

    function _findFulfillableDepositRequest(address owner, uint256 minAmount)
        internal
        view
        returns (bool found, uint256 requestId)
    {
        Bucket storage b = depositBucket;
        
        for (uint256 i = 0; i < b.tail; i++) {
            Request storage req = depositRequests[i];
            if (req.owner == owner && req.fulfilled && !req.cancelled && req.amount >= minAmount) {
                return (true, i);
            }
        }
        return (false, 0);
    }

    function _findFulfillableWithdrawRequest(address owner, uint256 minAmount)
        internal
        view
        returns (bool found, uint256 requestId)
    {
        Bucket storage b = withdrawBucket;
        for (uint256 i = 0; i < b.tail; i++) {
            Request storage req = withdrawRequests[i];
            if (req.owner == owner && req.fulfilled && !req.cancelled && req.amount >= minAmount) {
                return (true, i);
            }
        }
        return (false, 0);
    }

    function _getFulfillableDepositAmount(address owner) internal view returns (uint256 total) {
        Bucket storage b = depositBucket;
        for (uint256 i = 0; i < b.tail; i++) {
            Request storage req = depositRequests[i];
            if (req.owner == owner && req.fulfilled && !req.cancelled) {
                total += req.amount;
            }
        }
    }

    function _getFulfillableWithdrawAmount(address owner) internal view returns (uint256 total) {
        Bucket storage b = withdrawBucket;
        for (uint256 i = 0; i < b.tail; i++) {
            Request storage req = withdrawRequests[i];
            if (req.owner == owner && req.fulfilled && !req.cancelled) {
                total += req.amount;
            }
        }
    }

    function mintViaAuction(address to, uint256 amount) external onlyAuctioneer {
        _dripDepositBucket();
        Bucket storage b = depositBucket;
        require(b.availableAuctionCapacity >= amount, "auction capacity exceeded");
        b.availableAuctionCapacity -= amount;

        _mint(to, amount);
        emit AuctionFillExecuted(to, amount);
        emit Deposit(msg.sender, to, amount, amount);
    }

    function burnViaAuction(address winner, uint256 burnAmount, uint256 payoutAmount) external onlyAuctioneer {
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
        _dripDepositBucket();
        depositBucket.rate = rate;
        depositBucket.capacity = capacity;
        emit BucketParamsUpdated(true, rate, capacity);
    }

    function setWithdrawBucketParams(uint256 rate, uint256 capacity) external onlyGovernance {
        _dripWithdrawBucket();
        withdrawBucket.rate = rate;
        withdrawBucket.capacity = capacity;
        emit BucketParamsUpdated(false, rate, capacity);
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

    function setAuthorizedAuctioneer(address newAuctioneer) external onlyGovernance {
        emit AuthorizedAuctioneerChanged(authorizedAuctioneer, newAuctioneer);
        authorizedAuctioneer = newAuctioneer;
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

    function getDepositRequest(uint256 requestId) external view returns (Request memory) {
        return depositRequests[requestId];
    }

    function getWithdrawRequest(uint256 requestId) external view returns (Request memory) {
        return withdrawRequests[requestId];
    }
}
