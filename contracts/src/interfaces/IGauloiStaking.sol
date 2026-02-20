// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DataTypes} from "../types/DataTypes.sol";

interface IGauloiStaking {
    // Events
    event Staked(address indexed maker, uint256 amount);
    event UnstakeRequested(address indexed maker, uint256 amount, uint256 availableAt);
    event Unstaked(address indexed maker, uint256 amount);
    event Slashed(address indexed maker, uint256 amount, bytes32 indexed intentId);

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

    // --- View functions ---
    function getMakerInfo(address maker) external view returns (DataTypes.MakerInfo memory);
    function availableCapacity(address maker) external view returns (uint256);
    function isActiveMaker(address maker) external view returns (bool);
    function stakeToken() external view returns (address);
    function minStake() external view returns (uint256);
    function cooldownPeriod() external view returns (uint256);
}
