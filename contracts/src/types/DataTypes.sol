// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library DataTypes {
    enum IntentState {
        Committed,  // Maker executed order, filling in progress
        Filled,     // Maker submitted fill evidence, dispute window active
        Settled,    // Escrow released to maker (terminal)
        Disputed,   // Active dispute in progress
        Expired     // Commitment timed out, taker can reclaim (terminal)
    }

    /// @notice Signed order from the taker (never stored on-chain)
    struct Order {
        address taker;
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        uint256 minOutputAmount;
        uint256 destinationChainId;
        address destinationAddress;
        uint256 expiry;
        uint256 nonce;
    }

    /// @notice On-chain commitment — only mutable state (3 storage slots)
    struct Commitment {
        // slot 1: taker (20B) + state (1B)
        address taker;
        IntentState state;
        // slot 2: maker (20B) + commitmentDeadline (5B) + disputeWindowEnd (5B)
        address maker;
        uint40 commitmentDeadline;
        uint40 disputeWindowEnd;
        // slot 3: fillTxHash (32B)
        bytes32 fillTxHash;
    }

    struct MakerInfo {
        uint256 stakedAmount;
        uint256 activeExposure;
        uint256 unstakeRequestTime;
        uint256 unstakeAmount;
        bool isActive;
    }

    struct Dispute {
        bytes32 intentId;
        address challenger;
        uint256 bondAmount;
        uint256 disputeDeadline;
        bool resolved;
        bool fillDeemedValid;
    }
}
