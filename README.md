# gauloi-v2
Cross chain stablecoin swapping protocol with baked in compliance

## Architecture

Intent-based cross-chain settlement. Takers want to move stablecoins between chains. Makers fill those orders and earn a spread. The protocol escrows the taker's funds on the source chain until the maker proves they delivered on the destination chain.

**Three contracts, deployed per chain:**

- **GauloiStaking** — Makers stake USDC to participate. Stake gates participation, limits concurrent fill exposure, and backs dispute attestations. Fraudulent makers lose their entire stake.
- **GauloiEscrow** — Holds taker funds during settlement. Handles the full order lifecycle: execute, fill, settle, reclaim.
- **GauloiDisputes** — Any staked maker can challenge a fill claim by posting a bond. Resolution is M/N attestation signatures from the staked maker set — same security model as optimistic rollups (single honest challenger assumption).

**Settlement flow:**

```
Taker signs EIP-712 order off-chain (0 gas)
         |
         v
Maker calls executeOrder -----> Committed -----> Filled -----> Settled
  (pulls taker tokens,              |                |
   writes 3 storage slots)          |                +---> Disputed
                                    |                        |
                                    v                        +--> Settled (fill valid)
                                 Expired                     +--> Refunded (fill invalid)
                                 (taker reclaims)
```

