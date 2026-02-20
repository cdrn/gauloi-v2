// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DataTypes} from "../types/DataTypes.sol";

interface IGauloiEscrow {
    // Events
    event IntentCreated(
        bytes32 indexed intentId,
        address indexed taker,
        address inputToken,
        uint256 inputAmount,
        uint256 destinationChainId,
        address outputToken,
        uint256 minOutputAmount
    );
    event IntentCommitted(bytes32 indexed intentId, address indexed maker);
    event FillSubmitted(
        bytes32 indexed intentId,
        address indexed maker,
        bytes32 fillTxHash,
        uint256 disputeWindowEnd
    );
    event IntentSettled(bytes32 indexed intentId, address indexed maker, uint256 amount);
    event IntentReclaimed(bytes32 indexed intentId, address indexed taker);

    // Taker deposits and creates intent
    function createIntent(
        address inputToken,
        uint256 inputAmount,
        address outputToken,
        uint256 minOutputAmount,
        uint256 destinationChainId,
        address destinationAddress,
        uint256 expiry
    ) external returns (bytes32 intentId);

    // Staked maker commits to fill an intent
    function commitToIntent(bytes32 intentId) external;

    // Maker submits fill evidence (destination tx hash)
    function submitFill(bytes32 intentId, bytes32 destinationTxHash) external;

    // Settle a single intent after dispute window
    function settle(bytes32 intentId) external;

    // Batch settle multiple matured intents
    function settleBatch(bytes32[] calldata intentIds) external;

    // Taker reclaims after expiry or commitment timeout
    function reclaimExpired(bytes32 intentId) external;

    // --- View functions ---
    function getIntent(bytes32 intentId) external view returns (DataTypes.Intent memory);
    function settlementWindow() external view returns (uint256);
    function commitmentTimeout() external view returns (uint256);
}
