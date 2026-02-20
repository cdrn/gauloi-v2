# Gauloi Part 2: Mechanism Design

*20 February 2026 — cdrn.xyz*

## 1. Preamble

Part 1 covered what Gauloi is and why it exists. Intent-based cross-chain stablecoin settlement, compliance at the maker level, optimistic finality. The architecture post.

This post is about how it actually works. The escrow state machine, the dispute mechanism, the settlement window, the edge cases. Some of this is settled. Some of it isn't, and I'll say so where that's the case.

## 2. The escrow state machine

Everything starts with an escrow contract on the source chain. The taker locks funds, the protocol coordinates the fill, and the escrow releases once settlement finalises.

The lifecycle has six states. A taker deposits into the escrow with their intent parameters (output token, destination chain, destination address, minimum amount, expiry) and the intent goes OPEN. A maker commits on-chain, reserving the intent so nobody else can front-run the fill - this adds a gas cost but prevents two makers from racing to fill the same intent. The maker then has N blocks to fill before the commitment expires and the intent reopens.

Once the maker has sent the correct token to the taker's destination address on chain B, they submit a claim to the escrow on chain A with the destination tx hash. This moves the intent to FILLED and starts the dispute window. If the window passes without a challenge, the escrow releases the taker's deposit to the maker. If someone disputes, it escalates to the staked maker set for resolution. If no maker ever commits, or a committed maker doesn't fill in time, the taker reclaims their deposit.

The on-chain footprint in the happy path is two to three transactions: taker deposits, maker commits, maker claims. The fill itself happens on chain B and only touches chain A when the maker submits evidence.

The contract interface looks roughly like this:

```solidity
enum IntentState { Open, Committed, Filled, Settled, Disputed, Expired }

struct Intent {
    address taker;
    address inputToken;
    uint256 inputAmount;
    uint256 destinationChain;
    address destinationAddress;
    address outputToken;
    uint256 minOutputAmount;
    uint256 expiry;
    IntentState state;
    address maker;
    bytes32 fillTxHash;
    uint256 disputeWindowEnd;
}

// --- Maker staking ---

// Maker deposits stake to join the network.
// Stake token set at deployment (see open questions).
function stake(uint256 amount) external;

// Maker withdraws stake. Subject to cooldown
// to prevent unstaking immediately after a fraudulent fill.
function unstake(uint256 amount) external;

// --- Intent lifecycle ---

// Taker approves inputToken first, then calls this.
// Transfers inputAmount of inputToken into escrow.
function createIntent(
    address inputToken,
    uint256 inputAmount,
    address outputToken,
    uint256 minOutputAmount,
    uint256 destinationChain,
    address destinationAddress,
    uint256 expiry
) external returns (bytes32 intentId);

// Staked maker reserves an intent. Reverts if caller
// has insufficient stake for the fill amount.
function commitToIntent(bytes32 intentId) external;

// Maker submits evidence of fill on destination chain.
// Starts the dispute window.
function submitFill(bytes32 intentId, bytes32 destinationTxHash) external;

// Anyone can call after dispute window expires
// with no active dispute. Releases escrow to maker.
function settle(bytes32 intentId) external;

// Taker reclaims deposit if intent expired
// or committed maker failed to fill in time.
function reclaimExpired(bytes32 intentId) external;

// --- Disputes ---

// Any staked maker can challenge a fill claim.
// Bond amount calculated from fill size, transferred from caller.
function dispute(bytes32 intentId) external;

// Staked makers submit attestations to resolve a dispute.
// M/N threshold of signatures triggers resolution.
function resolveDispute(
    bytes32 intentId,
    bool fillValid,
    bytes[] calldata signatures
) external;
```

Not final, but this is the shape of it.

## 3. The dispute mechanism

Stablecoin settlement disputes are objectively resolvable. The question is always: did the maker send X amount of token Y to address Z on chain B? That's a binary lookup. The transaction either exists with the right parameters or it doesn't. Verifiable by anyone with an RPC endpoint.

The system uses a single honest challenger model. This is the same security assumption as optimistic rollups - Optimism posts state roots to L1 and assumes they're valid, and anyone can submit a fraud proof within the dispute window. The system doesn't need every validator to check every state root. It just needs one honest watcher. If nobody challenges, the state root finalises. If even one participant catches fraud, the system self-corrects.

Gauloi works the same way. Maker submits fill evidence and the claim is assumed valid by default. Settlement finalises automatically after the dispute window unless someone challenges. Any staked maker can raise a dispute by posting a bond. You only need one honest participant watching the network to catch fraud.

