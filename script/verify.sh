#!/usr/bin/env bash
# Verify deployed contracts on Etherscan v2 (one API key works for Ethereum 1 and Base 8453).
#   ./script/verify.sh prooflock <prooflockAddress> <usdcAddress> <ownerAddress>
# Env: RPC_URL (to detect chain), ETHERSCAN_API_KEY. Key is never echoed.
set -euo pipefail
export PATH="${HOME}/.foundry/bin:${PATH}"
: "${RPC_URL:?set RPC_URL}"
: "${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY (Etherscan v2 key)}"
KIND=${1:?prooflock}; ADDR=${2:?address}
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
case "$CHAIN_ID" in 1) echo "==> Chain: Ethereum mainnet (1)";; 8453) echo "==> Chain: Base (8453)";; *) echo "Unsupported chain $CHAIN_ID" >&2; exit 1;; esac
COMMON=(--chain "$CHAIN_ID" --watch --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=$CHAIN_ID")
case "$KIND" in
  prooflock)
    USDC=${3:?usdc address}
    OWNER=${4:?owner / fee recipient address}
    forge verify-contract "$ADDR" src/Prooflock.sol:Prooflock "${COMMON[@]}" \
      --constructor-args "$(cast abi-encode 'constructor(address,address,address)' "$USDC" "$OWNER" "$OWNER")"
    ;;
  *) echo "first arg must be prooflock" >&2; exit 1 ;;
esac
