// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Verifies the value of a single storage slot of a contract on another
///         chain, against a trusted recent block of that chain. This is the piece
///         that carries a destination-chain fact to the source chain.
///
///         Deliberately behind an interface: the trie/RLP/block-hash cryptography
///         is the largest and most dangerous surface in the system, so it is NOT
///         hand-rolled here. A production deployment wires an audited storage-proof
///         verifier — a ZK light client (Succinct) or a proof service (Axiom,
///         Herodotus) — whose job is exactly this: given a proof, return the proven
///         slot value at a trusted block, or revert.
///
///         Non-inclusion is a valid, provable outcome: an unset slot proves to
///         `bytes32(0)`. The verifier MUST revert (not return zero) when the proof
///         is malformed or the referenced block is not trusted, so a caller can
///         never confuse "proven empty" with "could not verify".
///
///         CRITICAL CONFORMANCE REQUIREMENT — LATEST FINALIZED HEAD ONLY.
///         The verifier MUST only accept proofs against the latest finalized block
///         of `chainId` that it tracks, and MUST revert for any historical or
///         unfinalized block. This is load-bearing, not advisory: FillRegistry
///         slots are write-once and never cleared, so an empty slot means "not
///         filled *as of the proven block*", not "never filled". If the verifier
///         let a caller pick an arbitrary past block, a challenger could prove a
///         maker's slot empty at a block just before the maker's fill and
///         false-convict an honest maker (their stake slashed for a fill that
///         genuinely happened). Proving only at the finalized head makes "empty"
///         mean "empty now" — and because the slot is monotonic, empty-now implies
///         never-filled, which is the only safe basis for an Invalid verdict.
///         A ZK light client (Succinct) tracks the finalized head natively; a
///         proof service (Axiom/Herodotus) must be constrained to the head block.
interface IFillProofVerifier {
    /// @param chainId  The chain whose state is being proven (destination chain)
    /// @param account  The contract whose storage is being proven (FillRegistry)
    /// @param slot     The storage slot being proven
    /// @param proof    Verifier-specific proof (block header, account+storage MPT
    ///                 proof, or a ZK proof) against the LATEST FINALIZED block of
    ///                 `chainId` — see the conformance requirement above
    /// @return value   The proven slot value (bytes32(0) for a proven-empty slot)
    function verifyStorage(
        uint256 chainId,
        address account,
        bytes32 slot,
        bytes calldata proof
    ) external view returns (bytes32 value);
}
