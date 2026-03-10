import WebSocket from "ws";
import {
  type PublicClient,
  type WalletClient,
  type Transport,
  type Chain,
} from "viem";
import { type PrivateKeyAccount } from "viem/accounts";
import {
  type ChainConfig,
  type Order,
  GauloiStakingAbi,
  signQuote,
} from "@gauloi/common";
import { ComplianceScreener, AllowlistScreener } from "./compliance/screener.js";
import { Quoter, type QuoterConfig } from "./pricing/quoter.js";
import { Filler } from "./chain/filler.js";
import { Settler } from "./chain/settler.js";
import { ChainWatcher } from "./chain/watcher.js";
import { DisputeWatcher } from "./dispute/watcher.js";
import { DisputeResponder } from "./dispute/responder.js";

// Re-use relay message types
enum MessageType {
  MakerSubscribe = "maker_subscribe",
  MakerQuote = "maker_quote",
  NewIntent = "new_intent",
  QuoteAccepted = "quote_accepted",
  Error = "error",
}

export interface BotConfig {
  makerAddress: `0x${string}`;
  relayUrl: string;
  sourceChain: ChainConfig;
  destChain: ChainConfig;
  sourcePublicClient: PublicClient<Transport, Chain>;
  sourceWalletClient: WalletClient<Transport, Chain, PrivateKeyAccount>;
  destPublicClient: PublicClient<Transport, Chain>;
  destWalletClient: WalletClient<Transport, Chain, PrivateKeyAccount>;
  screener?: ComplianceScreener;
  quoterConfig?: Partial<QuoterConfig>;
  settleIntervalMs?: number;
  disputeOnly?: boolean;
}

export class MakerBot {
  private ws: WebSocket | null = null;
  private screener: ComplianceScreener;
  private quoter: Quoter;
  private filler: Filler;
  private settler: Settler;
  private chainWatcher: ChainWatcher;
  private disputeWatcher: DisputeWatcher;
  private disputeResponder: DisputeResponder;
  private config: BotConfig;
  private running = false;
  private cachedCapacity: bigint = 0n;
  private capacityLastFetched = 0;
  // Local pending exposure tracking — prevents over-quoting between on-chain confirmations
  private pendingExposure: Map<string, { amount: bigint; expiresAt: number }> =
    new Map();
  // Cache orders by intentId for fill verification and dispute submission
  private orderCache = new Map<string, Order>();

  constructor(config: BotConfig) {
    this.config = config;
    this.screener = config.screener ?? new AllowlistScreener();
    this.quoter = new Quoter(config.quoterConfig);

    this.filler = new Filler(
      config.sourcePublicClient,
      config.sourceWalletClient,
      config.destPublicClient,
      config.destWalletClient,
      config.sourceChain.escrowAddress,
    );

    this.settler = new Settler(
      config.sourcePublicClient,
      config.sourceWalletClient,
      config.sourceChain.escrowAddress,
      config.sourceChain.settlementWindow,
    );

    this.chainWatcher = new ChainWatcher(
      config.sourcePublicClient,
      config.sourceChain.escrowAddress,
    );

    this.disputeWatcher = new DisputeWatcher(
      config.destPublicClient,
      config.sourceWalletClient,
      config.sourceChain.disputesAddress,
      config.makerAddress,
    );

    this.disputeResponder = new DisputeResponder(
      config.sourcePublicClient,
      config.sourceWalletClient,
      config.destPublicClient,
      config.sourceChain.disputesAddress,
      config.sourceChain.escrowAddress,
      config.makerAddress,
      config.sourceChain.chainId,
    );
  }

  async start(): Promise<void> {
    this.running = true;

    // Always start dispute responder (attestation + finalization)
    this.disputeResponder.start(this.config.settleIntervalMs ?? 60_000);

    if (!this.config.disputeOnly) {
      // Full maker mode: relay + settler + fill watching
      this.connectRelay();

      this.settler.start(this.config.settleIntervalMs ?? 60_000);

      this.chainWatcher.watchFills(async (event) => {
        const order = this.orderCache.get(event.intentId);
        const valid = await this.disputeWatcher.verifyFill(event, order);
        if (!valid) {
          console.log(`Invalid fill detected: ${event.intentId}`);
          await this.disputeWatcher.dispute(event.intentId, order);
        }
      });
    }

    const mode = this.config.disputeOnly ? "dispute-only" : "full";
    console.log(`Maker bot started (${mode}): ${this.config.makerAddress}`);
  }

