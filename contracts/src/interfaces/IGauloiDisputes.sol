// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DataTypes} from "../types/DataTypes.sol";

interface IGauloiDisputes {
    // Events
    event DisputeRaised(bytes32 indexed intentId, address indexed challenger, uint256 bondAmount);
    event DisputeResolved(bytes32 indexed intentId, bool fillValid);
    event ChallengerRewarded(address indexed challenger, uint256 reward);
    event ChallengerBondSlashed(address indexed challenger, uint256 amount);
    event AttestorRecorded(bytes32 indexed intentId, address indexed attestor, bool fillValid, uint256 stakeWeight);
    event QuorumExtended(bytes32 indexed intentId, uint256 newDeadline, uint256 failCount);
    event AttestorRewarded(bytes32 indexed intentId, address indexed attestor, uint256 amount);

    // Any staked maker disputes a fill (stores order for later resolution)
    function dispute(DataTypes.Order calldata order) external;

    // Resolve via stake-weighted EIP-712 signatures from staked makers
    function resolveDispute(
        bytes32 intentId,
        bool fillValid,
        bytes[] calldata signatures
    ) external;

    // Finalize unresolved dispute after deadline
    function finalizeExpiredDispute(bytes32 intentId) external;

    // --- View functions ---
    function getDispute(bytes32 intentId) external view returns (DataTypes.Dispute memory);
    function calculateDisputeBond(uint256 fillAmount) external view returns (uint256);
    function calculateSlashAmount(uint256 fillAmount, uint256 makerTotalStake) external view returns (uint256);
    function disputeResolutionWindow() external view returns (uint256);
    function getDisputeAttestors(bytes32 intentId, bool validSide) external view returns (address[] memory);
    function getAttestorStakeWeight(bytes32 intentId, address attestor) external view returns (uint256);
    function getQuorumFailCount(bytes32 intentId) external view returns (uint256);
}
