# Gauloi v2

Cross-chain stablecoin settlement protocol with maker-level compliance and optimistic settlement.

## Conventions

### Git
- Use conventional commits: `feat:`, `fix:`, `test:`, `docs:`, `chore:`, `refactor:`
- Scope by component when relevant: `feat(escrow):`, `feat(staking):`, `feat(disputes):`, `feat(relay):`, `feat(maker):`
- Commit often — at minimum per phase of the implementation plan
- Do NOT add Co-Authored-By lines to commits

### Contracts
- Foundry (forge) for build, test, deploy
- Solidity ^0.8.24
- OpenZeppelin for SafeERC20, ReentrancyGuard, Ownable, ECDSA
- Three contracts: GauloiStaking, GauloiEscrow, GauloiDisputes
- Shared types in `contracts/src/types/DataTypes.sol`

### TypeScript
- pnpm workspaces monorepo
- viem for chain interaction
- Packages: common, relay, maker, cli

## Architecture

See `plan.md` for full implementation plan and `docs/` for design blog posts.
