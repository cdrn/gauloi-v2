# gauloi-v2
Cross chain stablecoin swapping protocol with baked in compliance

## Testnet Deployments

### Sepolia (Chain ID: 11155111)

| Contract | Address | Verified |
|----------|---------|----------|
| USDC (Circle) | [`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`](https://sepolia.etherscan.io/address/0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) | - |
| GauloiStaking | [`0xa9C45d4f33639B2F12B80d6d1C1B7124c5197778`](https://sepolia.etherscan.io/address/0xa9C45d4f33639B2F12B80d6d1C1B7124c5197778) | Yes |
| GauloiEscrow | [`0x1786C39875819c90C8834D099CB182D2BF156E77`](https://sepolia.etherscan.io/address/0x1786C39875819c90C8834D099CB182D2BF156E77) | Yes |
| GauloiDisputes | [`0x34C49c7fe668cDdD13a8Af5677d3d71d57eFdddc`](https://sepolia.etherscan.io/address/0x34C49c7fe668cDdD13a8Af5677d3d71d57eFdddc) | Yes |

### Arbitrum Sepolia (Chain ID: 421614)

| Contract | Address | Verified |
|----------|---------|----------|
| USDC (Circle) | [`0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d`](https://sepolia.arbiscan.io/address/0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d) | - |
| GauloiStaking | [`0x123EAF1845C35639fd5481485cdc94c61780B0A5`](https://sepolia.arbiscan.io/address/0x123EAF1845C35639fd5481485cdc94c61780B0A5) | Yes |
| GauloiEscrow | [`0x6f46388f43Fbd7EB5466c027352BC0bC520F29BC`](https://sepolia.arbiscan.io/address/0x6f46388f43Fbd7EB5466c027352BC0bC520F29BC) | Yes |
| GauloiDisputes | [`0xAc3eff975782457B1559A3aD5D53856f81c7e962`](https://sepolia.arbiscan.io/address/0xAc3eff975782457B1559A3aD5D53856f81c7e962) | Yes |

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

Measured with `forge test --match-contract GasBenchmark --gas-report` (Solc 0.8.24, optimizer 200 runs).

### GauloiStaking

| Operation | Gas |
|-----------|-----|
| stake | 105,999 |
| requestUnstake | 74,127 |
| completeUnstake | 56,683 |

### GauloiEscrow

| Operation | Gas |
|-----------|-----|
| createIntent | 262,496 |
| commitToIntent | 112,013 |
| submitFill | 80,986 |
| settle | 57,407 |
| settleBatch (5) | 140,753 |
| settleBatch (10) | 243,366 |
| reclaimExpired | 67,915 |

### GauloiDisputes

| Operation | Gas |
|-----------|-----|
| dispute | 210,876 |
| resolveDispute (1 sig) | 145,298 |
| finalizeExpiredDispute | 132,505 |

Run `forge snapshot --match-contract GasBenchmark --diff` to check for regressions.
