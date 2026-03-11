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
| Staking | `0x140901e3285c01A051b1E904e4f90e2345bC0F3a` |
| Escrow | `0xa32D78ac618B41f5E7Ace535b921f1b06D87118E` |
| Disputes | `0xb4d5A4ea7D0Ec9A57a07d24f1A51a3Ca7ade526F` |

### Arbitrum Sepolia (421614)

| Contract | Address |
|---|---|
| USDC | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` |
| Staking | `0x845E14C0473356064b6fA7371635F5FAE8AE62B3` |
| Escrow | `0x0AE9C298A70f10A217D7b017A7aBF64c9bB52579` |
| Disputes | `0x877042524F713fa191687A70D6142cbF1C3cfec6` |

### Chainlink Price Feeds (USDC/USD)

| Chain | Feed Address |
|---|---|
| Eth Sepolia | `0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E` |
| Arbitrum Sepolia | `0x0153002d20B96532C639313c2d54c3dA09109309` |

### Testnet Parameters (current deploy)

| Parameter | Value |
|---|---|
| Settlement window | 2 minutes |
| Commitment timeout | 2 minutes |
| Min stake | 10 USDC |
| Unstake cooldown | 5 minutes |
| Dispute resolution window | 5 minutes |
| Dispute bond | max(0.5% of fill, 0.1 USDC) |
| Stale price threshold | 24 hours |

See `plan.md` for production target values.
