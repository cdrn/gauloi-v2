#!/bin/bash
# Extracts ABIs from Foundry build artifacts into TypeScript constants
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONTRACTS_OUT="$REPO_ROOT/contracts/out"
ABI_DIR="$SCRIPT_DIR/../src/abis"

mkdir -p "$ABI_DIR"

extract_abi() {
    local contract_name=$1
    local artifact="$CONTRACTS_OUT/${contract_name}.sol/${contract_name}.json"

    if [ ! -f "$artifact" ]; then
        echo "ERROR: artifact not found: $artifact"
        exit 1
    fi

    # Extract ABI array from the artifact JSON
    local abi
    abi=$(node -e "const a = require('$artifact'); console.log(JSON.stringify(a.abi, null, 2))")

    cat > "$ABI_DIR/${contract_name}.ts" << EOF
export const ${contract_name}Abi = ${abi} as const;
EOF

    echo "Generated ${contract_name}.ts"
}

extract_abi "GauloiStaking"
extract_abi "GauloiEscrow"
extract_abi "GauloiDisputes"

# Generate barrel export
cat > "$ABI_DIR/index.ts" << 'EOF'
export { GauloiStakingAbi } from "./GauloiStaking.js";
export { GauloiEscrowAbi } from "./GauloiEscrow.js";
export { GauloiDisputesAbi } from "./GauloiDisputes.js";
EOF

echo "ABI generation complete"
