# Gauloi v2 Contracts

Three Solidity contracts implementing cross-chain stablecoin settlement with EIP-712 signed orders.

## Contracts

- **GauloiStaking** — Maker stake management, exposure tracking, slashing
- **GauloiEscrow** — Order execution (EIP-712 signed orders), fill submission, settlement, batch operations
- **GauloiDisputes** — Dispute creation, resolution via M/N attestor signatures

## Build

```shell
forge build
```

## Test

```shell
forge test                                          # all tests
forge test --match-contract GasBenchmark            # gas benchmarks only
forge snapshot --match-contract GasBenchmark         # update .gas-snapshot
forge snapshot --match-contract GasBenchmark --diff  # check for regressions
```

## Gas Benchmarks

| Operation | Gas | Amortised |
|---|---|---|
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

Updated via `forge snapshot --match-contract GasBenchmark`.

## Deploy

```shell
# Set env vars in .env.local (DEPLOYER_KEY, USDC_ADDRESS, etc.)
forge script script/Deploy.s.sol:Deploy --rpc-url sepolia --broadcast --verify
```

See `script/Deploy.s.sol` for configurable parameters (MIN_STAKE, SETTLEMENT_WINDOW, etc.).

## Deployed Addresses

### Eth Sepolia (11155111)

| Contract | Address |
|---|---|
| USDC | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |
| Staking | `0x363531686E6a0B1A52189bE878038075B14cBCcB` |
| Escrow | `0x4A01bc51DF2c58C9fCad0413B3417a47bADE0e52` |
| Disputes | `0x49CFF580Ad8A15B82a22f9376e65Dc9CebFEc94a` |

### Arbitrum Sepolia (421614)

| Contract | Address |
|---|---|
| USDC | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` |
| Staking | `0x61bc65601290bD7CBfF2461a1C2B81d0892064Dd` |
| Escrow | `0xf9fFa89F4B3d3b63c389D91B06D805534BcE9256` |
| Disputes | `0x9938386603295918D6A4167839297fCB46FaF3E1` |

### Chainlink Price Feeds (USDC/USD)

| Chain | Feed Address |
|---|---|
| Eth Sepolia | `0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E` |
| Arbitrum Sepolia | `0x0153002d20B96532C639313c2d54c3dA09109309` |

### Testnet Parameters (current deploy)

| Parameter | Value |
|---|---|
| Settlement window | 15 minutes |
| Commitment timeout | 5 minutes |
| Min stake | 1 USDC |
| Unstake cooldown | 48 hours |
| Dispute resolution window | 24 hours |
| Dispute bond | max(0.5% of fill, 25 USDC) |
| Stale price threshold | 24 hours |

See `plan.md` for production target values.
