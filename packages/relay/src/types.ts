// Relay message types — shared between relay, maker, and taker clients

export enum MessageType {
  // Taker → Relay
  IntentBroadcast = "intent_broadcast",
  QuoteSelect = "quote_select",

  // Maker → Relay
  MakerQuote = "maker_quote",
  MakerSubscribe = "maker_subscribe",

  // Relay → Makers
  NewIntent = "new_intent",
  QuoteAccepted = "quote_accepted",

  // Relay → Taker
  QuoteReceived = "quote_received",

  // Relay → All
  Error = "error",
}

export interface IntentBroadcastMessage {
  type: MessageType.IntentBroadcast;
  data: {
    intentId: string;
    taker: string;
    inputToken: string;
    inputAmount: string; // bigint as string for serialization
    outputToken: string;
    destinationChainId: number;
    destinationAddress: string;
    minOutputAmount: string;
    expiry: number;
    nonce: string; // bigint as string
    takerSignature: string;
    sourceChainId: number;
  };
}

export interface MakerQuoteMessage {
  type: MessageType.MakerQuote;
  data: {
    intentId: string;
    maker: string;
    outputAmount: string;
    estimatedFillTime: number; // seconds
    expiry: number; // unix timestamp
    signature: string;
  };
}

export interface QuoteSelectMessage {
  type: MessageType.QuoteSelect;
  data: {
    intentId: string;
    maker: string; // selected maker address
  };
}

export interface NewIntentMessage {
  type: MessageType.NewIntent;
  data: Omit<IntentBroadcastMessage["data"], "takerSignature" | "nonce">;
}

export interface QuoteReceivedMessage {
  type: MessageType.QuoteReceived;
  data: MakerQuoteMessage["data"];
}

export interface QuoteAcceptedMessage {
  type: MessageType.QuoteAccepted;
  data: {
    intentId: string;
    taker: string;
    inputToken: string;
    inputAmount: string;
    outputToken: string;
    destinationChainId: number;
    destinationAddress: string;
    minOutputAmount: string;
    expiry: number;
    nonce: string;
    takerSignature: string;
    sourceChainId: number;
  };
}

export interface MakerSubscribeMessage {
  type: MessageType.MakerSubscribe;
  data: {
    address: string;
  };
}

export interface ErrorMessage {
  type: MessageType.Error;
  data: {
    message: string;
    intentId?: string;
  };
}

export type RelayMessage =
  | IntentBroadcastMessage
  | MakerQuoteMessage
  | QuoteSelectMessage
  | MakerSubscribeMessage
  | NewIntentMessage
  | QuoteReceivedMessage
  | QuoteAcceptedMessage
  | ErrorMessage;
