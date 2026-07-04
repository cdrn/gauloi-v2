// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IResolver} from "../../src/interfaces/IResolver.sol";
import {DataTypes} from "../../src/types/DataTypes.sol";

/// @dev Resolver with a settable verdict; records the last call for assertions
contract MockResolver is IResolver {
    Verdict public verdict; // defaults to Pending

    bytes32 public lastIntentId;
    bytes public lastEvidence;
    uint256 public lastDestinationChainId;
    uint256 public callCount;

    function setVerdict(Verdict v) external {
        verdict = v;
    }

    function resolve(
        bytes32 intentId,
        DataTypes.Order calldata order,
        bytes calldata evidence
    ) external returns (Verdict) {
        lastIntentId = intentId;
        lastEvidence = evidence;
        lastDestinationChainId = order.destinationChainId;
        callCount++;
        return verdict;
    }
}
