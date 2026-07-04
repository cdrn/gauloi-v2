// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DataTypes} from "../types/DataTypes.sol";

/// @notice Terminal arbiter for disputes on a corridor. Each destination chain is
///         assigned one resolver in GauloiDisputes: a storage-proof verifier where
///         the corridor is provable, a named M-of-N council where it is not.
///         A resolver renders a verdict from evidence; it never moves funds.
interface IResolver {
    enum Verdict {
        Pending, // evidence insufficient — dispute stays open
        Valid,   // fill satisfied the order — challenger loses bond
        Invalid  // fill did not happen / did not satisfy the order — maker slashed
    }

    /// @param intentId The disputed intent
    /// @param order    The order under dispute (resolver checks fill against its terms)
    /// @param evidence Resolver-specific: council verdict signatures, storage proof, etc.
    function resolve(
        bytes32 intentId,
        DataTypes.Order calldata order,
        bytes calldata evidence
    ) external returns (Verdict);
}
