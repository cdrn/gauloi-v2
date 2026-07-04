// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DataTypes} from "../types/DataTypes.sol";

interface IGauloiDisputes {
    // Events
    event DisputeRaised(bytes32 indexed intentId, address indexed challenger, uint256 bondAmount);
    event DisputeResolved(bytes32 indexed intentId, bool fillValid);
    event ChallengerRewarded(address indexed challenger, uint256 reward);
    event ChallengerBondSlashed(address indexed challenger, uint256 amount);
    event MakerRewardFailed(bytes32 indexed intentId, address indexed maker, uint256 amount);
    event ChallengerRewardFailed(bytes32 indexed intentId, address indexed challenger, uint256 amount);
    event TreasuryTransferFailed(bytes32 indexed intentId, uint256 amount);
    event ResolutionWindowUpdated(uint256 oldValue, uint256 newValue);
    event BondParamsUpdated(uint256 newBps, uint256 newMinBond);
    event SlashCurveUpdated(uint256 base, uint256 k, uint256 max);
    event ResolverUpdated(uint256 indexed destinationChainId, address indexed oldResolver, address indexed newResolver);
    event TreasuryUpdated(address oldTreasury, address newTreasury);

    // Anyone challenges a fill claim by posting a bond (permissionless)
    function challenge(DataTypes.Order calldata order) external;

    // Resolve via the corridor's terminal resolver; evidence is resolver-specific
    function resolve(bytes32 intentId, bytes calldata evidence) external;

    // Past the deadline with no verdict, the maker failed to defend: fill invalid
    function finalizeExpiredDispute(bytes32 intentId) external;

    // --- View functions ---
    function getDispute(bytes32 intentId) external view returns (DataTypes.Dispute memory);
    function getDisputeOrder(bytes32 intentId) external view returns (DataTypes.Order memory);
    function calculateDisputeBond(uint256 fillAmount) external view returns (uint256);
    function calculateSlashAmount(uint256 fillAmount, uint256 makerTotalStake) external view returns (uint256);
    function disputeResolutionWindow() external view returns (uint256);
}
