// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DataTypes} from "../types/DataTypes.sol";

interface IGauloiDisputes {
    // Events
    event DisputeRaised(bytes32 indexed intentId, address indexed challenger, uint256 bondAmount);
    event DisputeResolved(bytes32 indexed intentId, bool fillValid);
    event ChallengerRewarded(address indexed challenger, uint256 reward);
    event ChallengerBondSlashed(address indexed challenger, uint256 amount);

    // Any staked maker disputes a fill
    function dispute(bytes32 intentId) external;

    // Resolve via M/N EIP-712 signatures from staked makers
    function resolveDispute(
        bytes32 intentId,
        bool fillValid,
        bytes[] calldata signatures
    ) external;

    // Finalize unresolved dispute after deadline (defaults to fill-valid)
    function finalizeExpiredDispute(bytes32 intentId) external;

    // --- View functions ---
    function getDispute(bytes32 intentId) external view returns (DataTypes.Dispute memory);
    function calculateDisputeBond(uint256 fillAmount) external view returns (uint256);
    function requiredSignatures() external view returns (uint256);
    function disputeResolutionWindow() external view returns (uint256);
}
