import type {
  IntentBroadcastMessage,
  MakerQuoteMessage,
} from "../types.js";

export interface StoredIntent {
  intent: IntentBroadcastMessage["data"];
  quotes: Map<string, MakerQuoteMessage["data"]>; // maker address → quote
  selectedMaker: string | null;
  createdAt: number;
}

export class MemoryStore {
  private intents = new Map<string, StoredIntent>();

  addIntent(data: IntentBroadcastMessage["data"]): StoredIntent {
    const stored: StoredIntent = {
      intent: data,
      quotes: new Map(),
      selectedMaker: null,
      createdAt: Date.now(),
    };
    this.intents.set(data.intentId, stored);
    return stored;
  }

  getIntent(intentId: string): StoredIntent | undefined {
    return this.intents.get(intentId);
  }

  addQuote(intentId: string, quote: MakerQuoteMessage["data"]): boolean {
    const stored = this.intents.get(intentId);
    if (!stored) return false;
    if (stored.selectedMaker) return false; // already selected
    stored.quotes.set(quote.maker, quote);
    return true;
  }

  selectQuote(intentId: string, maker: string): boolean {
    const stored = this.intents.get(intentId);
    if (!stored) return false;
    if (!stored.quotes.has(maker)) return false;
    if (stored.selectedMaker) return false;
    stored.selectedMaker = maker;
    return true;
  }

  getOpenIntents(): StoredIntent[] {
    return Array.from(this.intents.values()).filter(
      (s) => !s.selectedMaker && s.intent.expiry > Date.now() / 1000,
    );
  }

  getIntentStats(): { total: number; open: number; filled: number; volume: string } {
    let total = 0;
    let open = 0;
    let filled = 0;
    let volume = 0n;

    const now = Date.now() / 1000;
    for (const stored of this.intents.values()) {
      total++;
      volume += BigInt(stored.intent.inputAmount);
      if (stored.selectedMaker) {
        filled++;
      } else if (stored.intent.expiry > now) {
        open++;
      }
    }

    return { total, open, filled, volume: volume.toString() };
  }

  // Clean up expired intents periodically
  pruneExpired(): number {
    const now = Date.now() / 1000;
    let pruned = 0;
    for (const [id, stored] of this.intents) {
      if (stored.intent.expiry < now) {
        this.intents.delete(id);
        pruned++;
      }
    }
    return pruned;
  }
}
