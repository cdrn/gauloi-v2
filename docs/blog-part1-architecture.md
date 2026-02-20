# Gauloi: Compliant Cross-Chain Settlement

*10 February 2026 — cdrn.xyz*

## 1. Preamble

A gauloi is a Phoenician trade cog - a round-hulled merchant ship that carried goods across the ancient world three thousand years ago. The Phoenicians ran the widest known trade network of their era - not just the Mediterranean but beyond: tin from Britain, gold from West Africa via Hanno's fleet down the Atlantic coast, and if you believe Herodotus, a full circumnavigation of Africa commissioned by Pharaoh Necho II two and a half millennia before Magellan. They connected economies that couldn't trade directly - Egypt, Greece, Carthage, Iberia, and beyond - through a network of neutral ports, standardised weights, and pragmatic indifference to who was on the other side of the trade. They didn't care about your god or your king. They cared about your cargo.

I first designed Gauloi with 0x330a, drawing on my experience building cross-chain infrastructure at Chainflip. The original was an HTLC-based atomic swap protocol with a peer-to-peer marketplace - Kademlia routing, proof-of-work spam prevention, the works. We phased it Sidon, Tyre, Carthage after the Phoenician trade cities. The thesis was simple: there's no way to swap between Bitcoin and Ethereum reliably without delegating your funds to a multisig, and multisigs get hacked. Atomic swaps solve this. Peer to peer. No intermediaries. Your funds never leave your custody.

That thesis was right. The mechanism was wrong. I'll explain why, what's changed, and where this needs to go.

## 2. What was wrong with v1

The original Gauloi used hashed time-locked contracts. HTLCs are elegant in theory: two parties lock funds on their respective chains, a shared hash locks both sides, revealing the preimage on one chain lets you claim on the other. Atomic. Trustless. No multisig.

In practice, they have three problems that make them unusable as a spot market.

First, the optionality problem. James Prestwich wrote about this extensively. In an HTLC swap, until funds are committed on both ends and the preimage is revealed, either party can back out. The worst case: your counterparty locks funds, you lock funds, and they simply... wait. They now hold a free option on the underlying asset for the duration of the timelock. Price moves in their favour? Complete the swap. Doesn't? Let it expire. You've given someone a free call option and locked your capital to do it.

Second, the UX. Both parties must be online. Timelocks must be staggered across chains with different block times and finality guarantees. Reorgs can create race conditions where a preimage is revealed too close to expiry. You need watchtowers to enforce claims if you go offline. The surface area of things that can go wrong is large, and every edge case locks someone's funds for hours.

Third, coincidence of wants. HTLCs don't have pools or passive liquidity - just two people who happen to want opposite sides of the same trade at the same time. Fine for large bilateral trades. Doesn't scale to a market.

We knew these problems when we wrote the original spec. We thought reputation systems, spam prevention and market makers quoting implied volatility over the timelock window could patch them. They can't. The problems are structural to HTLCs, not incidental.

Since then, the landscape shifted. Intent-based architectures emerged. The stablecoin market exploded. The compliance gap between what regulators demand and what on-chain infrastructure provides became a chasm. And the bridge wars proved that the bridge is not the product - the orderflow is.

Gauloi v2 keeps the peer-to-peer ethos and drops the settlement primitive that made it unusable.

## 3. The gap

I've written about these problems individually over the past year. Why stablecoin issuers will compete on yield until the spread between money and t-bills trends toward zero. Why blacklist() catches static funds and dumb attackers but can't touch anything that moves - 44 minutes to freeze an address that can exit in 12 seconds. Why bridges lost the value war to aggregators and solvers who own the orderflow.

Here's where things stand. An institution wants to move $5M of USDT on Tron to USDC on Base. They can use a centralised exchange (slow, KYC friction, counterparty risk, fees), an OTC desk (phone call, trust someone, settle in hours), or a permissionless bridge (fast, but their compliance team vetoes it because the pool processed Lazarus funds last month). None of these are good.

On the retail side it's more mundane but equally broken. User holds USDT because that's what their on-ramp gave them. The app they want takes USDC on Arbitrum. They need to find a bridge aggregator, pay gas on two chains, wait for finality, and hope the routing doesn't touch something sanctioned. Or just use a CEX. Most do.

