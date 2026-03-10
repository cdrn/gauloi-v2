import { describe, it, expect } from "vitest";
import { createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import {
  signAttestation,
  verifyAttestationSignature,
  type AttestationMessage,
} from "./attestation.js";

const DISPUTES = "0xcccccccccccccccccccccccccccccccccccccccc" as `0x${string}`;
const CHAIN_ID = 11155111; // Sepolia

const TEST_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as `0x${string}`;
const account = privateKeyToAccount(TEST_KEY);

const walletClient = createWalletClient({
  account,
  chain: sepolia,
  transport: http(),
});

const attestation: AttestationMessage = {
  intentId: "0x1111111111111111111111111111111111111111111111111111111111111111",
  fillValid: true,
  fillTxHash: "0x2222222222222222222222222222222222222222222222222222222222222222",
  destinationChainId: 421614n,
};

describe("signAttestation / verifyAttestationSignature", () => {
  it("sign + verify round-trip succeeds", async () => {
    const sig = await signAttestation(
      walletClient as any,
      attestation,
      DISPUTES,
      CHAIN_ID,
    );

    const valid = await verifyAttestationSignature(
      attestation,
      sig,
      account.address,
      DISPUTES,
      CHAIN_ID,
    );

    expect(valid).toBe(true);
  });

  it("verify fails for wrong signer", async () => {
    const sig = await signAttestation(
      walletClient as any,
      attestation,
      DISPUTES,
      CHAIN_ID,
    );

    const wrongSigner = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" as `0x${string}`;
    const valid = await verifyAttestationSignature(
      attestation,
      sig,
      wrongSigner,
      DISPUTES,
      CHAIN_ID,
    );

    expect(valid).toBe(false);
  });

  it("verify fails for wrong intentId", async () => {
    const sig = await signAttestation(
      walletClient as any,
      attestation,
      DISPUTES,
      CHAIN_ID,
    );

    const tampered: AttestationMessage = {
      ...attestation,
      intentId: "0x3333333333333333333333333333333333333333333333333333333333333333",
    };

    const valid = await verifyAttestationSignature(
      tampered,
      sig,
      account.address,
      DISPUTES,
      CHAIN_ID,
    );

    expect(valid).toBe(false);
  });

  it("verify fails for wrong fillValid", async () => {
    const sig = await signAttestation(
      walletClient as any,
      attestation,
      DISPUTES,
      CHAIN_ID,
    );

    const tampered: AttestationMessage = {
      ...attestation,
      fillValid: false,
    };

    const valid = await verifyAttestationSignature(
      tampered,
      sig,
      account.address,
      DISPUTES,
      CHAIN_ID,
    );

    expect(valid).toBe(false);
  });

  it("verify fails for wrong disputes address (different domain)", async () => {
    const sig = await signAttestation(
      walletClient as any,
      attestation,
      DISPUTES,
      CHAIN_ID,
    );

    const wrongDisputes = "0xdddddddddddddddddddddddddddddddddddddd" as `0x${string}`;
    const valid = await verifyAttestationSignature(
      attestation,
      sig,
      account.address,
      wrongDisputes,
      CHAIN_ID,
    );

    expect(valid).toBe(false);
  });
});
