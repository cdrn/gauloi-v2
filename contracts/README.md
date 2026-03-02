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

## Deploy

```shell
# Set env vars in .env.local (DEPLOYER_KEY, USDC_ADDRESS, etc.)
forge script script/Deploy.s.sol:Deploy --rpc-url sepolia --broadcast --verify
```

See `script/Deploy.s.sol` for configurable parameters (MIN_STAKE, SETTLEMENT_WINDOW, etc.).
