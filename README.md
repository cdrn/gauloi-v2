# gauloi-v2
Cross chain stablecoin swapping protocol with baked in compliance

## Architecture

Gasless intent creation via EIP-712 signed orders. The taker signs an order off-chain (0 gas), and the maker calls `executeOrder` with the signed order to pull tokens and commit in a single transaction.

```
[Off-chain: Taker signs EIP-712 order]
         |
         v
    Committed --> Filled --> Settled
         |            |
         +-> Expired   +-> Disputed --> Settled (fill valid)
            (reclaim)                   +-> Refunded (fill invalid)
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