  stop(): void {
    this.running = false;
    this.disputeResponder.stop();
    this.ws?.close();
    this.settler.stop();
    this.chainWatcher.stop();
    console.log("Maker bot stopped");
  }

  private connectRelay(): void {
    this.ws = new WebSocket(this.config.relayUrl);

    this.ws.on("open", () => {
      console.log("Connected to relay");
      this.ws!.send(
        JSON.stringify({
          type: MessageType.MakerSubscribe,
          data: {
            address: this.config.makerAddress,
            chains: [this.config.sourceChain.chainId, this.config.destChain.chainId],
          },
        }),
      );
      // Backfill: fetch open intents we may have missed
      this.fetchOpenIntents().catch(() => {});
    });

    this.ws.on("message", (raw) => {
      try {
        const msg = JSON.parse(raw.toString());
        this.handleRelayMessage(msg);
      } catch (err) {
        console.error("Failed to parse relay message:", err);
      }
    });

    this.ws.on("close", () => {
      if (this.running) {
        console.log("Relay connection lost, reconnecting in 5s...");
        setTimeout(() => this.connectRelay(), 5000);
      }
    });

    this.ws.on("error", (err) => {
      console.error("Relay WebSocket error:", err);
    });
  }

  private async handleRelayMessage(msg: any): Promise<void> {
    switch (msg.type) {
      case MessageType.NewIntent:
        await this.handleNewIntent(msg.data);
        break;

      case MessageType.QuoteAccepted:
        await this.handleQuoteAccepted(msg.data);
        break;

      case MessageType.Error:
        console.error("Relay error:", msg.data.message);
        break;
    }
  }

  private async fetchOpenIntents(): Promise<void> {
    const httpUrl = this.config.relayUrl
      .replace("wss://", "https://")
      .replace("ws://", "http://");
    try {
      const res = await fetch(`${httpUrl}/intents`);
      if (!res.ok) return;
      const intents = await res.json() as any[];
      const open = intents.filter((i: any) => !i.selectedMaker);
      if (open.length > 0) {
        console.log(`Backfilling ${open.length} open intent(s)...`);
      }
      for (const intent of open) {
        await this.handleNewIntent(intent);
      }
    } catch {
      // Non-fatal — we'll still get new intents via WebSocket
    }
  }

  private getTotalPendingExposure(): bigint {
    const now = Math.floor(Date.now() / 1000);
    let total = 0n;
    for (const [id, entry] of this.pendingExposure) {
      if (entry.expiresAt <= now) {
        this.pendingExposure.delete(id);
      } else {
        total += entry.amount;
      }
    }
    return total;
  }

  private async getCapacity(): Promise<bigint> {
    const now = Date.now();
    if (now - this.capacityLastFetched < 15_000) {
      return this.cachedCapacity;
    }
    const capacity = await this.config.sourcePublicClient.readContract({
      address: this.config.sourceChain.stakingAddress,
      abi: GauloiStakingAbi,
      functionName: "availableCapacity",
      args: [this.config.makerAddress],
    });
    this.cachedCapacity = capacity;
    this.capacityLastFetched = now;
    return capacity;
  }

