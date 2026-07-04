// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IResolver} from "../interfaces/IResolver.sol";
import {DataTypes} from "../types/DataTypes.sol";
import {SignatureLib} from "../libraries/SignatureLib.sol";

/// @notice Terminal arbiter for corridors where on-chain proof is not feasible.
///         M-of-N EIP-712 verdicts from a named, on-chain-registered council.
///
///         Honest centralization, honestly labeled: members are publicly
///         identified and accountable, and the residual trust is priced into the
///         corridor's spread. A corridor graduates away from the council the
///         moment its ProofResolver exists — the council's jurisdiction is
///         explicitly temporary per corridor.
///
///         Stateless with respect to disputes: it verifies signatures over a
///         verdict digest and reports Valid/Invalid/Pending. It never moves funds.
contract CouncilResolver is IResolver, Ownable {
    bytes32 public constant VERDICT_TYPEHASH =
        keccak256("CouncilVerdict(bytes32 intentId,bool fillValid,uint256 destinationChainId)");

    bytes32 public immutable domainSeparator;

    mapping(address => bool) public isMember;
    uint256 public memberCount;
    uint256 public threshold;

    event MemberAdded(address indexed member);
    event MemberRemoved(address indexed member);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    constructor(address[] memory initialMembers, uint256 _threshold, address _owner) Ownable(_owner) {
        domainSeparator = SignatureLib.buildDomainSeparator("GauloiCouncil", address(this));

        for (uint256 i = 0; i < initialMembers.length; i++) {
            _addMember(initialMembers[i]);
        }
        require(_threshold >= 1 && _threshold <= memberCount, "CouncilResolver: invalid threshold");
        threshold = _threshold;
    }

    // --- Membership admin ---

    function addMember(address member) external onlyOwner {
        _addMember(member);
    }

    function removeMember(address member) external onlyOwner {
        require(isMember[member], "CouncilResolver: not a member");
        require(memberCount - 1 >= threshold, "CouncilResolver: would break threshold");
        isMember[member] = false;
        memberCount--;
        emit MemberRemoved(member);
    }

    function setThreshold(uint256 _threshold) external onlyOwner {
        require(_threshold >= 1 && _threshold <= memberCount, "CouncilResolver: invalid threshold");
        uint256 oldThreshold = threshold;
        threshold = _threshold;
        emit ThresholdUpdated(oldThreshold, _threshold);
    }

    function _addMember(address member) internal {
        require(member != address(0), "CouncilResolver: zero address");
        require(!isMember[member], "CouncilResolver: already a member");
        isMember[member] = true;
        memberCount++;
        emit MemberAdded(member);
    }

    // --- IResolver ---

    /// @param evidence abi.encode(bool fillValid, bytes[] signatures) — signatures
    ///        over the verdict digest, from council members, sorted by ascending
    ///        signer address (cheap on-chain dedup)
    function resolve(
        bytes32 intentId,
        DataTypes.Order calldata order,
        bytes calldata evidence
    ) external view returns (Verdict) {
        (bool fillValid, bytes[] memory signatures) = abi.decode(evidence, (bool, bytes[]));

        bytes32 digest = verdictDigest(intentId, fillValid, order.destinationChainId);

        uint256 count;
        address last = address(0);
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ECDSA.recover(digest, signatures[i]);
            require(signer > last, "CouncilResolver: signers not sorted");
            require(isMember[signer], "CouncilResolver: not a member");
            last = signer;
            count++;
        }

        if (count >= threshold) {
            return fillValid ? Verdict.Valid : Verdict.Invalid;
        }
        return Verdict.Pending;
    }

    // --- Views ---

    /// @dev The digest council members sign — exposed so off-chain signers and
    ///      the verifier can never disagree on construction
    function verdictDigest(
        bytes32 intentId,
        bool fillValid,
        uint256 destinationChainId
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(VERDICT_TYPEHASH, intentId, fillValid, destinationChainId));
        return MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }
}