What's missing is a settlement layer that doesn't care which stablecoin you hold or which chain it's on, handles compliance at the participant level rather than the protocol level, and is cheap enough that makers can quote tight on what are essentially 1:1 swaps.

## 4. Why stablecoins

The original Gauloi was for BTC/ETH. Why narrow the scope?

Volatile pairs are hard. The optionality problem from v1 doesn't go away just because you swap HTLCs for optimistic settlement - it changes shape. A maker filling a volatile cross-chain swap is taking directional risk for the duration of the settlement window, and that risk has to be priced into the spread. You end up competing with CEXs on execution quality, which is a losing game unless you have Citadel's infrastructure.

Stablecoin pairs are different. USDC/USDT is not a trade, it's a transfer denominated in the same unit with different issuers on different rails. The "price" is 1:1 with minor deviations. Inventory risk is basis points. This means spreads can be tight enough that the compliance angle actually matters - when your spread is 3 bps, the difference between "I screened this counterparty" and "I didn't" is the whole margin.

The other reason is that stablecoins are where the compliance problem is most acute. These are dollar instruments. Issuers have freeze functions. OFAC cares. The GENIUS Act is mandating capabilities that structurally can't do what's asked of them. Institutions want to use stablecoins cross-chain but can't touch the existing rails. This is a compliance gap with real money behind it, not a theoretical one.

And there's a market timing argument. An explosion of issuer-specific stablecoins is coming - every bank, every fintech, every payments company wants to issue one. For payments to actually work, they need to interoperate. Circle's CCTP handles USDC-to-USDC across chains but it's a single-issuer solution, not a market. Nobody is building the neutral settlement layer for cross-stable, cross-chain flows with compliance that actually works. That's the gap.

## 5. The architecture

Gauloi is an intent-based cross-chain settlement protocol for stablecoins.

A taker broadcasts an intent: "I have 10,000 USDT on Tron. I want USDC on Base." Makers see the intent. Before quoting, they screen the taker's address - Chainalysis, TRM, Elliptic, whatever their compliance stack looks like. Clean address? They quote. Dirty? They walk away. The protocol doesn't make that call. The maker does.

Settlement is optimistic. Best quote wins. The maker fills the taker on the destination chain and the system assumes the fill is valid unless someone disputes it. A dispute window opens. If no fraud proof lands before it closes, settlement finalises and the maker receives the taker's source funds.

That's the loop. Intent, screen, quote, fill, settle.

What matters here is what the protocol doesn't do. The protocol has no opinion on compliance - it just coordinates and settles. Makers are the ones with capital deployed, with reputations, with regulatory exposure, so they make the compliance call. This is how market making works in tradfi. It should work this way on-chain too.

The other thing that matters is that the maker sees the counterparty before committing capital. This is impossible on an AMM. A Uniswap pool can't tell if the next swap is from Coinbase or Lazarus. Intent-based systems expose the taker at quote time. Compliance isn't bolted on after the fact - it's native to the flow. The quote is the compliance decision.

Settlement being optimistic rather than atomic is the key evolution from v1. Instead of locking liquidity on both chains and playing the HTLC timeout game, the maker just fills and trusts the system to release source funds after the dispute window. It's more capital efficient, better UX, and you don't hand your counterparty a free option. The tradeoff is finality risk during the settlement window, but for stablecoin pairs with minimal volatility, that risk is small and priceable.

If this sounds like Across, it should. Across pioneered intent-based optimistic settlement for cross-chain transfers, using UMA's oracle for dispute resolution with a 60-minute batch window. It works. But Across is a general purpose bridge with permissionless relayers - anyone can fill, there's no screening, and the protocol makes no distinction between a Coinbase treasury wallet and a Lazarus proxy. That's fine for ETH and general token transfers where compliance is someone else's problem. It's not fine for stablecoins, where the issuer has a freeze function and the regulator has an opinion. Gauloi takes the intent-plus-optimistic-settlement model and makes compliance native to the quote flow. The maker screens before filling. The protocol stays neutral but the participants aren't anonymous to each other. Same settlement guarantees, different trust model at the edges.

## 6. Compliance as a market function

