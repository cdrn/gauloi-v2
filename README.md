# gauloi-v2

Cross-chain stablecoin settlement protocol with compliance at the maker level.

The stablecoin space is fragmenting on purpose: every issuer builds silo rails for its own coin, every L2 cuts its own issuance deal. None of them can build the cross-issuer layer, because it requires neutrality between issuers. Gauloi is that layer — intent-based settlement across any stablecoin pair and chain pair, where makers carry compliance and inventory, and the protocol is a neutral escrow-and-adjudication venue whose rules don't move.

## Architecture

Intent-based cross-chain settlement. Takers want to move stablecoins between chains. Makers fill those orders and earn a spread. The protocol escrows the taker's funds on the source chain until the fill on the destination chain is settled or successfully disputed.

**Contracts, deployed per chain:**

- **GauloiStaking** — Makers stake USDC to participate. Stake gates participation, caps concurrent fill exposure, and is the slashable collateral behind every fill claim.
- **GauloiEscrow** — Holds taker funds during settlement. Handles the full order lifecycle: execute, fill, settle, reclaim.
- **GauloiDisputes** — Bonded challenges against fill claims, and their resolution. The resolution mechanism is being redesigned — see [Trust model](#trust-model) and the [v0.2 spec](#v02-spec-provable-settlement) below for what is deployed today versus where this is going.
- **GauloiFillRegistry** *(v0.2, [#53](https://github.com/cdrn/gauloi-v2/issues/53))* — Destination-side registry that makes fills canonical on-chain facts.

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
2. **Maker executes order** — Calls `executeOrder` with the signed order. The contract verifies the taker's signature, pulls tokens from the taker into escrow, and records a `Commitment`. The maker now has until the commitment deadline to deliver.
3. **Maker fills on destination chain** — Sends the output token to the taker's destination address on chain B. In v0.1 this is a bare token transfer; in v0.2 it routes through the `GauloiFillRegistry`, which records the fill keyed by intent ID.
4. **Maker submits fill evidence** — Calls `submitFill` on chain A with the destination transaction hash. This starts the dispute window.
5. **Dispute window passes** — If nobody challenges, anyone can call `settle` to release the escrowed tokens to the maker.
6. **Taker reclaims on timeout** — If the maker fails to fill before the commitment deadline, the taker calls `reclaimExpired` to get their tokens back.

### Economic incentives

**Fraud is unprofitable when detection works.** A maker's concurrent fill exposure is capped by their stake, and a fill judged fraudulent is slashed on a curve: `min(stake, fill × min(15, 2 + 650/fill_in_USDC))` — at least 2× the fill for large fills, up to 15× for small ones, so salami-slicing fraud into tiny fills is punished disproportionately. A maker stealing 100k risks at least 200k of stake.

**Challengers are incentivized to watch.** Disputing a fill claim requires posting a bond; a successful challenge returns the bond plus a share of the slash. Checking a fill is trivial for anyone already watching both chains — which every maker is. In v0.1, one honest challenger is *necessary but not sufficient*: the challenge still has to win a vote (see [Trust model](#trust-model)). In v0.2, one honest challenger is sufficient — a challenged fill with no proof of delivery resolves against the maker.

**Dispute spam is unprofitable.** The dispute bond — `max(0.5% of fill, min bond)` — is forfeited if the fill turns out to be valid, with half of it compensating the wrongly-accused maker.

**Pricing is competitive, not algorithmic.** Makers quote spreads via off-chain RFQ, not an AMM curve. Multiple makers see each order and compete on price — the taker picks the best quote. Spreads reflect real costs: gas on the destination chain, capital lockup during the settlement window, finality risk for the specific chain pair, residual trust in the corridor's adjudication (see the corridor table below), and the maker's own compliance overhead. Stablecoin pairs have tight natural bounds, so spreads stay in the low single-digit basis points on clean corridors.

**Compliance at the maker level.** Makers screen counterparties and price risk into their spread. The protocol doesn't enforce KYC — it provides the settlement infrastructure, and makers operate within their own regulatory framework.

### Stake capacity and oracle integration

A maker's available fill capacity is their stake value adjusted by a Chainlink USDC/USD price feed, minus outstanding fill exposure. The oracle can only *reduce* capacity below 1:1 (if USDC trades below peg), never inflate it above face value. If the feed goes stale beyond a configurable threshold, capacity queries revert and the maker cannot accept new orders until the feed recovers.

## Trust model

Stated plainly, per version — because for a settlement protocol the trust model *is* the product, and it should be checkable against the code.

**v0.1 (deployed today):** disputes are resolved by a stake-weighted vote of staked makers other than the disputed maker and the challenger, with a 30% participation quorum. Attestations carry rewards for the winning side but **no slashing for the losing side** — voting wrong is costless. An unresolved dispute defaults to fill-valid; a dispute that twice fails quorum pauses the escrow and defaults to fill-valid. Only staked makers may challenge. The practical consequences: the mechanism assumes a large, diligent, non-colluding maker set, which does not exist yet; with few makers, quorum is unreachable and every dispute terminates in the fill-valid default. **v0.1 is safe under a single trusted operator — which is what currently runs it — and should not be trusted beyond that.** This is the honest reading of the deployed code, and it is why v0.2 exists.

**v0.2 (spec below):** detection and judgment are separated. Anyone may challenge (bonded). Judgment terminates in a per-corridor **resolver** — an on-chain storage proof where the corridor supports it, a named M-of-N council where it doesn't. A challenged fill with no successful defense resolves **against the maker**. There is no vote.

| Corridor class | Terminal arbiter | Unresolved default | Settlement window |
|---|---|---|---|
| Provable (e.g. fills on Ethereum, escrow on Arbitrum) | Storage proof of the FillRegistry | Challenged + no proof → **invalid**, taker refunded | Shrinks toward destination finality |
| Council (unprovable corridors; bootstrap everywhere) | Named M-of-N EIP-712 council | Challenged + no verdict → **invalid**, taker refunded | Wider; residual trust priced into spread |
| v0.1 vote *(being removed)* | Stake-weighted maker poll | **Valid**, maker paid | Fixed global |

## v0.2 spec: provable settlement

Umbrella issue: [#2](https://github.com/cdrn/gauloi-v2/issues/2). This section is the living spec; the blog posts in `docs/` are historic design artifacts and are not updated.

### Why the validator set is removed

Three structural problems, none fixable with parameters:

1. **Votes are costless.** Losing-side attestors are not slashed. A validator set works because wrong votes destroy stake; without that, this is a poll with rewards on one side.
2. **The jury is conflicted by construction.** Attestors are the disputed maker's competitors (an incentive to convict rivals — a slash removes competition permanently) or cartel partners (an incentive to acquit). Maker markets are capital-intensive and power-law distributed; the set will be small and correlated. Bundling truth-attestation with market-making caps oracle security at market structure.
3. **The recursion argument.** A vote is only sound if wrong votes can eventually be punished — which requires a terminal arbiter beneath the vote (a proof or an accountable adjudicator). If that arbiter exists, the vote is redundant. If it doesn't, the vote is unsound. Either way the vote cannot be load-bearing. (Adding a second vote layer to slash the first — the design explored in [#31](https://github.com/cdrn/gauloi-v2/issues/31) — recurses the same problem and is superseded by this spec.)

What survives: makers as the **detection** layer. They already run infrastructure watching every chain, so bonded challenges with slash-share bounties align them as watchmen. Detection wants many self-interested eyes; judgment wants finality. v0.2 keeps the eyes and replaces the gavel.

### GauloiFillRegistry ([#53](https://github.com/cdrn/gauloi-v2/issues/53))

A small destination-side contract that makes fills canonical, unique facts:

```solidity
function fill(bytes32 intentId, address token, address recipient, uint256 amount) external;
```

- Reverts if `intentId` was already filled — one fill per intent, one intent per fill. This kills double-claiming, where one destination transfer is presented as evidence for two identical orders.
- Transfers `token` from the filler to `recipient` and stores a single-slot commitment: `fills[intentId] = keccak256(abi.encode(token, recipient, amount, msg.sender, block.number))`.
- Single-slot by design: a storage proof needs to prove exactly one slot. Verifiers receive the preimage as evidence, recompute the hash, and check `amount >= order.minOutputAmount` plus token/recipient equality — the inequality check is why the preimage travels alongside the proof rather than being verified inside the hash.

Purely additive: under v0.1 it already turns dispute verification from log-interpretation into an existence check, and it is the foundation everything else stands on.

### Disputes v2 ([#54](https://github.com/cdrn/gauloi-v2/issues/54))

- **Permissionless challenges.** `challenge(order)` requires a bond, not a maker stake. The taker — the actual victim of a fraudulent fill — and any third-party watcher can dispute. The bond alone gates griefing.
- **Maker must defend.** A challenged fill unresolved by the deadline resolves **invalid**: taker refunded from escrow, maker slashed on the existing curve. This inverts v0.1's fill-valid default, and it is safe *because of the registry*: an honest maker always has an unambiguous defense, so silence can safely convict. Low challenger turnout now hurts fraudsters instead of victims.
- **Resolver routing.** Resolution forwards to the corridor's resolver:

```solidity
interface IResolver {
    enum Verdict { Pending, Valid, Invalid }
    function resolve(bytes32 intentId, DataTypes.Order calldata order, bytes calldata evidence)
        external returns (Verdict);
}
```

- **Deleted:** attestor recording, stake-weight snapshots, quorum tracking and extension, the two-strikes global escrow pause.
- **Kept:** the slash curve, the bond formula, per-intent order storage. Splits become: verdict valid → challenger bond 50% to maker / 50% to treasury; verdict invalid → challenger refunded plus 25% of the slash, 75% to treasury.
- **Escrow unchanged.** `setDisputed` / `resolveValid` / `resolveInvalid` already make escrow agnostic to how truth is decided. Migration is a Disputes redeploy plus `setDisputes()` on Escrow and Staking.

### Resolvers

**CouncilResolver ([#55](https://github.com/cdrn/gauloi-v2/issues/55))** — M-of-N EIP-712 verdicts from a named, on-chain-registered council. Honest centralization, honestly labeled: members are publicly identified and accountable, which is what institutional diligence actually prefers over an anonymous stake poll. Bootstrap council is the deployer key, stated plainly here until it isn't. A corridor graduates council → proof with one owner call; the council automatically loses jurisdiction wherever proofs exist.

**ProofResolver ([#56](https://github.com/cdrn/gauloi-v2/issues/56))** — verifies an MPT storage proof that the destination registry holds the expected commitment, against a destination block hash known on the source chain. Ships first for the natively provable direction: fills on Ethereum proven on Arbitrum via the L1 block hash exposed to L2 contracts — no third party, minutes of latency. The reverse direction (Arbitrum fills proven on Ethereum) waits on rollup confirmation (~1 week) — acceptable for a *defense* with an extended proof deadline (slow appeals court, fast trial court), compressible later with a ZK light client; the council covers that direction meanwhile. A proof verdict is terminal and overrides any council verdict.

### Corridor economics ([#57](https://github.com/cdrn/gauloi-v2/issues/57), [#58](https://github.com/cdrn/gauloi-v2/issues/58))

The settlement window is an insurance premium priced by corridor verifiability, so it becomes per-corridor: provable corridors shrink toward destination finality; council corridors stay wide and price the residual trust into the spread. Maker capital velocity scales directly (destination float ≈ flow × window). A protocol fee switch (`feeBps`, default 0, hard-capped) lands in `settle`/`resolveValid` alongside an explicit treasury address, so it is in place — and audited — before it is ever non-zero.

### Delivery phases

| Phase | Issues | Deliverable |
|---|---|---|
| 1 | [#53](https://github.com/cdrn/gauloi-v2/issues/53) | FillRegistry deployed both chains; maker bot fills through it (additive, no breaking change) |
| 2 | [#54](https://github.com/cdrn/gauloi-v2/issues/54), [#55](https://github.com/cdrn/gauloi-v2/issues/55) | Disputes v2 with CouncilResolver; vote machinery deleted; redeploy + `setDisputes` swap |
| 3 | [#56](https://github.com/cdrn/gauloi-v2/issues/56) | ProofResolver; Ethereum-fill corridor graduates to trustless resolution |
| 4 | [#57](https://github.com/cdrn/gauloi-v2/issues/57), [#58](https://github.com/cdrn/gauloi-v2/issues/58) | Per-corridor windows; fee switch; then external audit and the mainnet checklist ([#3](https://github.com/cdrn/gauloi-v2/issues/3)) |

## Off-chain RFQ flow

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

Measured with `forge snapshot --match-contract GasBenchmark` (Solc 0.8.24, optimizer 200 runs). Dispute rows reflect the v0.1 vote mechanism and will change with [#54](https://github.com/cdrn/gauloi-v2/issues/54).

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

`docs/blog-part1-architecture.md` and `docs/blog-part2-mechanism-design.md` are the original v0.1 design writings, kept as historic artifacts — they describe the thinking at the time, including the maker-attestation mechanism this spec replaces. The current spec is this README.