  private async handleNewIntent(data: any): Promise<void> {
    const { intentId, taker, inputAmount, destinationChainId } = data;

    // Check if this intent is for our destination chain
    if (destinationChainId !== this.config.destChain.chainId) {
      return;
    }

    // Screen the taker
    const screenResult = await this.screener.screen(
      taker,
      data.sourceChainId,
    );

    if (!screenResult.allowed) {
      console.log(`Rejected intent ${intentId}: ${screenResult.reason}`);
      return;
    }

    // Calculate quote
    const outputAmount = this.quoter.calculateOutputAmount(
      BigInt(inputAmount),
      screenResult.riskTier,
    );

    if (outputAmount === null) {
      console.log(`Cannot quote intent ${intentId}: exceeds limits or flagged`);
      return;
    }

    // Check available capacity accounting for pending (not-yet-on-chain) fills
    const amount = BigInt(inputAmount);
    try {
      const onChainCapacity = await this.getCapacity();
      const pending = this.getTotalPendingExposure();
      const effectiveCapacity =
        onChainCapacity > pending ? onChainCapacity - pending : 0n;

      console.log(
        `Capacity check for ${intentId}: onChain=${onChainCapacity} pending=${pending} effective=${effectiveCapacity} required=${amount}`,
      );

      if (effectiveCapacity < amount) {
        console.log(`Insufficient capacity for intent ${intentId}`);
        return;
      }
    } catch {
      console.error("Failed to check capacity");
      return;
    }

    // Submit quote to relay
    const quoteExpiry = Math.floor(Date.now() / 1000) + 300; // 5 min

    // Reserve capacity before yielding — prevents concurrent intents from
    // both passing the capacity check before either reservation is recorded
    this.pendingExposure.set(intentId, { amount, expiresAt: quoteExpiry });

    const quoteMsg = {
      intentId: intentId as `0x${string}`,
      maker: this.config.makerAddress,
      outputAmount,
      estimatedFillTime: 30,
      expiry: quoteExpiry,
    };

    let signature: `0x${string}`;
    try {
      signature = await signQuote(this.config.sourceWalletClient, quoteMsg);
    } catch (err) {
      this.pendingExposure.delete(intentId);
      console.error(`Failed to sign quote for intent ${intentId}:`, err);
      return;
    }

    console.log(
      `Quoting intent ${intentId}: ${outputAmount} (${screenResult.riskTier})`,
    );

    this.ws?.send(
      JSON.stringify({
        type: MessageType.MakerQuote,
        data: {
          intentId,
          maker: this.config.makerAddress,
          outputAmount: outputAmount.toString(),
          estimatedFillTime: 30,
          expiry: quoteExpiry,
          signature,
        },
      }),
    );
  }

  private async handleQuoteAccepted(data: any): Promise<void> {
    const {
      intentId,
      taker,
      inputToken,
      inputAmount,
      outputToken,
      minOutputAmount,
      destinationChainId,
      destinationAddress,
      nonce,
      takerSignature,
    } = data;

    // Only handle if this intent's source chain matches our source chain
    if (data.sourceChainId && data.sourceChainId !== this.config.sourceChain.chainId) {
      return;
    }

    console.log(`Quote accepted for intent ${intentId}, executing order...`);

    try {
      // Build the Order struct for executeOrder
      const order: Order = {
        taker: taker as `0x${string}`,
        inputToken: inputToken as `0x${string}`,
        inputAmount: BigInt(inputAmount),
        outputToken: outputToken as `0x${string}`,
        minOutputAmount: BigInt(minOutputAmount),
        destinationChainId: BigInt(destinationChainId),
        destinationAddress: destinationAddress as `0x${string}`,
        expiry: BigInt(data.expiry),
        nonce: BigInt(nonce),
      };

      // Cache order for fill verification and dispute submission
      this.orderCache.set(intentId, order);

      // 1. Execute order on source chain (replaces commitToIntent)
      console.log("Executing order on source chain...");
      await this.filler.executeOrder(order, takerSignature as `0x${string}`);

      // On-chain exposure now tracks this fill — release local reservation
      // and invalidate cache so next capacity check is fresh
      this.pendingExposure.delete(intentId);
      this.capacityLastFetched = 0;

      // 2. Fill on destination chain
      console.log("Filling on destination chain...");
      const fillTxHash = await this.filler.fillOnDestination(
        outputToken as `0x${string}`,
        destinationAddress as `0x${string}`,
        BigInt(minOutputAmount), // Fill at minimum — spread is our profit
      );

      // 3. Submit fill evidence on source chain
      console.log("Submitting fill evidence...");
      await this.filler.submitFill(
        intentId as `0x${string}`,
        fillTxHash,
      );

      // 4. Track for settlement
      const disputeWindowEnd =
        Math.floor(Date.now() / 1000) +
        this.config.sourceChain.settlementWindow;
      this.settler.trackFill(intentId as `0x${string}`, disputeWindowEnd, order);

      console.log(`Fill complete for intent ${intentId}: ${fillTxHash}`);
    } catch (err) {
      // Release local reservation on failure
      this.pendingExposure.delete(intentId);
      this.orderCache.delete(intentId);
      this.capacityLastFetched = 0;
      console.error(`Fill failed for intent ${intentId}:`, err);
    }
  }
}
