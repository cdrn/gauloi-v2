import { describe, it, expect } from "vitest";
import { createWalletClient, http, decodeAbiParameters } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import {
  signCouncilVerdict,
  verifyCouncilVerdictSignature,
  encodeCouncilEvidence,
} from "./council.js";

const KEY = "0x0000000000000000000000000000000000000000000000000000000000c0de01" as const;
const COUNCIL = "0x1111111111111111111111111111111111111111" as const;
const INTENT_ID = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as const;

describe("council verdict signing", () => {
  const account = privateKeyToAccount(KEY);
  const wallet = createWalletClient({ account, chain: sepolia, transport: http("http://localhost") });

  it("signs and verifies a verdict", async () => {
    const verdict = { intentId: INTENT_ID, fillValid: true, destinationChainId: 421614n };
    const sig = await signCouncilVerdict(wallet, verdict, COUNCIL, sepolia.id);

    expect(await verifyCouncilVerdictSignature(verdict, sig, account.address, COUNCIL, sepolia.id)).toBe(true);
    // Wrong verdict does not verify
    expect(
      await verifyCouncilVerdictSignature(
        { ...verdict, fillValid: false }, sig, account.address, COUNCIL, sepolia.id,
      ),
    ).toBe(false);
  });

  it("encodes evidence as (bool, bytes[])", async () => {
    const sig = await signCouncilVerdict(
      wallet,
      { intentId: INTENT_ID, fillValid: false, destinationChainId: 421614n },
      COUNCIL,
      sepolia.id,
    );
    const evidence = encodeCouncilEvidence(false, [sig]);
    const [fillValid, sigs] = decodeAbiParameters(
      [{ type: "bool" }, { type: "bytes[]" }],
      evidence,
    );
    expect(fillValid).toBe(false);
    expect(sigs).toEqual([sig]);
  });
});
