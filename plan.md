# Gauloi v2 — Implementation Plan

## Context

Gauloi v2 is an intent-based cross-chain stablecoin settlement protocol. Compliance happens at the maker level (makers screen counterparties and price risk into their spread), settlement is optimistic (fill assumed valid unless disputed), and the RFQ flow happens off-chain with on-chain escrow for fund safety.

The goal for v0.1: prove the settlement loop end-to-end. USDC/USDT across Ethereum + Arbitrum, single maker, optimistic settlement with dispute resolution. Boring and functional.

Reference docs will live in `docs/blog-part1-architecture.md` and `docs/blog-part2-mechanism-design.md`.

---

## Decisions

| Decision | Choice |
|----------|--------|
| Contract framework | Foundry |
| Off-chain language | TypeScript (viem) |
| Package manager | pnpm (monorepo) |
| Target chains | Ethereum mainnet + Arbitrum |
| Stake denomination | USDC |
| Commitment timeout | Taker reclaims (no reopening) |
| Unresolved dispute default | Fill-valid (prevents griefing) |
| Governance token | None. Never. |

---

## Repo Structure

```
gauloi-v2/
├── contracts/                     # Foundry
│   ├── foundry.toml
│   ├── src/
│   │   ├── types/DataTypes.sol    # Shared structs + enums
│   │   ├── interfaces/            # IGauloiEscrow, IGauloiStaking, IGauloiDisputes
│   │   ├── libraries/
│   │   │   ├── IntentLib.sol      # Intent hashing helpers
│   │   │   └── SignatureLib.sol   # EIP-712 verification
│   │   ├── GauloiStaking.sol
│   │   ├── GauloiEscrow.sol
│   │   └── GauloiDisputes.sol
│   ├── test/
│   │   ├── unit/
│   │   ├── integration/
│   │   └── fork/
│   └── script/                    # Deployment scripts
│
├── packages/                      # pnpm workspaces
│   ├── common/                    # Shared types, ABIs, chain configs
│   ├── relay/                     # Off-chain RFQ relay (WebSocket)
│   ├── maker/                     # Maker bot
│   └── cli/                       # Dev/testing CLI (act as taker)
│
├── docs/                          # Blog posts + spec
├── pnpm-workspace.yaml
└── .env.example
```

## Contract Architecture

Three contracts, not one monolith. Keeps each under the 24KB limit, cleaner separation, easier to audit.

**Dependency graph:**
```
DataTypes.sol (shared structs/enums)
  ├── GauloiStaking.sol    (standalone — stake, unstake, exposure, slash)
  ├── GauloiEscrow.sol     (calls Staking for exposure tracking)
  └── GauloiDisputes.sol   (calls Staking for slashing, Escrow for state)
```

Each chain gets its own deployment of all three contracts. No cross-chain messaging at the contract level — the maker bot is the bridge.

### State Machine

```
[Off-chain: Taker signs EIP-712 order]
         │
         ▼
    Committed ──→ Filled ──→ Settled
         │            │
         └→ Expired   └→ Disputed ──→ Settled (fill valid)
            (reclaim)                  └→ Refunded (fill invalid)
```

There is no on-chain `Open` state — the taker signs an order off-chain (0 gas). The maker calls `executeOrder` with the signed order, pulling tokens from the taker and creating the `Committed` state directly. Committed + timeout = taker reclaims. No reopening.

### Key Contract Functions

**GauloiStaking.sol**
- `stake(amount)` — deposit USDC, become active maker
- `requestUnstake(amount)` / `completeUnstake()` — two-step with cooldown
- `increaseExposure(maker, amount)` — called by Escrow on commit (permissioned)
- `decreaseExposure(maker, amount)` — called by Escrow on settle/reclaim (permissioned)
- `slash(maker, intentId)` → `uint256` — called by Disputes on fraud (permissioned)
- `availableCapacity(maker)` → `uint256` — `stakedAmount - activeExposure`

**GauloiEscrow.sol**
- `executeOrder(Order calldata order, bytes calldata takerSignature)` → `bytes32 intentId` — maker executes a taker's EIP-712 signed order: verifies signature, pulls tokens from taker, writes Commitment (3 storage slots), starts commitment deadline
- `submitFill(intentId, destTxHash)` — maker submits fill evidence, starts dispute window
- `settle(Order calldata order)` — anyone calls after dispute window, releases escrow to maker
- `settleBatch(Order[] calldata orders)` — batch settle, skips failures (try/catch internally)
- `reclaimExpired(Order calldata order)` — taker reclaims on commitment timeout

**GauloiDisputes.sol**
- `dispute(Order calldata order)` — staked maker posts bond, stores order for later resolution, pauses settlement
- `resolveDispute(intentId, fillValid, signatures)` — M/N EIP-712 attestations from staked makers
- Bond: `max(fillAmount * 50bps, 25 USDC)`
- Fill valid → disputer bond slashed. Fill invalid → maker's entire stake slashed, taker refunded.
- Unresolved by deadline → defaults to fill-valid

### Intent ID

```solidity
intentId = keccak256(abi.encode(taker, inputToken, inputAmount, outputToken,
    minOutputAmount, destChainId, destAddress, expiry, nonce))
```

Nonce is part of the signed order (random, chosen by taker off-chain). Replay protection: `_commitments[intentId].taker == address(0)` check prevents double execution. No on-chain nonce storage needed.

### Initial Parameters

