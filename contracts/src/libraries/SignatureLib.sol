// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

library SignatureLib {
    bytes32 internal constant FILL_ATTESTATION_TYPEHASH = keccak256(
        "FillAttestation(bytes32 intentId,bool fillValid,bytes32 fillTxHash,uint256 destinationChainId)"
    );

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    function buildDomainSeparator(address verifyingContract) internal view returns (bytes32) {
        return keccak256(abi.encode(
            EIP712_DOMAIN_TYPEHASH,
            keccak256("GauloiDisputes"),
            keccak256("1"),
            block.chainid,
            verifyingContract
        ));
    }

    function hashAttestation(
        bytes32 intentId,
        bool fillValid,
        bytes32 fillTxHash,
        uint256 destinationChainId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            FILL_ATTESTATION_TYPEHASH,
            intentId,
            fillValid,
            fillTxHash,
            destinationChainId
        ));
    }

    function recoverAttestor(
        bytes32 domainSeparator,
        bytes32 intentId,
        bool fillValid,
        bytes32 fillTxHash,
        uint256 destinationChainId,
        bytes memory signature
    ) internal pure returns (address) {
        bytes32 structHash = hashAttestation(intentId, fillValid, fillTxHash, destinationChainId);
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        return ECDSA.recover(digest, signature);
    }
}
