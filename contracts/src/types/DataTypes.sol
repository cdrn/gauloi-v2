// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library DataTypes {
    enum IntentState {
        Open,       // Taker deposited, waiting for maker
        Committed,  // Maker reserved, filling in progress
        Filled,     // Maker submitted fill evidence, dispute window active
        Settled,    // Escrow released to maker (terminal)
        Disputed,   // Active dispute in progress
        Expired     // No maker committed or commitment timed out, taker can reclaim (terminal)
    }

    struct Intent {
        bytes32 intentId;
        address taker;
        address inputToken;
        uint256 inputAmount;
        uint256 destinationChainId;
        address destinationAddress;
        address outputToken;
        uint256 minOutputAmount;
        uint256 expiry;
        IntentState state;
        address maker;
        uint256 commitmentDeadline;
        bytes32 fillTxHash;
        uint256 disputeWindowEnd;
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