The standard approach to on-chain compliance is access control. Whitelist addresses, blacklist addresses, freeze at the contract level. I've argued before that this is structurally broken - too slow, too blunt, trivially routed around by anyone who understands the asset model.

Gauloi does something different. Compliance is a market function, not a protocol function.

Each maker runs their own compliance stack. Some screen with Chainalysis. Others require full KYC attestations. Others are pseudonymous and will fill anyone for a wider spread. The protocol doesn't prescribe any of this - it provides settlement guarantees and lets makers compete.

What falls out of this naturally is tiered pricing. A maker screening counterparties via chain analytics will quote tight, because they have confidence in the counterparty's provenance - the compliance premium is actually negative, you get better pricing for being clean. Takers with on-chain KYC attestations (Worldcoin, Coinbase Verifications, whatever wins) get even tighter quotes. They're trading privacy for price improvement. And the open rail - no screening, no attestation, any address can request a quote - has wider spreads and smaller size, because the maker is pricing in full counterparty risk.

These aren't separate systems. Same liquidity, same makers, same settlement layer. A clean address gets 2 bps. An unknown address gets 15 bps. A flagged address gets no quote. The spread is the compliance decision expressed as a price. The market does the work.

This is how risk gets priced everywhere else. Insurance premiums, credit spreads, lending rates - they're all compliance and risk decisions expressed as prices rather than binary access controls. On-chain, we've been doing it backwards: blocking at the gate instead of pricing at the quote.

## 7. Maker economics

Stablecoin-to-stablecoin pairs are quasi-pegged. USDC/USDT, USDT/PYUSD, USDC/EURC - these aren't volatile. Inventory risk for a maker here is a totally different animal to holding ETH against USDC.

What a maker is actually pricing: depeg risk (rare but real - Tether depegged briefly in 2022, USDC depegged during SVB - for major stables this is basis points, not percentages), chain finality risk (a reorg on the source chain could invalidate the taker's deposit after the maker already filled on destination - deeper finality means lower risk, and makers price this per chain), timing risk (USDT on Tron settles differently to USDC on Arbitrum, the maker is exposed during the gap, but for stablecoins this is mostly opportunity cost not loss risk), and compliance risk (screening misses something, you fill an address that gets flagged later - nonzero but quantifiable, and that's what the spread is for).

All in, for a clean counterparty on a major stablecoin pair across liquid chains: single digit basis points. Competitive with CEX fees and significantly better than the current bridge-plus-swap stack. For institutional size the spread compresses further because fixed compliance costs amortise across larger fills.

Better screening means tighter quotes which means more orderflow which means more revenue. Compliance capability gets directly monetised. The maker with the best risk infrastructure wins.

## 8. The wedge

The go-to-market isn't consumer. Not yet.

Bridges need to rebalance liquidity across chains constantly and they currently do it through DEX swaps, CEX transfers or manual OTC - all expensive, all slow. Gauloi as a rebalancing layer with compliant counterparties and tight spreads is the first wedge. LiFi, Socket, Across, Stargate all need this. It's B2B: Gauloi sits underneath existing aggregators as a settlement option.

Second is institutional cross-chain. OTC desks, funds, corporate treasuries moving stablecoins between chains. These entities want compliance guarantees that no existing bridge can offer. KYC'd counterparties, maker screening, audit trails. Better than a phone call to a desk, and better than trusting a bridge that processed stolen funds last month.

The endgame is consumer settlement. "Pay in any stable" - user holds USDT, merchant accepts USDC, Gauloi settles in the background. User never sees a bridge, never picks a chain, never thinks about which stablecoin they hold. But this only works once the rebalancing and institutional layers are running. The consumer layer is just UX on top of infrastructure that already works.

B2B first gets volume without needing distribution. Institutional second builds the compliance track record. Consumer third is where the orderflow moat compounds, but only once the plumbing is proven.

## 9. What's next

Part 2 will cover mechanism design in detail: dispute resolution, fraud proof construction, game theory of the optimistic settlement window, and the smart contract architecture. There are hard problems in there, particularly around cross-chain finality guarantees and what happens when the dispute window spans chains with different security models.

If you're a maker, a bridge operator, or an institution that moves stablecoins cross-chain and hates every option available - I want to talk.
