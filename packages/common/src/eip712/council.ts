import {
  type WalletClient,
  type Transport,
  type Chain,
  verifyTypedData,
  encodeAbiParameters,
} from "viem";
import { type PrivateKeyAccount } from "viem/accounts";

export const ZERO_BYTES32 = "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`;

// EIP-712 types for council verdicts — matches CouncilResolver.VERDICT_TYPEHASH
export const COUNCIL_VERDICT_TYPES = {
  CouncilVerdict: [
    { name: "intentId", type: "bytes32" },
    { name: "fillValid", type: "bool" },
    { name: "destinationChainId", type: "uint256" },
  ],
} as const;

export interface CouncilVerdictMessage {
  intentId: `0x${string}`;
  fillValid: boolean;
  destinationChainId: bigint;
}

function councilDomain(councilAddress: `0x${string}`, chainId: number) {
  return {
    name: "GauloiCouncil",
    version: "1",
    chainId,
    verifyingContract: councilAddress,
  } as const;
}

/**
 * Sign a council verdict using EIP-712 typed data.
 * Domain matches SignatureLib.buildDomainSeparator("GauloiCouncil", council).
 */
export async function signCouncilVerdict(
  walletClient: WalletClient<Transport, Chain, PrivateKeyAccount>,
  verdict: CouncilVerdictMessage,
  councilAddress: `0x${string}`,
  chainId: number,
): Promise<`0x${string}`> {
  return walletClient.signTypedData({
    domain: councilDomain(councilAddress, chainId),
    types: COUNCIL_VERDICT_TYPES,
    primaryType: "CouncilVerdict",
    message: verdict,
  });
}

export async function verifyCouncilVerdictSignature(
  verdict: CouncilVerdictMessage,
  signature: `0x${string}`,
  expectedSigner: `0x${string}`,
  councilAddress: `0x${string}`,
  chainId: number,
): Promise<boolean> {
  try {
    return await verifyTypedData({
      address: expectedSigner,
      domain: councilDomain(councilAddress, chainId),
      types: COUNCIL_VERDICT_TYPES,
      primaryType: "CouncilVerdict",
      message: verdict,
      signature,
    });
  } catch {
    return false;
  }
}

/**
 * Encode council evidence for GauloiDisputes.resolve():
 * abi.encode(bool fillValid, bytes[] signatures).
 * Signatures must be sorted by ascending signer address.
 */
export function encodeCouncilEvidence(
  fillValid: boolean,
  signatures: `0x${string}`[],
): `0x${string}` {
  return encodeAbiParameters(
    [{ type: "bool" }, { type: "bytes[]" }],
    [fillValid, signatures],
  );
}
