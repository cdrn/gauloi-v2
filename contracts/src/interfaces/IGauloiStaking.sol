// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DataTypes} from "../types/DataTypes.sol";

interface IGauloiStaking {
    // Events
    event Staked(address indexed maker, uint256 amount);
    event UnstakeRequested(address indexed maker, uint256 amount, uint256 availableAt);
    event Unstaked(address indexed maker, uint256 amount);
    event Slashed(address indexed maker, uint256 amount, bytes32 indexed intentId);
    event PriceFeedUpdated(address indexed oldFeed, address indexed newFeed);
    event MinStakeUpdated(uint256 oldValue, uint256 newValue);
    event CooldownUpdated(uint256 oldValue, uint256 newValue);
    event EscrowUpdated(address oldEscrow, address newEscrow);
    event DisputesUpdated(address oldDisputes, address newDisputes);

    // Maker joins by staking USDC
    function stake(uint256 amount) external;

    // Request unstake (starts cooldown)
    function requestUnstake(uint256 amount) external;

    // Complete unstake after cooldown
    function completeUnstake() external;

    // --- Called by Escrow/Disputes contracts (permissioned) ---

    // Increase maker's active exposure when they commit to an intent
    function increaseExposure(address maker, uint256 amount) external;

    // Decrease maker's active exposure when intent settles or expires
    function decreaseExposure(address maker, uint256 amount) external;

    // Slash maker's entire stake (called by Disputes on fraud)
    function slash(address maker, bytes32 intentId) external returns (uint256 slashedAmount);

    // Slash a partial amount of maker's stake (called by Disputes for curve-based slashing)
    function slashPartial(address maker, bytes32 intentId, uint256 amount) external returns (uint256 slashedAmount);

    // --- View functions ---
    function getMakerInfo(address maker) external view returns (DataTypes.MakerInfo memory);
    function availableCapacity(address maker) external view returns (uint256);
    function isActiveMaker(address maker) external view returns (bool);
    function stakeToken() external view returns (address);
    function minStake() external view returns (uint256);
    function cooldownPeriod() external view returns (uint256);
    function totalActiveStake() external view returns (uint256);
    function getStake(address maker) external view returns (uint256);
    function getExposure(address maker) external view returns (uint256);

    // --- Oracle ---
    function setPriceFeed(address _priceFeed) external;
}
