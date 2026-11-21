#!/usr/bin/env bash
# Update web/src/deployments.json for one chain. No secrets.
# Usage: write-web-config.sh <chainId> <prooflockAddress> [usdcAddress]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="${DEPLOYMENTS_PATH:-$ROOT/web/src/deployments.json}"
CHAIN_ID=${1:?chain id}
ESCROW=${2:?prooflock address}
USDC=${3:-}
if [ ! -f "$FILE" ]; then
  echo "write-web-config: $FILE not found" >&2
  exit 1
fi
tmp="$(mktemp)"
if [ -n "$USDC" ]; then
  jq --arg c "$CHAIN_ID" --arg e "$ESCROW" --arg u "$USDC" \
    '.[$c] = ((.[$c] // {}) | .prooflock = $e | .usdc = $u)' "$FILE" > "$tmp"
else
  jq --arg c "$CHAIN_ID" --arg e "$ESCROW" \
    '.[$c] = ((.[$c] // {}) | .prooflock = $e)' "$FILE" > "$tmp"
fi
mv "$tmp" "$FILE"
echo "Wrote prooflock $ESCROW to web/src/deployments.json (chain $CHAIN_ID)"
