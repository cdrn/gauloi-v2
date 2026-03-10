// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DataTypes} from "../types/DataTypes.sol";

interface IGauloiEscrow {
    // Events
    event OrderExecuted(
        bytes32 indexed intentId,
        address indexed taker,
        address indexed maker,
        address inputToken,
        uint256 inputAmount,
        uint256 destinationChainId,
        address outputToken,
        uint256 minOutputAmount
    );
    event FillSubmitted(
        bytes32 indexed intentId,
        address indexed maker,
        bytes32 fillTxHash,
        uint256 disputeWindowEnd
    );
    event IntentSettled(bytes32 indexed intentId, address indexed maker, uint256 amount);
    event IntentReclaimed(bytes32 indexed intentId, address indexed taker);
    event SettlementTransferFailed(bytes32 indexed intentId, address indexed recipient, uint256 amount);
    event Paused(address indexed caller);
    event Unpaused(address indexed caller);
    event DisputesUpdated(address oldDisputes, address newDisputes);
    event SettlementWindowUpdated(uint256 oldValue, uint256 newValue);
    event CommitmentTimeoutUpdated(uint256 oldValue, uint256 newValue);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event BatchSettleFailed(bytes32 indexed intentId);

    // Maker executes a taker's signed order (pulls tokens from taker, commits)
    function executeOrder(
        DataTypes.Order calldata order,
        bytes calldata takerSignature
    ) external returns (bytes32 intentId);

    // Maker submits fill evidence (destination tx hash)
    function submitFill(bytes32 intentId, bytes32 destinationTxHash) external;

    // Settle a single intent after dispute window
    function settle(DataTypes.Order calldata order) external;

    // Batch settle multiple matured intents
    function settleBatch(DataTypes.Order[] calldata orders) external;

    // Taker reclaims after commitment timeout
    function reclaimExpired(DataTypes.Order calldata order) external;

    // --- Pause ---
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);

    // --- Admin ---
    function rescueTokens(address token, address to, uint256 amount) external;

    // --- View functions ---
    function getCommitment(bytes32 intentId) external view returns (DataTypes.Commitment memory);
    function settlementWindow() external view returns (uint256);
    function commitmentTimeout() external view returns (uint256);
}
