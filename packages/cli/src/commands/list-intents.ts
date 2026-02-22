interface ListIntentsOptions {
  relay: string;
}

export async function listIntents(options: ListIntentsOptions): Promise<void> {
  const url = `${options.relay}/intents`;

  try {
    const res = await fetch(url);
    if (!res.ok) {
      console.error(`Relay returned ${res.status}: ${await res.text()}`);
      process.exit(1);
    }

    const intents = await res.json() as any[];

    if (intents.length === 0) {
      console.log("No open intents.");
      return;
    }

    console.log(`${intents.length} open intent(s):\n`);

    for (const intent of intents) {
      console.log(`Intent: ${intent.intentId}`);
      console.log(`  Taker:        ${intent.taker}`);
      console.log(`  Input:        ${intent.inputAmount} of ${intent.inputToken}`);
      console.log(`  Output:       min ${intent.minOutputAmount} of ${intent.outputToken}`);
      console.log(`  Dest chain:   ${intent.destinationChainId}`);
      console.log(`  Dest address: ${intent.destinationAddress}`);
      console.log(`  Expiry:       ${new Date(intent.expiry * 1000).toISOString()}`);
      console.log(`  Quotes:       ${intent.quoteCount}`);
      if (intent.selectedMaker) {
        console.log(`  Selected:     ${intent.selectedMaker}`);
      }
      console.log();
    }
  } catch (err: any) {
    console.error(`Failed to connect to relay at ${url}: ${err.message}`);
    process.exit(1);
  }
}
