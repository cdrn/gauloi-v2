// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGauloiFillRegistry {
    // Events
    event Filled(
        bytes32 indexed intentId,
        address indexed token,
        address indexed recipient,
        uint256 amount,
        address filler
    );

    // Deliver `amount` of `token` to `recipient` and record the fill against `intentId`.
    // Exactly one fill per intent — repeat calls for the same intentId revert.
    function fill(bytes32 intentId, address token, address recipient, uint256 amount) external;

    // --- View functions ---

    // Commitment hash for a recorded fill (bytes32(0) if unfilled)
    function getFill(bytes32 intentId) external view returns (bytes32);

    function isFilled(bytes32 intentId) external view returns (bool);

    // Recompute a fill commitment from its preimage — used by verifiers
    // checking a proven storage slot against claimed fill parameters
    function computeFillCommitment(
        address token,
        address recipient,
        uint256 amount,
        address filler,
        uint256 blockNumber
    ) external pure returns (bytes32);
}
