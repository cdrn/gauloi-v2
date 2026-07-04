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

    // Deliver `amount` of `token` to `recipient` and record the fill against
    // (intentId, msg.sender). One fill per (intent, filler) — a given filler
    // cannot record the same intent twice, but distinct fillers have independent
    // slots so no one can squat another maker's slot. Resolvers read the
    // committed maker's slot; other fillers' records are ignored.
    function fill(bytes32 intentId, address token, address recipient, uint256 amount) external;

    // --- View functions ---

    // Commitment hash for a fill recorded by `filler` (bytes32(0) if none).
    // Keyed by (intentId, filler): resolvers look up the committed maker's slot.
    function getFill(bytes32 intentId, address filler) external view returns (bytes32);

    function isFilled(bytes32 intentId, address filler) external view returns (bool);

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
