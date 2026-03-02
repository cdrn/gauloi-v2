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

**Compliance at the maker level.** Makers screen counterparties and price risk into their spread. The protocol doesn't enforce KYC — it provides the settlement infrastructure, and makers operate within their own regulatory framework.

**Off-chain RFQ flow:**

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

## Testnet Deployments

### Sepolia (Chain ID: 11155111)

| Contract | Address | Verified |
|----------|---------|----------|
| USDC (Circle) | [`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`](https://sepolia.etherscan.io/address/0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) | - |
| GauloiStaking | [`0xc157d212a20361f8DBD4D6D890Ba19C62E1bf181`](https://sepolia.etherscan.io/address/0xc157d212a20361f8DBD4D6D890Ba19C62E1bf181) | Yes |
| GauloiEscrow | [`0x61bc65601290bD7CBfF2461a1C2B81d0892064Dd`](https://sepolia.etherscan.io/address/0x61bc65601290bD7CBfF2461a1C2B81d0892064Dd) | Yes |
| GauloiDisputes | [`0xf9fFa89F4B3d3b63c389D91B06D805534BcE9256`](https://sepolia.etherscan.io/address/0xf9fFa89F4B3d3b63c389D91B06D805534BcE9256) | Yes |

### Arbitrum Sepolia (Chain ID: 421614)

| Contract | Address | Verified |
|----------|---------|----------|
| USDC (Circle) | [`0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d`](https://sepolia.arbiscan.io/address/0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d) | - |
| GauloiStaking | [`0x34C49c7fe668cDdD13a8Af5677d3d71d57eFdddc`](https://sepolia.arbiscan.io/address/0x34C49c7fe668cDdD13a8Af5677d3d71d57eFdddc) | Yes |
| GauloiEscrow | [`0x94AC29e9888314Bf9Addc60c7CB3FFa876e7565a`](https://sepolia.arbiscan.io/address/0x94AC29e9888314Bf9Addc60c7CB3FFa876e7565a) | Yes |
| GauloiDisputes | [`0xe2D845c033F8BEF0d10c6c1B06BdE4882f3b0f8a`](https://sepolia.arbiscan.io/address/0xe2D845c033F8BEF0d10c6c1B06BdE4882f3b0f8a) | Yes |

### Testnet Parameters

| Parameter | Value |
|-----------|-------|
| Settlement window | 2 minutes |
| Commitment timeout | 2 minutes |
| Min stake | 10 USDC |
| Unstake cooldown | 5 minutes |
| Dispute resolution window | 5 minutes |
| Dispute bond | max(0.5% of fill, 0.1 USDC) |

## Gas Costs

Measured with `forge snapshot --match-contract GasBenchmark` (Solc 0.8.24, optimizer 200 runs).

### GauloiStaking

| Operation | Gas |
|-----------|-----|
| stake | 102,874 |
| requestUnstake | 154,772 |
| completeUnstake | 147,304 |

### GauloiEscrow

| Operation | Gas |
|-----------|-----|
| executeOrder | 266,775 |
| submitFill | 294,406 |
| settle | 267,147 |
| settleBatch (5) | 714,276 |
| settleBatch (10) | 1,270,755 |
| reclaimExpired | 241,787 |

### GauloiDisputes

| Operation | Gas |
|-----------|-----|
| dispute | 780,981 |
| resolveDispute (1 sig) | 799,226 |
| finalizeExpiredDispute | 785,231 |

Run `forge snapshot --match-contract GasBenchmark --diff` to check for regressions.
