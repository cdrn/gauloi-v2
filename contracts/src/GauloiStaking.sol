// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGauloiStaking} from "./interfaces/IGauloiStaking.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {DataTypes} from "./types/DataTypes.sol";

contract GauloiStaking is IGauloiStaking, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakeTokenContract;
    uint256 public minStakeAmount;
    uint256 public cooldownDuration;

    // Chainlink USDC/USD price feed for oracle-adjusted exposure checks
    AggregatorV3Interface public priceFeed;
    uint8 public priceFeedDecimals;
    uint256 public immutable stalePriceThreshold;

    // Authorized callers for permissioned functions
    address public escrow;
    address public disputes;

    mapping(address => DataTypes.MakerInfo) internal _makers;

    modifier onlyEscrow() {
        require(msg.sender == escrow, "GauloiStaking: caller is not escrow");
        _;
    }

    modifier onlyEscrowOrDisputes() {
        require(
            msg.sender == escrow || msg.sender == disputes,
            "GauloiStaking: caller is not escrow or disputes"
        );
        _;
    }

    modifier onlyDisputes() {
        require(msg.sender == disputes, "GauloiStaking: caller is not disputes");
        _;
    }

    constructor(
        address _stakeToken,
        uint256 _minStake,
        uint256 _cooldownPeriod,
        uint256 _stalePriceThreshold,
        address _owner
    ) Ownable(_owner) {
        require(_stakeToken != address(0), "GauloiStaking: zero address");
        require(_stalePriceThreshold > 0, "GauloiStaking: zero threshold");
        stakeTokenContract = IERC20(_stakeToken);
        minStakeAmount = _minStake;
        cooldownDuration = _cooldownPeriod;
        stalePriceThreshold = _stalePriceThreshold;
    }

    // --- Admin ---

    function setEscrow(address _escrow) external onlyOwner {
        require(_escrow != address(0), "GauloiStaking: zero address");
        escrow = _escrow;
    }

    function setDisputes(address _disputes) external onlyOwner {
        require(_disputes != address(0), "GauloiStaking: zero address");
        disputes = _disputes;
    }

    function setMinStake(uint256 _minStake) external onlyOwner {
        minStakeAmount = _minStake;
    }

    function setCooldownPeriod(uint256 _cooldownPeriod) external onlyOwner {
        cooldownDuration = _cooldownPeriod;
    }

    function setPriceFeed(address _priceFeed) external onlyOwner {
        address oldFeed = address(priceFeed);
        if (_priceFeed == address(0)) {
            priceFeed = AggregatorV3Interface(address(0));
            priceFeedDecimals = 0;
        } else {
            priceFeed = AggregatorV3Interface(_priceFeed);
            priceFeedDecimals = AggregatorV3Interface(_priceFeed).decimals();
        }
        emit PriceFeedUpdated(oldFeed, _priceFeed);
    }

    // --- Maker staking ---

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "GauloiStaking: zero amount");
        DataTypes.MakerInfo storage maker = _makers[msg.sender];

        // Effects before interaction (CEI pattern)
        maker.stakedAmount += amount;
        if (!maker.isActive && maker.stakedAmount >= minStakeAmount) {
            maker.isActive = true;
        }

        emit Staked(msg.sender, amount);

        // Interaction last
        stakeTokenContract.safeTransferFrom(msg.sender, address(this), amount);
    }

    function requestUnstake(uint256 amount) external {
        DataTypes.MakerInfo storage maker = _makers[msg.sender];
        require(amount > 0, "GauloiStaking: zero amount");
        require(maker.unstakeRequestTime == 0, "GauloiStaking: unstake already pending");

        // Can only unstake what isn't committed to active fills
        uint256 available = maker.stakedAmount - maker.activeExposure;
        require(amount <= available, "GauloiStaking: insufficient available stake");

        maker.unstakeRequestTime = block.timestamp;
        maker.unstakeAmount = amount;

        uint256 availableAt = block.timestamp + cooldownDuration;
        emit UnstakeRequested(msg.sender, amount, availableAt);
    }

    function completeUnstake() external nonReentrant {
        DataTypes.MakerInfo storage maker = _makers[msg.sender];
        require(maker.unstakeRequestTime > 0, "GauloiStaking: no unstake pending");
        require(
            block.timestamp >= maker.unstakeRequestTime + cooldownDuration,
            "GauloiStaking: cooldown not elapsed"
        );

        uint256 amount = maker.unstakeAmount;

        // Re-check available balance in case exposure changed during cooldown
        uint256 available = maker.stakedAmount - maker.activeExposure;
        require(amount <= available, "GauloiStaking: insufficient available stake");

        maker.stakedAmount -= amount;
        maker.unstakeRequestTime = 0;
        maker.unstakeAmount = 0;

        // Deactivate if below minimum
        if (maker.stakedAmount < minStakeAmount) {
            maker.isActive = false;
        }

        stakeTokenContract.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    // --- Permissioned: called by Escrow ---

    function increaseExposure(address maker, uint256 amount) external onlyEscrow {
        DataTypes.MakerInfo storage info = _makers[maker];
        require(info.isActive, "GauloiStaking: maker not active");

        uint256 newExposure = info.activeExposure + amount;
        uint256 effectiveCapacity = _stakeValueInUsd(info.stakedAmount);
        require(newExposure <= effectiveCapacity, "GauloiStaking: exposure exceeds stake");

        info.activeExposure = newExposure;
    }

    function decreaseExposure(address maker, uint256 amount) external onlyEscrowOrDisputes {
        DataTypes.MakerInfo storage info = _makers[maker];
        // Cap instead of revert — exposure may already be zeroed by slash()
        if (info.activeExposure >= amount) {
            info.activeExposure -= amount;
        } else {
            info.activeExposure = 0;
        }
    }

    // --- Permissioned: called by Disputes ---

    function slash(address maker, bytes32 intentId) external onlyDisputes returns (uint256 slashedAmount) {
        DataTypes.MakerInfo storage info = _makers[maker];
        slashedAmount = info.stakedAmount;
        require(slashedAmount > 0, "GauloiStaking: nothing to slash");

        info.stakedAmount = 0;
        info.activeExposure = 0;
        info.isActive = false;

        // Cancel any pending unstake
        info.unstakeRequestTime = 0;
        info.unstakeAmount = 0;

        // Transfer slashed funds to the disputes contract for distribution
        stakeTokenContract.safeTransfer(disputes, slashedAmount);

        emit Slashed(maker, slashedAmount, intentId);
    }

    // --- View functions ---

    function getMakerInfo(address maker) external view returns (DataTypes.MakerInfo memory) {
        return _makers[maker];
    }

    function availableCapacity(address maker) external view returns (uint256) {
        DataTypes.MakerInfo storage info = _makers[maker];
        if (!info.isActive) return 0;
        uint256 effectiveCapacity = _stakeValueInUsd(info.stakedAmount);
        if (effectiveCapacity <= info.activeExposure) return 0;
        return effectiveCapacity - info.activeExposure;
    }

    function isActiveMaker(address maker) external view returns (bool) {
        return _makers[maker].isActive;
    }

    function stakeToken() external view returns (address) {
        return address(stakeTokenContract);
    }

    function minStake() external view returns (uint256) {
        return minStakeAmount;
    }

    function cooldownPeriod() external view returns (uint256) {
        return cooldownDuration;
    }

    // --- Internal ---

    /// @dev Returns the USD value of a USDC stake amount using the oracle.
    ///      If no oracle is set, assumes 1:1 (i.e. returns the raw amount).
    ///      Chainlink USDC/USD feeds use 8 decimals, USDC uses 6.
    ///      Result is in 6-decimal "USD units" so it can be compared directly to fill amounts.
    ///      Capped at stakedAmount so oracle can only reduce capacity, never inflate above 1:1.
    function _stakeValueInUsd(uint256 stakedAmount) internal view returns (uint256) {
        if (address(priceFeed) == address(0)) {
            return stakedAmount;
        }

        (, int256 price,, uint256 updatedAt,) = priceFeed.latestRoundData();
        require(price > 0, "GauloiStaking: invalid oracle price");
        require(block.timestamp - updatedAt <= stalePriceThreshold, "GauloiStaking: stale oracle price");

        // stakedAmount (6 decimals) * price (feedDecimals) / 10^feedDecimals = USD value (6 decimals)
        uint256 oracleValue = (stakedAmount * uint256(price)) / (10 ** priceFeedDecimals);
        // Cap: oracle can only reduce capacity, never inflate above 1:1
        return oracleValue < stakedAmount ? oracleValue : stakedAmount;
    }
}
