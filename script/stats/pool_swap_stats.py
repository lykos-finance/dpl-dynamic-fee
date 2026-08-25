#!/usr/bin/env python3
"""Fetch and summarize Uniswap v4 Swap events for a specific poolId.

Usage: pool_swap_stats.py <pool_manager> <pool_id> <from_block> <to_block>
Needs: ETHERSCAN_API_KEY, CHAIN_ID in environment.
"""
import os
import sys
import json
import urllib.request
import urllib.parse
from datetime import datetime, timezone


# Swap event signature: keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
TOPIC_SWAP = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"
# ModifyLiquidity event
TOPIC_MODIFY_LIQUIDITY = "0xf208f4912782fd25c7f114ca3723a2d5dd6f3bcc3ac8db5af63baa85f711d5ec"


def decode_int24(hex_str):
    """Decode a signed int24 from hex (rightmost 6 chars represent the int24)."""
    raw = int(hex_str[-6:], 16)
    if raw >= 1 << 23:
        raw -= 1 << 24
    return raw


def decode_int128(hex_str):
    """Decode a sign-extended int128 from a 64-hex-char (32-byte) ABI-encoded word."""
    raw = int(hex_str, 16)
    # ABI sign-extends int128 to int256 — convert from uint256 to int256
    if raw >= 1 << 255:
        raw -= 1 << 256
    return raw


def decode_swap(data_hex):
    """
    Decode Swap event data.
    Layout: amount0 (int128), amount1 (int128), sqrtPriceX96 (uint160),
            liquidity (uint128), tick (int24), fee (uint24)
    All packed into 32-byte words.
    """
    d = data_hex[2:] if data_hex.startswith("0x") else data_hex
    amount0 = decode_int128(d[0:64])
    amount1 = decode_int128(d[64:128])
    sqrt_price = int(d[128:192], 16)
    liquidity = int(d[192:256], 16)
    tick = decode_int24(d[256:320])
    fee = int(d[320:384], 16) & 0xFFFFFF
    return amount0, amount1, sqrt_price, liquidity, tick, fee


def main():
    pool_manager = sys.argv[1]
    pool_id = sys.argv[2]
    from_block = sys.argv[3]
    to_block = sys.argv[4]
    chain_id = os.environ.get("CHAIN_ID", "1")
    api_key = os.environ.get("ETHERSCAN_API_KEY", "")
    if not api_key:
        print("ERROR: ETHERSCAN_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    params = {
        "chainid": chain_id,
        "module": "logs",
        "action": "getLogs",
        "fromBlock": from_block,
        "toBlock": to_block,
        "address": pool_manager,
        "topic0": TOPIC_SWAP,
        "topic1": pool_id,
        "topic0_1_opr": "and",
        "apikey": api_key,
    }
    url = "https://api.etherscan.io/v2/api?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=30) as r:
        data = json.loads(r.read())

    if data.get("status") != "1":
        print(f"Etherscan response: {data.get('message')}")
        if data.get("result") and not isinstance(data['result'], list):
            print(f"  {data['result']}")
        return

    logs = data["result"]
    print(f"=== Pool Swap Stats ===")
    print(f"Chain:        {chain_id}")
    print(f"PoolManager:  {pool_manager}")
    print(f"PoolId:       {pool_id}")
    print(f"Blocks:       {from_block}..{to_block}")
    print(f"Total swaps:  {len(logs)}")
    print()

    if not logs:
        return

    # Decode all swaps
    decoded = []
    total_volume_0 = 0
    total_volume_1 = 0
    total_fee_pay_0 = 0
    total_fee_pay_1 = 0
    fee_distribution = {}
    senders = {}

    for log in logs:
        amount0, amount1, sqrt_price, liq, tick, fee = decode_swap(log["data"])
        sender = "0x" + log["topics"][2][26:]
        block = int(log["blockNumber"], 16)
        ts = int(log.get("timeStamp", "0x0"), 16)
        tx = log["transactionHash"]
        decoded.append({
            "block": block,
            "ts": ts,
            "tx": tx,
            "sender": sender,
            "amount0": amount0,
            "amount1": amount1,
            "sqrt_price": sqrt_price,
            "liquidity": liq,
            "tick": tick,
            "fee": fee,
        })
        total_volume_0 += abs(amount0)
        total_volume_1 += abs(amount1)
        # Negative amounts = pool sends to user; positive = user sends to pool (incl. fee)
        if amount0 > 0: total_fee_pay_0 += amount0
        if amount1 > 0: total_fee_pay_1 += amount1
        fee_distribution[fee] = fee_distribution.get(fee, 0) + 1
        senders[sender] = senders.get(sender, 0) + 1

    # Detail per swap
    print("=== Swaps detail ===")
    prev_tick = None
    for s in decoded:
        when = datetime.fromtimestamp(s["ts"], tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC") if s["ts"] else "?"
        direction = "BUY  WETH" if s["amount0"] < 0 else "SELL WETH"
        # WETH/USDT pool: token0=WETH (18 dec), token1=USDT (6 dec)
        weth_amt = abs(s["amount0"]) / 1e18
        usdt_amt = abs(s["amount1"]) / 1e6
        drift = ""
        if prev_tick is not None:
            d = s["tick"] - prev_tick
            drift = f" drift={d:+d}"
        print(f"  {when}  block={s['block']}  fee={s['fee']:>5d}  {direction}  WETH={weth_amt:.6f}  USDT={usdt_amt:.4f}{drift}  tick={s['tick']}  tx={s['tx'][:14]}...")
        prev_tick = s["tick"]

    # Aggregate stats
    print()
    print("=== Aggregates ===")
    print(f"Volume token0 (WETH):  {total_volume_0/1e18:.6f}")
    print(f"Volume token1 (USDT):  {total_volume_1/1e6:.4f}")
    print()
    print(f"Token0 paid INTO pool (incl. fees): {total_fee_pay_0/1e18:.6f} WETH")
    print(f"Token1 paid INTO pool (incl. fees): {total_fee_pay_1/1e6:.4f} USDT")
    print()
    print(f"Fee distribution (pips × count):")
    for fee, count in sorted(fee_distribution.items()):
        pct = fee / 1e6 * 100
        print(f"  fee={fee:>5d} ({pct:.4f}%): {count} swaps")
    print()
    print(f"Top senders:")
    for sender, count in sorted(senders.items(), key=lambda x: -x[1])[:5]:
        print(f"  {sender}: {count} swaps")


if __name__ == "__main__":
    main()
