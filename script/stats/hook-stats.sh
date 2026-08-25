#!/bin/bash
# Fetch and summarize hook events from Etherscan API.
# Usage: ./script/hook-stats.sh [FROM_BLOCK] [TO_BLOCK]

set -e
source "$(dirname "$0")/../.env"

HOOK="${HOOK_ADDRESS:-0xe9aef6479166f271825610143d4ee047fb288cc05c48dbac7b8c7e2679eb892e}"
FROM_BLOCK="${1:-${FROM_BLOCK:-	25028398}}"
TO_BLOCK="${2:-${TO_BLOCK:-latest}}"

export ETHERSCAN_API_KEY
exec python3 "$(dirname "$0")/hook_stats.py" "$HOOK" "$FROM_BLOCK" "$TO_BLOCK"
