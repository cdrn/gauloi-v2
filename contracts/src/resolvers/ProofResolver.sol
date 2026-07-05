// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IResolver} from "../interfaces/IResolver.sol";
import {IFillProofVerifier} from "../interfaces/IFillProofVerifier.sol";
import {GauloiEscrow} from "../GauloiEscrow.sol";
import {DataTypes} from "../types/DataTypes.sol";

/// @notice Trustless terminal arbiter for provable corridors. It resolves a
///         dispute by proving what the destination FillRegistry actually holds
///         for the committed maker's slot, then checking that fill against the
///         order — no council, no vote.
///
///         The dangerous cryptography (block-hash trust, MPT/RLP walking) lives
///         entirely in the injected IFillProofVerifier. This contract owns only
///         the decision logic:
///           1. read the committed maker for the intent from escrow (source chain)
///           2. compute the registry storage slot for (intentId, maker)
///           3. ask the verifier what that slot holds on the destination chain
///           4. bind the supplied preimage to the proven commitment
///           5. decide Valid / Invalid from order satisfaction
///
///         A proof of an EMPTY slot (maker never recorded a fill) resolves Invalid.
///         A proof of a satisfying fill resolves Valid. A proof of a fill that does
///         not satisfy the order (wrong token/recipient, or amount < minOutput)
///         resolves Invalid. Anything the verifier cannot prove reverts, so the
///         dispute stays open for a better proof or the deadline default.
///
///         SAFETY DEPENDENCY: the empty-slot → Invalid verdict is only sound
///         because the verifier proves against the destination's latest finalized
///         head (see IFillProofVerifier). Registry slots are write-once, so
///         "empty at head" == "never filled"; a verifier that proved arbitrary
///         historical blocks would let a challenger false-convict an honest maker.
///
///         KNOWN LIMITATION (accepted for v0.2): a maker who marked Filled without
///         delivering can still back-fill the registry during the dispute window
///         and prove Valid, harvesting the challenger's bond. The taker is made
///         whole (the back-fill is a real transfer satisfying the order), so this
///         is griefing of the challenger, not fund loss. Fully closing it needs a
///         destination-block ↔ source-time anchor (require the proven fill to
///         predate the challenge), which is a larger cross-chain-time feature.
///         Bond economics (forfeited on a losing challenge) bound the incentive.
contract ProofResolver is IResolver, Ownable {
    IFillProofVerifier public verifier;
    GauloiEscrow public immutable escrow;

    struct Corridor {
        address registry; // FillRegistry address on the destination chain
        uint256 fillsSlot; // storage slot index of GauloiFillRegistry._fills
        bool configured;
    }

    // destination chain id => registry location on that chain
    mapping(uint256 => Corridor) public corridors;

    event VerifierUpdated(address indexed oldVerifier, address indexed newVerifier);
    event CorridorConfigured(uint256 indexed destinationChainId, address registry, uint256 fillsSlot);

    constructor(address _verifier, address _escrow, address _owner) Ownable(_owner) {
        require(_verifier != address(0) && _escrow != address(0), "ProofResolver: zero address");
        verifier = IFillProofVerifier(_verifier);
        escrow = GauloiEscrow(_escrow);
    }

    // --- Admin ---

    function setVerifier(address _verifier) external onlyOwner {
        require(_verifier != address(0), "ProofResolver: zero address");
        address old = address(verifier);
        verifier = IFillProofVerifier(_verifier);
        emit VerifierUpdated(old, _verifier);
    }

    /// @param fillsSlot storage slot index of `_fills` in GauloiFillRegistry.
    ///        Pin this against the deployed layout (see ProofResolver test).
    function configureCorridor(uint256 destinationChainId, address registry, uint256 fillsSlot)
        external
        onlyOwner
    {
        require(registry != address(0), "ProofResolver: zero registry");
        corridors[destinationChainId] = Corridor({registry: registry, fillsSlot: fillsSlot, configured: true});
        emit CorridorConfigured(destinationChainId, registry, fillsSlot);
    }

    // --- IResolver ---

    /// @param evidence abi.encode(
    ///          address token, address recipient, uint256 amount, uint256 blockNumber, bytes proof
    ///        )
    ///        The first four are the fill-commitment preimage (filler is derived
    ///        as the committed maker); `proof` is passed to the verifier.
    function resolve(
        bytes32 intentId,
        DataTypes.Order calldata order,
        bytes calldata evidence
    ) external view returns (Verdict) {
        Corridor memory corridor = corridors[order.destinationChainId];
        require(corridor.configured, "ProofResolver: corridor not configured");

        // The fill must have been recorded by the maker who took the commitment.
        address maker = escrow.getCommitment(intentId).maker;
        require(maker != address(0), "ProofResolver: unknown intent");

        bytes32 slot = _fillSlot(intentId, maker, corridor.fillsSlot);

        // What does the destination registry actually hold for this maker's slot?
        bytes32 provenCommitment =
            verifier.verifyStorage(order.destinationChainId, corridor.registry, slot, _proof(evidence));

        // Proven empty at the finalized head → never filled (slots are write-once,
        // so empty-now implies empty-forever). Safe only under the verifier's
        // latest-finalized-head conformance requirement — see IFillProofVerifier.
        if (provenCommitment == bytes32(0)) {
            return Verdict.Invalid;
        }

        (address token, address recipient, uint256 amount, uint256 blockNumber) = _preimage(evidence);

        // Bind the supplied preimage to the proven commitment — the submitter
        // cannot lie about the fill's contents, they must match the proven hash.
        bytes32 expected = keccak256(abi.encode(token, recipient, amount, maker, blockNumber));
        require(expected == provenCommitment, "ProofResolver: preimage mismatch");

        // A recorded fill that does not satisfy the order is an invalid fill.
        if (
            token != order.outputToken ||
            recipient != order.destinationAddress ||
            amount < order.minOutputAmount
        ) {
            return Verdict.Invalid;
        }

        return Verdict.Valid;
    }

    // --- Views / helpers ---

    /// @dev Storage slot of GauloiFillRegistry._fills[keccak256(intentId, filler)].
    ///      Mirrors the registry's own `_slot(intentId, filler)` keying.
    function fillStorageSlot(bytes32 intentId, address filler, uint256 fillsSlot)
        public
        pure
        returns (bytes32)
    {
        return _fillSlot(intentId, filler, fillsSlot);
    }

    function _fillSlot(bytes32 intentId, address filler, uint256 fillsSlot) internal pure returns (bytes32) {
        bytes32 mappingKey = keccak256(abi.encode(intentId, filler));
        return keccak256(abi.encode(mappingKey, fillsSlot));
    }

    function _preimage(bytes calldata evidence)
        internal
        pure
        returns (address token, address recipient, uint256 amount, uint256 blockNumber)
    {
        (token, recipient, amount, blockNumber,) =
            abi.decode(evidence, (address, address, uint256, uint256, bytes));
    }

    function _proof(bytes calldata evidence) internal pure returns (bytes memory proof) {
        (,,,, proof) = abi.decode(evidence, (address, address, uint256, uint256, bytes));
    }
}
