import { describe, it, expect, vi, beforeEach } from "vitest";
import { Settler } from "./settler.js";
import type { Order } from "@gauloi/common";

// --- helpers ---

function makeOrder(overrides: Partial<Order> = {}): Order {
  return {
    taker: "0x1111111111111111111111111111111111111111",
    inputToken: "0x2222222222222222222222222222222222222222",
    inputAmount: 1_000_000n,
    outputToken: "0x3333333333333333333333333333333333333333",
    minOutputAmount: 990_000n,
    destinationChainId: 421614n,
    destinationAddress: "0x1111111111111111111111111111111111111111",
    expiry: BigInt(Math.floor(Date.now() / 1000) + 3600),
    nonce: 1n,
    ...overrides,
  };
}

/** Build a mock commitment return value matching the contract struct */
function makeCommitment(state: number, disputeWindowEnd: number) {
  return {
    taker: "0x1111111111111111111111111111111111111111" as `0x${string}`,
    state,
    maker: "0x4444444444444444444444444444444444444444" as `0x${string}`,
    commitmentDeadline: 0,
    disputeWindowEnd,
    fillTxHash: "0xabcd" as `0x${string}`,
  };
}

function createMockClients(readContractFn: (...args: any[]) => any) {
  const publicClient = {
    readContract: vi.fn(readContractFn),
    waitForTransactionReceipt: vi.fn().mockResolvedValue({}),
  } as any;

  const walletClient = {
    writeContract: vi.fn().mockResolvedValue("0xtxhash"),
  } as any;

  return { publicClient, walletClient };
}

const ESCROW = "0xESCROW0000000000000000000000000000000000" as `0x${string}`;

// --- tests ---

