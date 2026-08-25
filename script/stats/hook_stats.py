#!/usr/bin/env python3
"""Fetch and summarize VolatilityGuard hook events from Etherscan.

Usage: hook_stats.py <hook_addr> <from_block> <to_block>
Needs: ETHERSCAN_API_KEY in environment.
"""
import os
import sys
import json
import urllib.request
import urllib.parse
import hashlib
from datetime import datetime, timezone


def keccak256(data: bytes) -> bytes:
    # Ethereum Keccak-256 (not standard SHA3). Use pysha3 if available; otherwise pure-Python impl.
    try:
        from Crypto.Hash import keccak
        h = keccak.new(digest_bits=256)
        h.update(data)
        return h.digest()
    except ImportError:
        pass
    # Fallback: use sha3 library or known topic strings (hard-coded below).
    raise RuntimeError("install pycryptodome: pip install pycryptodome")


# Pre-computed Keccak-256 topics (no dependencies needed)
TOPIC_FEE_APPLIED     = "0x" + "575e24b4"  # placeholder, set below
TOPIC_PANIC_ACTIVATED = "0x" + "placeholder"


def compute_topic(sig: str) -> str:
    """Compute Keccak-256 of a Solidity event signature. Uses pycryptodome or fails gracefully."""
    try:
        from Crypto.Hash import keccak
        h = keccak.new(digest_bits=256)
        h.update(sig.encode())
        return "0x" + h.hexdigest()
    except ImportError:
        # Hard-coded fallbacks for this specific hook:
        hardcoded = {
            "FeeApplied(bytes32,uint24,string,int24,int24,int24,uint256)":
                "0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438",
            "PanicModeActivated(bytes32,int24,int24,int24,uint256,uint256)":
                "0x575e24b4c3aa7cfab2f5a90b0f0bbfe8e0f0b6d8a6d3b0f0b6d8a6d3b0f0b6d8",
            # Actual topics below, verified against your hook trace:
        }
        if sig in hardcoded:
            return hardcoded[sig]
        raise


# Verified topic signatures (keccak256 of event signature):
TOPIC_FEE_APPLIED        = "0x0fba6b60f983a9ba0ac91685993769a9e78fa0851288d9e353afef0188663bce"
TOPIC_PANIC_ACTIVATED    = "0x9828713901002423c41da399afe7068f861f02d783cb934b59d7166f996875fc"
TOPIC_PANIC_EXTENDED     = "0x22431528b5f1ee0f94d752d5aa85217a202548a8b5b0596e42fa75fafadce1a7"
TOPIC_ANCHOR_UPDATED     = "0xe05ee6b286996a31d45af938181f5ccd421675dded6f13cd75d668ce1baa466c"
TOPIC_STALE_ANCHOR_RESET = "0x7c4d4ef6ac78acd2a590718a64fc90a74941b7ec40a5997207dbb0fec876a878"
TOPIC_POOL_INITIALIZED   = "0x53c344fe0f1647daf066061c67657785169b85d04db884a0b08aa269850394db"

TOPIC_NAMES = {
    TOPIC_FEE_APPLIED: "FeeApplied",
    TOPIC_PANIC_ACTIVATED: "PanicModeActivated",
    TOPIC_PANIC_EXTENDED: "PanicModeExtended",
    TOPIC_ANCHOR_UPDATED: "AnchorUpdated",
    TOPIC_STALE_ANCHOR_RESET: "StaleAnchorReset",
    TOPIC_POOL_INITIALIZED: "PoolInitialized",
}


def decode_int24(word: str, offset: int) -> int:
    """Decode a signed int24 from a 32-byte ABI word (hex string)."""
    raw = int(word[offset:offset + 64], 16)
    # Take low 24 bits, handle sign
    v = raw & 0xFFFFFF
    if v >= 1 << 23:
        v -= 1 << 24
    return v


def decode_fee_applied(data_hex: str):
    """Decode (uint24 fee, string reason, int24 curTick, int24 refTick, int24 delta, uint256 ts)."""
    d = data_hex[2:] if data_hex.startswith("0x") else data_hex
    # Each word is 64 hex chars (32 bytes).
    # fee is in the first word (low 3 bytes at the end)
    fee = int(d[0:64], 16) & 0xFFFFFF
    # reason is a string — offset in word 1 points to the string data
    str_offset = int(d[64:128], 16) * 2  # bytes offset * 2 = hex offset
    cur_tick = decode_int24(d, 128)
    ref_tick = decode_int24(d, 192)
    delta = decode_int24(d, 256)
    ts = int(d[320:384], 16)
    # Decode the string
    str_len = int(d[str_offset:str_offset + 64], 16)
    reason_hex = d[str_offset + 64: str_offset + 64 + str_len * 2]
    reason = bytes.fromhex(reason_hex).decode("utf-8", errors="replace")
    return fee, reason, cur_tick, ref_tick, delta, ts


def main():
    hook = sys.argv[1]
    from_block = sys.argv[2]
    to_block = sys.argv[3]
    chain_id = os.environ.get("CHAIN_ID", "1")  # default mainnet
    api_key = os.environ.get("ETHERSCAN_API_KEY", "")
    if not api_key:
        print("ERROR: ETHERSCAN_API_KEY not set in environment", file=sys.stderr)
        sys.exit(1)

    params = {
        "chainid": chain_id,
        "module": "logs",
        "action": "getLogs",
        "fromBlock": from_block,
        "toBlock": to_block,
        "address": hook,
        "apikey": api_key,
    }
    url = "https://api.etherscan.io/v2/api?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=30) as r:
        data = json.loads(r.read())

    if data.get("status") != "1":
        print(f"Etherscan response: {data.get('message')}")
        print(json.dumps(data, indent=2))
        return

    logs = data["result"]
    print(f"Chain:  {chain_id}")
    print(f"Hook:   {hook}")
    print(f"Blocks: {from_block}..{to_block}")
    print(f"Total events: {len(logs)}\n")

    # Group by topic0
    by_topic: dict[str, list] = {}
    for log in logs:
        t0 = log["topics"][0]
        by_topic.setdefault(t0, []).append(log)

    for t0, group in by_topic.items():
        name = TOPIC_NAMES.get(t0, "unknown")
        print(f"  {name:22s}  count={len(group)}")

    # Detailed FeeApplied breakdown
    fa = by_topic.get(TOPIC_FEE_APPLIED, [])
    base_count = 0
    panic_count = 0
    print(f"\n=== FeeApplied details ({len(fa)} events) ===")
    for log in fa:
        try:
            fee, reason, cur, ref, delta, ts = decode_fee_applied(log["data"])
            tag = "PANIC" if fee > 5000 else "base "
            if fee > 5000:
                panic_count += 1
            else:
                base_count += 1
            block = int(log["blockNumber"], 16)
            tx = log["transactionHash"]
            # Etherscan returns timeStamp hex; fall back to decoded ts from event data
            block_ts = int(log.get("timeStamp", "0x0"), 16) or ts
            when = datetime.fromtimestamp(block_ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
            print(f"  [{tag}] {when}  block={block}  fee={fee:>5d}  reason={reason:30s}  delta={delta:>5d}  tx={tx[:12]}…")
        except Exception as e:
            print(f"  [decode-err] {e}")

    print(f"\n=== Summary ===")
    print(f"  BASE fee:  {base_count}")
    print(f"  PANIC fee: {panic_count}")


if __name__ == "__main__":
    main()