The taker pays zero gas — they sign an [EIP-712](https://eips.ethereum.org/EIPS/eip-712) typed order off-chain. The maker calls `executeOrder` with the signed order, which verifies the signature, pulls tokens from the taker into escrow, and creates the commitment in a single transaction. Order parameters are never stored on-chain — the `Commitment` struct uses 3 storage slots instead of 9, and the `intentId` is recomputed from calldata wherever needed.

### Settlement lifecycle

1. **Taker signs order** — EIP-712 typed data specifying input token/amount, desired output, destination chain/address, expiry, and a random nonce. Zero gas.
2. **Maker executes order** — Calls `executeOrder` with the signed order. The contract verifies the taker's signature, pulls tokens from the taker into escrow, and records a `Commitment` (3 storage slots: taker+state, maker+deadlines, fillTxHash). The maker now has until the commitment deadline to deliver.
3. **Maker fills on destination chain** — Sends the output token to the taker's destination address on chain B. This is a normal token transfer, no protocol contract needed on the destination.
4. **Maker submits fill evidence** — Calls `submitFill` on chain A with the destination transaction hash. This starts the dispute window.
5. **Dispute window passes** — If nobody challenges, anyone can call `settle` to release the escrowed tokens to the maker.
6. **Taker reclaims on timeout** — If the maker fails to fill before the commitment deadline, the taker calls `reclaimExpired` to get their tokens back.

### Economic incentives

**Makers are honest because fraud costs more than it's worth.** A maker stakes USDC to participate, and their concurrent fill exposure is capped by their stake. Attempting a fraudulent fill (claiming delivery without actually sending tokens) risks their *entire* stake being slashed — not just the fill amount. A maker with 500k staked who tries to steal 100k on a single fill risks the full 500k. The expected value of fraud is `(1-P) * fill - P * stake`, where P (probability of getting caught) approaches 1 because verification is a single RPC call.

**Challengers are incentivized to watch.** Any staked maker can dispute a fill claim by posting a bond. If the fill is fraudulent, the challenger gets rewarded from the slashed stake. Since checking a fill is trivial (does this tx hash exist with the right parameters on chain B?), staked makers can passively monitor every fill at negligible cost. You only need one honest watcher — same security assumption as optimistic rollups.

**Dispute spam is unprofitable.** The dispute bond — `max(0.5% of fill, min bond)` — is forfeited if the fill turns out to be valid. Frivolous disputes cost the attacker real capital with no upside.

**Attestors are the makers themselves.** Resolution uses M/N signatures from the staked maker set. No separate attestor class, no governance token. Makers already have the infrastructure (watching multiple chains), economic alignment (their own fills depend on system integrity), and capital at risk (incorrect attestation = slashing). Stablecoin fill verification is objectively binary — the transaction either exists with the right parameters or it doesn't.

**Pricing is competitive, not algorithmic.** Makers quote spreads via off-chain RFQ, not an AMM curve. Multiple makers see each order and compete on price — the taker picks the best quote. Spreads reflect real costs: gas on the destination chain, capital lockup during the settlement window, finality risk for the specific chain pair, and the maker's own compliance overhead. Stablecoin pairs have tight natural bounds (both sides are ~$1), so there's no impermanent loss and spreads stay in the low single-digit basis points. Makers who misprice get outcompeted; makers who price accurately earn volume.

**Compliance at the maker level.** Makers screen counterparties and price risk into their spread. The protocol doesn't enforce KYC — it provides the settlement infrastructure, and makers operate within their own regulatory framework.

### Stake capacity and oracle integration

A maker's available fill capacity is not simply their staked amount — it's their stake value adjusted by a Chainlink USDC/USD price feed, minus any outstanding fill exposure. The oracle can only *reduce* capacity below 1:1 (if USDC trades below peg), never inflate it above face value. This prevents a depegging stablecoin from creating phantom capacity. If the oracle feed goes stale (beyond a configurable threshold), capacity queries revert and the maker cannot accept new orders until the feed recovers.

### Off-chain RFQ flow

```
Taker                    Relay                    Maker
  |--- broadcast order --->|                        |
  |                        |--- push to makers ---->|
  |                        |<-- quote (spread) -----|
  |<-- deliver quote ------|                        |
  |--- accept quote ------>|                        |
  |                        |--- notify winner ----->|
  |                        |           executeOrder + fill on dest chain
```

The relay is a WebSocket server that connects takers and makers. It broadcasts intents, collects quotes, and notifies the winning maker. The relay is a coordination layer only — it never touches funds and has no privileged access to the contracts. If the relay goes down, makers can still settle directly on-chain.

## Project Structure

```
contracts/          Foundry (Solidity) — GauloiStaking, GauloiEscrow, GauloiDisputes
packages/
  common/           Shared types, ABIs, chain config (single source of truth for addresses)
  relay/            WebSocket relay server — intent broadcast, quote collection
  maker/            Maker bot — auto-quote, fill, settle, dispute response
  cli/              CLI tool for staking, quoting, and admin operations
app/                Next.js frontend — swap UI, stats dashboard, maker management
```

## Getting Started

```shell
pnpm install
pnpm build
```

### Run tests

```shell
cd contracts && forge test      # Solidity unit/integration/gas tests
```

### Local development

```shell
# Terminal 1: relay
cd packages/relay && pnpm dev

# Terminal 2: maker
cd packages/maker && pnpm dev

# Terminal 3: frontend
cd app && pnpm dev
```

Environment variables are configured via `.env.local` files in each package. See `app/.env.example` for the frontend config.

## Testnet Deployments

### Sepolia (Chain ID: 11155111)

| Contract | Address |
|----------|---------|
| USDC (Circle) | [`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`](https://sepolia.etherscan.io/address/0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) |
| GauloiStaking | [`0x140901e3285c01A051b1E904e4f90e2345bC0F3a`](https://sepolia.etherscan.io/address/0x140901e3285c01A051b1E904e4f90e2345bC0F3a) |
| GauloiEscrow | [`0xa32D78ac618B41f5E7Ace535b921f1b06D87118E`](https://sepolia.etherscan.io/address/0xa32D78ac618B41f5E7Ace535b921f1b06D87118E) |
| GauloiDisputes | [`0xb4d5A4ea7D0Ec9A57a07d24f1A51a3Ca7ade526F`](https://sepolia.etherscan.io/address/0xb4d5A4ea7D0Ec9A57a07d24f1A51a3Ca7ade526F) |

### Arbitrum Sepolia (Chain ID: 421614)

| Contract | Address |
|----------|---------|
| USDC (Circle) | [`0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d`](https://sepolia.arbiscan.io/address/0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d) |
| GauloiStaking | [`0x845E14C0473356064b6fA7371635F5FAE8AE62B3`](https://sepolia.arbiscan.io/address/0x845E14C0473356064b6fA7371635F5FAE8AE62B3) |
| GauloiEscrow | [`0x0AE9C298A70f10A217D7b017A7aBF64c9bB52579`](https://sepolia.arbiscan.io/address/0x0AE9C298A70f10A217D7b017A7aBF64c9bB52579) |
| GauloiDisputes | [`0x877042524F713fa191687A70D6142cbF1C3cfec6`](https://sepolia.arbiscan.io/address/0x877042524F713fa191687A70D6142cbF1C3cfec6) |

### Chainlink Price Feeds (USDC/USD)

| Chain | Feed Address |
|-------|-------------|
| Eth Sepolia | [`0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E`](https://sepolia.etherscan.io/address/0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E) |
| Arbitrum Sepolia | [`0x0153002d20B96532C639313c2d54c3dA09109309`](https://sepolia.arbiscan.io/address/0x0153002d20B96532C639313c2d54c3dA09109309) |

### Testnet Parameters

| Parameter | Value |
|-----------|-------|
| Settlement window | 2 minutes |
| Commitment timeout | 2 minutes |
| Min stake | 10 USDC |
| Unstake cooldown | 5 minutes |
| Dispute resolution window | 5 minutes |
| Dispute bond | max(0.5% of fill, 0.1 USDC) |
| Stale price threshold | 24 hours |

## Gas Costs

Measured with `forge snapshot --match-contract GasBenchmark` (Solc 0.8.24, optimizer 200 runs).

| Operation | Gas | Amortised |
|-----------|-----|-----------|
| stake | 125,495 | — |
| requestUnstake | 177,327 | — |
| completeUnstake | 165,823 | — |
| executeOrder | 296,042 | — |
| submitFill | 323,655 | — |
| settle | 296,419 | — |
| settleBatch (5) | 754,394 | 150,879 |
| settleBatch (10) | 1,324,458 | 132,446 |
| reclaimExpired | 265,801 | — |
| dispute | 811,872 | — |
| resolveDispute (1 sig) | 863,755 | — |
| resolveDispute (3 sigs, stake-weighted) | 1,192,166 | — |
| slashPartial (via resolve) | 880,191 | — |
| finalizeExpiredDispute | 751,781 | — |

Run `forge snapshot --match-contract GasBenchmark --diff` to check for regressions.

## Design

See `docs/blog-part1-architecture.md` for the full architecture rationale and `docs/blog-part2-mechanism-design.md` for dispute resolution, bond economics, and settlement window analysis.
