#!/usr/bin/env bash
set -euo pipefail

# Deploy Gauloi v2 contracts to Sepolia + Arbitrum Sepolia
# Requires: PRIVATE_KEY env var (deployer account with testnet ETH on both chains)
# Get testnet USDC from: https://faucet.circle.com/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTRACTS_DIR="$ROOT_DIR/contracts"
DEPLOYMENTS_DIR="$ROOT_DIR/deployments"

# Check required env
if [ -z "${PRIVATE_KEY:-}" ]; then
  echo "Error: PRIVATE_KEY env var required"
  echo "Export a private key with testnet ETH on Sepolia + Arbitrum Sepolia"
  exit 1
fi

# RPC endpoints
SEPOLIA_RPC="${SEPOLIA_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
ARB_SEPOLIA_RPC="${ARBITRUM_SEPOLIA_RPC_URL:-https://arbitrum-sepolia-rpc.publicnode.com}"

# Circle testnet USDC addresses
SEPOLIA_USDC="0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
ARB_SEPOLIA_USDC="0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d"

# Testnet parameters (shorter for faster testing)
export MIN_STAKE="10000000"           # 10 USDC
export COOLDOWN="300"                 # 5 minutes
export SETTLEMENT_WINDOW="120"        # 2 minutes
export COMMITMENT_TIMEOUT="120"       # 2 minutes
export RESOLUTION_WINDOW="300"        # 5 minutes
export BOND_BPS="50"                  # 0.5%
export MIN_BOND="100000"              # 0.1 USDC

parse_addresses() {
  local output="$1"
  local json="{}"

  local usdc=$(echo "$output" | grep "USDC" | grep -oE '0x[0-9a-fA-F]{40}' | head -1)
  local staking=$(echo "$output" | grep "Staking:" | grep -oE '0x[0-9a-fA-F]{40}' | head -1)
  local escrow=$(echo "$output" | grep "Escrow:" | grep -oE '0x[0-9a-fA-F]{40}' | head -1)
  local disputes=$(echo "$output" | grep "Disputes:" | grep -oE '0x[0-9a-fA-F]{40}' | head -1)

  cat <<EOF
{
  "usdc": "$usdc",
  "staking": "$staking",
  "escrow": "$escrow",
  "disputes": "$disputes"
}
EOF
}

echo "========================================="
echo "  Gauloi v2 — Testnet Deployment"
echo "========================================="
echo ""

# --- Deploy to Sepolia ---
echo ">>> Deploying to Sepolia (chainId: 11155111)..."
echo "    RPC: $SEPOLIA_RPC"
echo "    USDC: $SEPOLIA_USDC"
echo ""

SEPOLIA_OUTPUT=$(cd "$CONTRACTS_DIR" && \
  DEPLOYER_KEY="$PRIVATE_KEY" \
  USDC_ADDRESS="$SEPOLIA_USDC" \
  forge script script/Deploy.s.sol:Deploy \
    --rpc-url "$SEPOLIA_RPC" \
    --broadcast \
    --slow \
    2>&1) || {
  echo "Sepolia deployment failed:"
  echo "$SEPOLIA_OUTPUT"
  exit 1
}

echo "$SEPOLIA_OUTPUT"
SEPOLIA_JSON=$(parse_addresses "$SEPOLIA_OUTPUT")
echo "$SEPOLIA_JSON" > "$DEPLOYMENTS_DIR/sepolia.json"
echo ""
echo ">>> Sepolia addresses saved to deployments/sepolia.json"
echo "$SEPOLIA_JSON"
echo ""

# --- Deploy to Arbitrum Sepolia ---
echo ">>> Deploying to Arbitrum Sepolia (chainId: 421614)..."
echo "    RPC: $ARB_SEPOLIA_RPC"
echo "    USDC: $ARB_SEPOLIA_USDC"
echo ""

ARB_OUTPUT=$(cd "$CONTRACTS_DIR" && \
  DEPLOYER_KEY="$PRIVATE_KEY" \
  USDC_ADDRESS="$ARB_SEPOLIA_USDC" \
  forge script script/Deploy.s.sol:Deploy \
    --rpc-url "$ARB_SEPOLIA_RPC" \
    --broadcast \
    --slow \
    2>&1) || {
  echo "Arbitrum Sepolia deployment failed:"
  echo "$ARB_OUTPUT"
  exit 1
}

echo "$ARB_OUTPUT"
ARB_JSON=$(parse_addresses "$ARB_OUTPUT")
echo "$ARB_JSON" > "$DEPLOYMENTS_DIR/arbitrum-sepolia.json"
echo ""
echo ">>> Arbitrum Sepolia addresses saved to deployments/arbitrum-sepolia.json"
echo "$ARB_JSON"
echo ""

echo "========================================="
echo "  Deployment complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "  1. Get testnet USDC from https://faucet.circle.com/"
echo "  2. Run the smoke test: npx tsx scripts/testnet-smoke.ts"