| Parameter | Ethereum | Arbitrum |
|-----------|----------|----------|
| Settlement window | 15 min | 30 min |
| Commitment timeout | 5 min | 5 min |
| Min stake | 10,000 USDC | 10,000 USDC |
| Exposure multiplier | 1× | 1× |
| Unstake cooldown | 48 hours | 48 hours |
| Dispute resolution window | 24 hours | 24 hours |
| Dispute bond | max(0.5% of fill, 25 USDC) | same |
| Dispute threshold | 2/3 of staked makers | 2/3 |

---

## Phases

### Phase 0: Scaffolding
- `forge init` in `contracts/`, install forge-std + openzeppelin
- pnpm workspace with `packages/common`, `packages/relay`, `packages/maker`, `packages/cli`
- `foundry.toml` with fork testing config (Ethereum + Arbitrum RPC URLs)
- TypeScript config (tsconfig, vitest)
- `.env.example`, `.gitignore`
- Save blog posts to `docs/`

### Phase 1: Staking Contract
- `DataTypes.sol` — Intent struct, MakerInfo struct, Dispute struct, IntentState enum
- `GauloiStaking.sol` — stake, unstake (two-step + cooldown), exposure tracking, slashing
- Access control: owner sets Escrow + Disputes contract addresses as authorized callers
- OpenZeppelin: `SafeERC20`, `ReentrancyGuard`, `Ownable`
- **Tests**: stake/unstake lifecycle, cooldown enforcement, exposure limits, slashing, access control
- MockERC20 for USDC in tests

### Phase 2: Escrow Contract
- `IntentLib.sol` — intent ID generation via `computeIntentId(Order)`, `hashOrder` for EIP-712, `ORDER_TYPEHASH`
- `SignatureLib.sol` — EIP-712 domain builder, `recoverOrderSigner` for taker signature verification
- `GauloiEscrow.sol` — EIP-712 signed order flow: `executeOrder` (verifies taker sig, pulls tokens, writes 3-slot Commitment), `submitFill`, `settle(Order)`, `settleBatch(Order[])`, `reclaimExpired(Order)`
- Token whitelist (only USDC/USDT for v0.1)
- Calls Staking for exposure checks on executeOrder, exposure release on settle/reclaim
- `SafeERC20` for all transfers (USDT doesn't return bool)
- `ReentrancyGuard` on all token-transferring functions
- **Tests**: happy path, order expiry, commitment timeout, batch settle, capacity enforcement, signature verification, replay protection

### Phase 3: Disputes Contract
- `SignatureLib.sol` — EIP-712 domain, FillAttestation type, signature recovery + threshold verification
- `GauloiDisputes.sol` — dispute, resolveDispute, bond calculation
- On fraud: slash maker via Staking, refund taker via Escrow
- **Tests**: dispute lifecycle (both outcomes), signature verification, bond math, deadline default

### Phase 4: Integration + Fork Tests
- Deploy all three contracts together, run full lifecycle
- Fork tests with real USDC on mainnet fork (`vm.deal`)
- Cross-chain simulation: two forks (`vm.createFork`), deploy on both, simulate fill across forks
- Gas benchmarking (`forge test --gas-report`)

### Phase 5: TypeScript Common Package
- ABI generation from Foundry build artifacts (`contracts/out/`)
- Type definitions mirroring Solidity structs
- Chain configs (RPC URLs, contract addresses, settlement windows)
- viem client factory

### Phase 6: Relay Service
- WebSocket + HTTP server (hono or fastify + ws)
- Taker broadcasts intent → relay pushes to connected makers
- Makers submit quotes → relay delivers to taker
- Taker selects quote → relay notifies winning maker
- In-memory store (no DB for v0.1)
- Message types: `IntentBroadcast`, `MakerQuote`, `QuoteAccepted`

### Phase 7: Maker Bot
- **Relay listener**: receive intents via WebSocket
- **Compliance screener**: stub interface (allowlist/denylist JSON config), pluggable for Chainalysis/TRM later
- **Quoter**: spread-based pricing (configurable bps per risk tier)
- **Filler**: on quote acceptance → `executeOrder(order, takerSignature)` → transfer on dest chain → `submitFill()`
- **Settler**: periodic loop, `settleBatch()` for all matured intents
- **Dispute watcher**: verify all `FillSubmitted` events against dest chain RPC, dispute if invalid, sign attestations

### Phase 8: CLI + E2E Testing
- CLI commands: `create-intent`, `list-intents`, `status`
- E2E test: two Anvil instances → deploy → relay + maker bot → taker creates intent → full settlement
- Dispute E2E: maker submits fake fill → watcher disputes → resolution

### Phase 9: Testnet Deployment
- Deploy to Sepolia + Arbitrum Sepolia
- Run relay + maker bot against testnets
- Execute 10-20 settlement loops
- Test edge cases manually (expiry, timeout, dispute)

---

## Out of Scope (v0.1)

- Tron / Solana / Bitcoin
- Multi-hop routing
- KYC attestation integration (Worldcoin, Coinbase Verifications)
- Governance / timelock for parameter updates
- Production compliance APIs
- Consumer frontend
- Multi-maker competition
- Proxy/upgradeability patterns

---

## Verification

1. **Contracts**: `forge test` — all unit, integration, and fork tests pass
2. **Gas**: `forge test --gas-report` — settle < 200k gas, batch settle < 100k amortized
3. **E2E**: scripted test with two Anvil instances, relay, maker bot → full settlement loop completes
4. **Testnet**: 20+ successful settlements on Sepolia + Arbitrum Sepolia