Why this works particularly well for stablecoin settlement: verification is cheap (checking a tx hash is a single RPC call, so staked makers can passively monitor every fill without it being a burden), fraud is obvious (a fake tx hash either doesn't exist or has the wrong parameters, there's no ambiguity), and challengers are economically motivated (catch a fraudulent fill, get rewarded from the fraudulent maker's slashed stake).

In the happy path, nothing happens. Maker claims, window passes, escrow releases. The dispute infrastructure exists but never activates. This solves the incentive problem of "how do you pay attestors when disputes are rare" - you don't need to, because active attestation isn't required for normal operation. The system only activates under adversarial conditions.

When a dispute is raised, the staked maker set resolves it. Each participating maker independently checks the claimed transaction on chain B and signs an attestation. A threshold of M/N signatures resolves the dispute on-chain - the escrow contract verifies the threshold and either releases funds to the maker (claim valid, disputer's bond slashed) or returns funds to the taker (claim invalid, maker's stake slashed).

Resolution should be fast. For EVM chains where you're checking a tx hash against an RPC, minutes not hours. The dispute window itself is longer than resolution time to give people time to notice, but the actual resolution once triggered should be near-instant.

## 4. Staked makers as the attestor set

Every maker stakes capital to join the network. The stake does triple duty: it gates participation (prevents sybil attacks), limits the maker's maximum active fill exposure (stake 500k, fill up to some multiple of that concurrently), and backs their attestations during dispute resolution (incorrect attestation = slashing). The same capital that lets them make markets also backs the integrity of the dispute mechanism.

This avoids introducing a separate class of participant. The people verifying fills are the same people doing fills. They already have the infrastructure (watching multiple chains, monitoring cross-chain state), they already have economic alignment (their own fills depend on the system being trustworthy), and they already have capital at risk.

The collusion question: what stops the staked makers from all agreeing to approve each other's fraudulent fills? Staked capital should be large enough that the cost of getting caught exceeds the one-time gain from fraud - the slashing penalty is the maker's entire stake, not just a portion, so a maker with 500k staked who tries to steal 100k risks the full 500k. As the maker set grows, coordinating collusion among independent economic actors becomes harder. And reputationally, makers operating in the compliant stablecoin space are likely to be known entities with businesses and regulatory exposure - the kind of participants for whom getting caught colluding is existentially bad, not just expensive.

Early on when the maker set is small (say, 3-5 makers), the collusion risk is real and the honest answer is that you're relying on a small group of known, staked participants to be honest. This is roughly equivalent to trusting a multisig - which is exactly the thing Gauloi v1 was trying to avoid. The difference is that the trust assumption shrinks as the network grows, the participants have ongoing economic skin in the game rather than just key custody, and the stakes are denominated in the thing they'd have to steal (stablecoins) rather than in some governance token with detached incentives.

I want to explicitly avoid a governance token for attestor selection. The design works with economic incentives and reputation. Token voting is a rug pull factory and I don't want it anywhere near the settlement layer.

## 5. The settlement window

How long should the dispute window be?

It depends on the chain pair. The window needs to be long enough that the maker's fill on chain B is actually final, watchers have time to notice and dispute a fraudulent claim, and the maker set can respond if a dispute is raised.

For EVM L2s (Arbitrum, Base, Optimism) with fast soft finality, the fill confirms in seconds. But L2 finality is complicated. Soft confirmation from the sequencer is fast but technically reversible if the sequencer goes rogue. Hard finality (posted to L1) takes longer - minutes to hours depending on the L2. And for optimistic rollups, the fraud proof window is 7 days, though in practice state roots are almost never challenged.

So which finality do you target? If you wait for full L1 finality on every fill, your settlement window is hours to days and capital efficiency dies. If you accept sequencer soft confirmation, you get fast settlement but take on the (small, theoretical) risk that the sequencer reverses the fill.

My current thinking is to let makers price this. Define chain-specific minimum settlement windows based on reasonable finality assumptions - maybe 30 minutes for Arbitrum/Base (well past soft confirmation, short of L1 finality), 15 minutes for Ethereum mainnet (sufficient block depth), and longer for chains with weaker finality. Makers who fill on chains with longer windows price the capital lockup into their spread. The protocol sets the floor, the market sets the ceiling.

The interesting edge case: what happens if a fill on chain B gets reorged after the settlement window closes and the escrow has already released? The taker's deposit is gone. The maker's fill evaporated. Someone lost money. The honest answer is that this is a chain-level failure, not a protocol-level failure, and whoever took the finality risk (the maker) eats the loss. This is the same risk every bridge takes. You can mitigate it by being conservative with settlement windows per chain, but you can't eliminate it without waiting for true L1 finality everywhere, which makes the system unusable.

For stablecoins, this risk is at least bounded. A reorged fill on a 1:1 stablecoin pair means the maker lost approximately the face value. No directional blowup. A maker can quantify this risk per chain and reserve against it.

## 6. Bond economics

There are two bonds in the system: the maker's stake and the dispute bond. They serve different purposes and price different attacks.

The maker's stake is a standing bond. Posted once when the maker joins, stays locked while they're active. It limits concurrent fill exposure, backs attestation, and is the slashing target for fraud. The standing model is more capital efficient than per-fill bonding - the maker posts once and executes many fills against the same stake, with the constraint on concurrent exposure rather than per-fill cost. Active makers turning over capital quickly amortise the bond cost across volume.

The stake needs to be large enough that fraud is -EV. The expected value of attempting a fraudulent claim is (1-P) * fill_amount - P * stake, where P is the probability of getting caught. Given the single honest challenger assumption and the trivial verification cost, P should be very high. A stake of 2-5x the maximum fill size makes fraud unprofitable even with generous assumptions about getting away with it - a maker staking 500k who tries to steal 100k on a single fill risks the entire 500k.

The dispute bond is posted by the challenger. It prevents spam - a troll disputing every claim pays the bond each time and loses it when the claim is valid. A legitimate challenger pays once, gets it back plus a reward from the fraudulent maker's slashed stake. Since dispute resolution is fast (minutes, a trivial RPC lookup) the damage from a spam dispute is limited, so the bond doesn't need to be extreme. Something like max(0.5% of swap, 25 USDC) - enough to make griefing unprofitable but low enough that real fraud gets challenged.

These parameters need to be tunable. The contracts should support governance-free parameter updates through a timelock mechanism - no token voting.

## 7. Extending beyond EVM

Everything above assumes both chains are EVM-compatible. Transaction hashes look the same, RPC interfaces are standardised, the staked maker set knows how to verify a fill using the same tooling regardless of which EVM chain it's on.

Tron is the obvious next step because it's where most USDT lives. Tron is mostly EVM-compatible at the API level so the dispute resolution model doesn't change much. The differences are in finality (DPoS with 27 super representatives, ~3 second blocks, 19-block finality around 57 seconds) and gas economics. The escrow contract would need a Tron-specific deployment (Solidity compiles to TVM with minor differences) but the dispute mechanism works the same way.

Bitcoin is the hard case. No smart contracts in the EVM sense, no escrow contract, no on-chain state machine. Supporting BTC stablecoins would need either an intermediary chain to host the escrow or a UTXO-native escrow using Bitcoin Script - limited but possible for simple lock/release patterns. Later problem. Stablecoin volume is overwhelmingly EVM plus Tron.

Solana is interesting because it has large USDC volume and a different execution model (accounts and programs, not contracts and storage). The dispute mechanism still works - a fill on Solana produces a transaction signature that any maker can verify. The gap is that Gauloi's contracts would need to be written in Rust, which doubles the audit surface. Worth doing eventually, not for v0.1.

The general principle: the escrow and dispute mechanism should work for any chain pair where a staked maker can verify a transaction happened. The staked maker set is the abstraction layer - they translate "did this fill happen on chain B" into a signed attestation that the escrow on chain A can consume, regardless of what chain B looks like underneath.

## 8. Open questions

There are things I haven't solved yet.

**Maker collusion in early days.** The economic argument against collusion improves with scale. With 3-5 makers, it's a trust assumption. With 50 staked makers, coordination is hard and one defector collapses the scheme. The bootstrap period is the most vulnerable and probably requires known, reputable initial makers who have more to lose from reputational damage than they could gain from fraud. This is imperfect. It might be the best available option for early-stage.

**Intent ordering and MEV.** If intents are posted on-chain, block builders see them before makers do. A malicious builder could front-run intents by inserting their own maker commitment before legitimate makers. For stablecoins with tight spreads this is less of an issue than for volatile pairs (not much to extract from front-running a 3 bps spread), but it's worth thinking about. Off-chain intent relay would solve this but adds infrastructure.

**Multi-hop routes.** The design above assumes single-hop: chain A to chain B. What about USDT on Tron to EURC on Ethereum where there's no direct maker? You'd need either a multi-hop route (Tron USDT to Arb USDC to Eth EURC) or a single maker capitalised on both ends. Multi-hop introduces sequential settlement dependencies and compounding failure risk. Probably better to let makers handle routing internally and just quote a single price for the end-to-end.

**Regulatory classification.** Is Gauloi an exchange? A clearinghouse? A money transmitter? The compliance-at-maker-level design is partly intended to push regulatory obligations to the participants rather than the protocol, but untested legal theory isn't the same as regulatory clarity. This needs real legal analysis, which I haven't done yet.

**Stake denomination.** Should the maker stake be in a specific stablecoin, in ETH, or in something else? Stablecoin-denominated stakes are cleanest (the system handles stablecoins, the stake is in stablecoins, no oracle needed for slashing calculations). But which stablecoin? USDC is the obvious choice for US-compliant makers, but it introduces an issuer dependency on the settlement layer itself. ETH-denominated stakes require a price oracle for calculating slashing relative to fill amounts. No clean answer here yet.

## 9. What's next

Part 3 will probably be code. Escrow contracts for Arbitrum and Base, a basic maker bot, and enough infrastructure to prove the settlement loop works end to end. USDC/USDT, two chains, one maker. Boring and functional.

If you've read both parts and have opinions on the staking model or the dispute economics, I'm genuinely interested. These are the hardest open problems and I'd rather get them right than ship something elegant that breaks under adversarial conditions.
