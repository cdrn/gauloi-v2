import {
  type WalletClient,
  type Transport,
  type Chain,
  verifyTypedData,
} from "viem";
import { type PrivateKeyAccount } from "viem/accounts";

export const ZERO_BYTES32 = "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`;

// EIP-712 types for fill attestations — domain includes chainId + verifyingContract
export const ATTESTATION_TYPES = {
  FillAttestation: [
    { name: "intentId", type: "bytes32" },
    { name: "fillValid", type: "bool" },
    { name: "fillTxHash", type: "bytes32" },
    { name: "destinationChainId", type: "uint256" },
  ],
} as const;

export interface AttestationMessage {
  intentId: `0x${string}`;
  fillValid: boolean;
  fillTxHash: `0x${string}`;
  destinationChainId: bigint;
}

function attestationDomain(disputesAddress: `0x${string}`, chainId: number) {
  return {
    name: "GauloiDisputes",
    version: "1",
    chainId,
    verifyingContract: disputesAddress,
  } as const;
}

/**
 * Sign a fill attestation using EIP-712 typed data.
 * Domain includes chainId + verifyingContract to match SignatureLib.sol.
 */
export async function signAttestation(
  walletClient: WalletClient<Transport, Chain, PrivateKeyAccount>,
  attestation: AttestationMessage,
  disputesAddress: `0x${string}`,
  chainId: number,
): Promise<`0x${string}`> {
  return walletClient.signTypedData({
    domain: attestationDomain(disputesAddress, chainId),
    types: ATTESTATION_TYPES,
    primaryType: "FillAttestation",
    message: {
      intentId: attestation.intentId,
      fillValid: attestation.fillValid,
      fillTxHash: attestation.fillTxHash,
      destinationChainId: attestation.destinationChainId,
    },
  });
}

/**
 * Verify an attestation signature recovers to the expected signer address.
 */
export async function verifyAttestationSignature(
  attestation: AttestationMessage,
  signature: `0x${string}`,
  expectedSigner: `0x${string}`,
  disputesAddress: `0x${string}`,
  chainId: number,
): Promise<boolean> {
  try {
    return await verifyTypedData({
      address: expectedSigner,
      domain: attestationDomain(disputesAddress, chainId),
      types: ATTESTATION_TYPES,
      primaryType: "FillAttestation",
      message: {
        intentId: attestation.intentId,
        fillValid: attestation.fillValid,
        fillTxHash: attestation.fillTxHash,
        destinationChainId: attestation.destinationChainId,
      },
      signature,
    });
  } catch {
    return false;
  }
}
