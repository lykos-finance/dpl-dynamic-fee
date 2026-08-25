#!/bin/bash
# Fetch Swap-event stats for the no-hook pool on mainnet.
# Pool: WETH/USDT, fee=3000, tickSpacing=58, hooks=address(0)
# Usage: ./script/pool-stats-nohook.sh [FROM_BLOCK] [TO_BLOCK]

set -e
source "$(dirname "$0")/../.env"

POOL_MANAGER="0x000000000004444c5dc75cB358380D2e3dE08A90"
WETH="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
USDT="0xdAC17F958D2ee523a2206206994597C13D831ec7"

# Compute poolId on the fly: keccak256(abi.encode(token0, token1, fee, tickSpacing, hooks))
POOL_ID=$(cast keccak "$(cast abi-encode 'x((address,address,uint24,int24,address))' "($WETH,$USDT,3000,58,0x0000000000000000000000000000000000000000)")")

FROM_BLOCK="${1:-${FROM_BLOCK:-0}}"
TO_BLOCK="${2:-${TO_BLOCK:-latest}}"

# Auto-detect deploy block if FROM_BLOCK=0
if [ "$FROM_BLOCK" = "0" ]; then
  DEPLOY_FILE=$(ls -t "$(dirname "$0")/../broadcast/InitPoolNoHook.s.sol/1/run-"*.json 2>/dev/null | tail -1)
  if [ -n "$DEPLOY_FILE" ]; then
    FROM_BLOCK=$(python3 -c "
import json
d = json.load(open('$DEPLOY_FILE'))
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

echo "PoolId: $POOL_ID"
echo

export ETHERSCAN_API_KEY
export CHAIN_ID=1
exec python3 "$(dirname "$0")/pool_swap_stats.py" "$POOL_MANAGER" "$POOL_ID" "$FROM_BLOCK" "$TO_BLOCK"
