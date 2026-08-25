#!/bin/bash
# V3 hook stats on mainnet via Etherscan V2 API.
# Usage: ./script/hook-stats-v3.sh [FROM_BLOCK] [TO_BLOCK]

set -e
source "$(dirname "$0")/../.env"

HOOK="${HOOK_ADDRESS_V3:?HOOK_ADDRESS_V3 not set in .env}"
FROM_BLOCK="${1:-${FROM_BLOCK:-0}}"
TO_BLOCK="${2:-${TO_BLOCK:-latest}}"

# Auto-detect deploy block if FROM_BLOCK=0
if [ "$FROM_BLOCK" = "0" ]; then
  DEPLOY_FILE=$(ls -t "$(dirname "$0")/../broadcast/DeployV3.s.sol/1/run-"*.json 2>/dev/null | tail -1)
  if [ -n "$DEPLOY_FILE" ]; then
    FROM_BLOCK=$(python3 -c "
import json
d = json.load(open('$DEPLOY_FILE'))
hook = '$HOOK'.lower()
for r in d.get('receipts', []):
    addr = r.get('contractAddress')
    if addr and addr.lower() == hook:
        print(int(r['blockNumber'], 16))
        exit()
recs = d.get('receipts', [])
if recs:
    print(int(recs[0]['blockNumber'], 16))
else:
    print(0)
")
  fi
  if [ -z "$FROM_BLOCK" ] || [ "$FROM_BLOCK" = "0" ]; then
    echo "Could not auto-detect deploy block. Pass FROM_BLOCK explicitly:"
    echo "  $0 <from_block> [to_block]"
    exit 1
  fi
fi

export ETHERSCAN_API_KEY
export CHAIN_ID=1
exec python3 "$(dirname "$0")/hook_stats.py" "$HOOK" "$FROM_BLOCK" "$TO_BLOCK"
