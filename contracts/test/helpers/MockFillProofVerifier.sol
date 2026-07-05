// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFillProofVerifier} from "../../src/interfaces/IFillProofVerifier.sol";

/// @dev Test double for the storage-proof verifier. Instead of walking a trie it
///      returns pre-seeded slot values keyed by (chainId, account, slot), and
///      reverts for anything unseeded — modelling "cannot verify this proof".
///      The real verifier would derive `value` from `proof` cryptographically.
///      The seeded value models the slot at the LATEST FINALIZED HEAD, which is the
///      only block a conformant verifier proves against (see IFillProofVerifier);
///      `proof` is opaque and ignored here.
contract MockFillProofVerifier is IFillProofVerifier {
    mapping(bytes32 => bytes32) internal _values;
    mapping(bytes32 => bool) internal _known;

    function setSlot(uint256 chainId, address account, bytes32 slot, bytes32 value) external {
        bytes32 k = keccak256(abi.encode(chainId, account, slot));
        _values[k] = value;
        _known[k] = true;
    }

    function verifyStorage(
        uint256 chainId,
        address account,
        bytes32 slot,
        bytes calldata /* proof */
    ) external view returns (bytes32) {
        bytes32 k = keccak256(abi.encode(chainId, account, slot));
        require(_known[k], "MockFillProofVerifier: unverifiable proof");
        return _values[k];
    }
}