describe("Settler", () => {
  describe("trySettle", () => {
    it("returns null when no pending intents", async () => {
      const { publicClient, walletClient } = createMockClients(() => ({}));
      const settler = new Settler(publicClient, walletClient, ESCROW, 3600);

      const result = await settler.trySettle();
      expect(result).toBeNull();
    });

    it("settles matured intents (state=Filled, past dispute window)", async () => {
      const pastTimestamp = Math.floor(Date.now() / 1000) - 100;
      const { publicClient, walletClient } = createMockClients(() =>
        makeCommitment(1, pastTimestamp),
      );

      const settler = new Settler(publicClient, walletClient, ESCROW, 3600);
      const order = makeOrder();
      settler.trackFill("0xINTENT1" as `0x${string}`, pastTimestamp, order);

      const hash = await settler.trySettle();

      expect(hash).toBe("0xtxhash");
      expect(walletClient.writeContract).toHaveBeenCalledWith({
        address: ESCROW,
        abi: expect.any(Array),
        functionName: "settleBatch",
        args: [[order]],
      });
    });

    it("does not settle intents still within dispute window", async () => {
      const futureTimestamp = Math.floor(Date.now() / 1000) + 3600;
      const { publicClient, walletClient } = createMockClients(() =>
        makeCommitment(1, futureTimestamp),
      );

      const settler = new Settler(publicClient, walletClient, ESCROW, 3600);
      settler.trackFill("0xINTENT1" as `0x${string}`, futureTimestamp, makeOrder());

      const result = await settler.trySettle();

      expect(result).toBeNull();
      expect(walletClient.writeContract).not.toHaveBeenCalled();
    });

    it("removes settled intents (state=2) from tracking", async () => {
      const { publicClient, walletClient } = createMockClients(() =>
        makeCommitment(2, 0), // Settled
      );

      const settler = new Settler(publicClient, walletClient, ESCROW, 3600);
      settler.trackFill("0xINTENT1" as `0x${string}`, 0, makeOrder());

      await settler.trySettle();

      // Should have been removed — second call should return null immediately
      expect(await settler.trySettle()).toBeNull();
      // readContract should only be called once (first trySettle), not twice
      expect(publicClient.readContract).toHaveBeenCalledTimes(1);
    });

    it("removes disputed intents (state=3) from tracking", async () => {
      const { publicClient, walletClient } = createMockClients(() =>
        makeCommitment(3, 0), // Disputed
      );

      const settler = new Settler(publicClient, walletClient, ESCROW, 3600);
      settler.trackFill("0xINTENT1" as `0x${string}`, 0, makeOrder());

      await settler.trySettle();

      // Should have been removed — second call should return null immediately
      expect(await settler.trySettle()).toBeNull();
      expect(publicClient.readContract).toHaveBeenCalledTimes(1);
    });

    it("removes expired intents (state=4) from tracking", async () => {
      const { publicClient, walletClient } = createMockClients(() =>
        makeCommitment(4, 0), // Expired
      );

      const settler = new Settler(publicClient, walletClient, ESCROW, 3600);
      settler.trackFill("0xINTENT1" as `0x${string}`, 0, makeOrder());

      await settler.trySettle();

      // Should have been removed — second call should return null immediately
      expect(await settler.trySettle()).toBeNull();
      expect(publicClient.readContract).toHaveBeenCalledTimes(1);
    });

    it("keeps committed intents (state=0) in tracking", async () => {
      const { publicClient, walletClient } = createMockClients(() =>
        makeCommitment(0, 0), // Committed — not terminal
      );

      const settler = new Settler(publicClient, walletClient, ESCROW, 3600);
      settler.trackFill("0xINTENT1" as `0x${string}`, 0, makeOrder());

      await settler.trySettle();

      // Should NOT have been removed — second call should read contract again
      await settler.trySettle();
      expect(publicClient.readContract).toHaveBeenCalledTimes(2);
    });

    it("handles mixed intent states in a single batch", async () => {
      const pastTimestamp = Math.floor(Date.now() / 1000) - 100;
      const futureTimestamp = Math.floor(Date.now() / 1000) + 3600;

      const commitments: Record<string, any> = {
        "0xMATURED": makeCommitment(1, pastTimestamp),   // Filled, past window → settle
        "0xPENDING": makeCommitment(1, futureTimestamp), // Filled, future window → skip
        "0xDISPUTED": makeCommitment(3, 0),              // Disputed → remove
        "0xSETTLED": makeCommitment(2, 0),               // Settled → remove
      };

      const { publicClient, walletClient } = createMockClients(
        ({ args }: { args: [string] }) => commitments[args[0]],
      );

      const settler = new Settler(publicClient, walletClient, ESCROW, 3600);
      const maturedOrder = makeOrder({ nonce: 1n });
      settler.trackFill("0xMATURED" as `0x${string}`, pastTimestamp, maturedOrder);
      settler.trackFill("0xPENDING" as `0x${string}`, futureTimestamp, makeOrder({ nonce: 2n }));
      settler.trackFill("0xDISPUTED" as `0x${string}`, 0, makeOrder({ nonce: 3n }));
      settler.trackFill("0xSETTLED" as `0x${string}`, 0, makeOrder({ nonce: 4n }));

      const hash = await settler.trySettle();

      // Should settle only the matured intent
      expect(hash).toBe("0xtxhash");
      expect(walletClient.writeContract).toHaveBeenCalledWith(
        expect.objectContaining({
          functionName: "settleBatch",
          args: [[maturedOrder]],
        }),
      );

      // After trySettle: MATURED removed (settled), DISPUTED removed, SETTLED removed
      // Only PENDING should remain
      publicClient.readContract.mockClear();
      walletClient.writeContract.mockClear();

      await settler.trySettle();
      // Only PENDING should be checked
      expect(publicClient.readContract).toHaveBeenCalledTimes(1);
    });

    it("skips intents that throw on readContract (RPC error)", async () => {
      const pastTimestamp = Math.floor(Date.now() / 1000) - 100;
      let callCount = 0;

      const { publicClient, walletClient } = createMockClients(() => {
        callCount++;
        if (callCount === 1) throw new Error("RPC error");
        return makeCommitment(1, pastTimestamp);
      });

      const settler = new Settler(publicClient, walletClient, ESCROW, 3600);
      settler.trackFill("0xERROR" as `0x${string}`, 0, makeOrder({ nonce: 1n }));
      settler.trackFill("0xOK" as `0x${string}`, pastTimestamp, makeOrder({ nonce: 2n }));

      const hash = await settler.trySettle();

      // Should still settle the successful one
      expect(hash).toBe("0xtxhash");
    });
  });

  describe("start/stop", () => {
    it("runs trySettle periodically and can be stopped", async () => {
      vi.useFakeTimers();

      const { publicClient, walletClient } = createMockClients(() =>
        makeCommitment(2, 0),
      );

      const settler = new Settler(publicClient, walletClient, ESCROW, 3600);
      const spy = vi.spyOn(settler, "trySettle").mockResolvedValue(null);

      settler.start(1000);

      // Advance past one interval
      await vi.advanceTimersByTimeAsync(1000);
      expect(spy).toHaveBeenCalledTimes(1);

      await vi.advanceTimersByTimeAsync(1000);
      expect(spy).toHaveBeenCalledTimes(2);

      settler.stop();

      await vi.advanceTimersByTimeAsync(2000);
      // Should not have been called again after stop
      expect(spy).toHaveBeenCalledTimes(2);

      vi.useRealTimers();
    });
  });
});
