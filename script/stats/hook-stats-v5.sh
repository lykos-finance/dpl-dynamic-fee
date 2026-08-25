#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# hook-stats-v5.sh  —  VolatilityGuardHookV5 on-chain analytics
#
# Usage:
#   ./hook-stats-v5.sh [FROM_BLOCK] [TO_BLOCK]
#   ./hook-stats-v5.sh 20000000 latest
#   ./hook-stats-v5.sh          # auto-detects deploy block from broadcast/
#
# Required env (.env or exported):
#   HOOK_ADDRESS_V5      — deployed hook address (0x...)
#   ETHERSCAN_API_KEY    — Etherscan v2 API key
#
# Optional env:
#   FROM_BLOCK           — fallback start block (default: 0 → auto-detect)
#   TO_BLOCK             — end block          (default: latest)
#   CHAIN_ID             — chain id           (default: 1 mainnet)
#   OUTPUT_DIR           — where to write CSV/JSON (default: ./stats-out)
#   PANIC_THRESHOLD      — tick delta for panic (default: 60)
#   PANIC_DURATION       — panic window in sec  (default: 300)
#
# Dependencies: curl, python3  (no jq required)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Load .env ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

# ── Config ───────────────────────────────────────────────────────────────────
HOOK="${HOOK_ADDRESS_V5:?HOOK_ADDRESS_V5 not set}"
FROM_BLOCK="${1:-${FROM_BLOCK:-0}}"
TO_BLOCK="${2:-${TO_BLOCK:-latest}}"
CHAIN_ID="${CHAIN_ID:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/stats-out}"
PANIC_THRESHOLD="${PANIC_THRESHOLD:-60}"
PANIC_DURATION="${PANIC_DURATION:-300}"
ETHERSCAN_BASE="https://api.etherscan.io/v2/api"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

log()  { echo -e "${CYN}[INFO]${RST}  $*"; }
warn() { echo -e "${YEL}[WARN]${RST}  $*"; }
err()  { echo -e "${RED}[ERR]${RST}   $*" >&2; }
ok()   { echo -e "${GRN}[OK]${RST}    $*"; }

# ── Dependency check — only curl + python3 ───────────────────────────────────
check_deps() {
  local missing=()
  for cmd in curl python3; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing dependencies: ${missing[*]}"
    err "Install with: apt install ${missing[*]}  OR  brew install ${missing[*]}"
    exit 1
  fi
}

# ── Auto-detect deploy block ─────────────────────────────────────────────────
resolve_from_block() {
  [[ "$FROM_BLOCK" != "0" ]] && return

  log "FROM_BLOCK=0 → searching broadcast/ for deploy receipt..."

  local broadcast_dir="${SCRIPT_DIR}/../broadcast"
  local deploy_file
  deploy_file=$(ls -t "${broadcast_dir}/Deploy"*".s.sol/${CHAIN_ID}/run-"*.json 2>/dev/null | head -1 || true)

  if [[ -z "$deploy_file" ]]; then
    err "No broadcast file found. Pass FROM_BLOCK explicitly: $0 <from_block>"
    exit 1
  fi

  log "Found broadcast: $deploy_file"

  FROM_BLOCK=$(python3 - "$deploy_file" "$HOOK" <<'PYEOF'
import json, sys
deploy_file, hook = sys.argv[1], sys.argv[2].lower()
with open(deploy_file) as f:
    d = json.load(f)
receipts = d.get('receipts', [])
for r in receipts:
    addr = (r.get('contractAddress') or '').lower()
    if addr == hook:
        print(int(r['blockNumber'], 16))
        sys.exit(0)
if receipts:
    print(int(receipts[0]['blockNumber'], 16))
else:
    print(0)
PYEOF
)

  if [[ -z "$FROM_BLOCK" || "$FROM_BLOCK" == "0" ]]; then
    err "Could not parse deploy block. Pass FROM_BLOCK explicitly."
    exit 1
  fi

  ok "Deploy block: $FROM_BLOCK"
}

# ── Fetch Etherscan logs — pure Python, no jq ────────────────────────────────
fetch_logs() {
  local topic="$1"
  local outfile="$2"
  local label="$3"

  log "Fetching $label logs (topic: ${topic:0:18}…)"

  python3 - "$ETHERSCAN_BASE" "$HOOK" "$CHAIN_ID" "$FROM_BLOCK" \
            "$TO_BLOCK" "$topic" "${ETHERSCAN_API_KEY}" "$outfile" "$label" <<'PYEOF'
import json, sys, time, urllib.request, urllib.parse

base, hook, chain, frm, to, topic, apikey, outfile, label = sys.argv[1:]
offset = 1000
all_logs = []
page = 1

while True:
    params = urllib.parse.urlencode({
        'chainid': chain, 'module': 'logs', 'action': 'getLogs',
        'address': hook, 'fromBlock': frm, 'toBlock': to,
        'topic0': topic, 'page': page, 'offset': offset, 'apikey': apikey
    })
    try:
        with urllib.request.urlopen(f'{base}?{params}', timeout=20) as r:
            data = json.load(r)
    except Exception as e:
        print(f'  [warn] Request failed: {e}', flush=True)
        break

    status = data.get('status', '0')
    msg    = data.get('message', '')
    result = data.get('result', [])

    if not isinstance(result, list):
        if msg != 'No records found':
            print(f'  [warn] Etherscan: status={status} msg={msg}', flush=True)
        break

    count = len(result)
    all_logs.extend(result)
    print(f'  page={page} → {count} records', flush=True)

    if count < offset:
        break
    page += 1
    time.sleep(0.25)

with open(outfile, 'w') as f:
    json.dump(all_logs, f)
print(f'  [ok] {len(all_logs)} {label} events saved → {outfile}', flush=True)
PYEOF
}

# ── Fetch internal txs — pure Python, no jq ─────────────────────────────────
fetch_swap_txs() {
  local outfile="$1"

  log "Fetching internal transactions to hook (swap calls)..."

  python3 - "$ETHERSCAN_BASE" "$HOOK" "$CHAIN_ID" "$FROM_BLOCK" \
            "$TO_BLOCK" "${ETHERSCAN_API_KEY}" "$outfile" <<'PYEOF'
import json, sys, time, urllib.request, urllib.parse

base, hook, chain, frm, to, apikey, outfile = sys.argv[1:]
offset = 1000
all_txs = []
page = 1

while True:
    params = urllib.parse.urlencode({
        'chainid': chain, 'module': 'account', 'action': 'txlistinternal',
        'address': hook, 'startblock': frm, 'endblock': to,
        'page': page, 'offset': offset, 'sort': 'asc', 'apikey': apikey
    })
    try:
        with urllib.request.urlopen(f'{base}?{params}', timeout=20) as r:
            data = json.load(r)
    except Exception as e:
        print(f'  [warn] Request failed: {e}', flush=True)
        break

    result = data.get('result', [])
    if not isinstance(result, list) or data.get('status') != '1':
        break

    count = len(result)
    all_txs.extend(result)
    print(f'  page={page} → {count} txs', flush=True)

    if count < offset:
        break
    page += 1
    time.sleep(0.25)

with open(outfile, 'w') as f:
    json.dump(all_txs, f)
print(f'  [ok] {len(all_txs)} swap txs saved → {outfile}', flush=True)
PYEOF
}

# ── Analytics — pure Python ──────────────────────────────────────────────────
run_analytics() {
  local panic_file="$1"
  local expired_file="$2"
  local swaps_file="$3"
  local out_dir="$4"

  python3 - "$panic_file" "$expired_file" "$swaps_file" "$out_dir" \
            "$PANIC_THRESHOLD" "$PANIC_DURATION" "$HOOK" \
            "$FROM_BLOCK" "$TO_BLOCK" "$CHAIN_ID" <<'PYEOF'
import json, sys, csv, os, math
from datetime import datetime, timezone
from collections import defaultdict

(panic_file, expired_file, swaps_file, out_dir,
 PANIC_THRESHOLD, PANIC_DURATION, HOOK,
 FROM_BLOCK, TO_BLOCK, CHAIN_ID) = sys.argv[1:]

PANIC_THRESHOLD = int(PANIC_THRESHOLD)
PANIC_DURATION  = int(PANIC_DURATION)
MIN_FEE   = 1000
PANIC_FEE = 3000

def load(path):
    try:
        with open(path) as f:
            data = json.load(f)
            return data if isinstance(data, list) else []
    except Exception as e:
        print(f'  [warn] Cannot load {path}: {e}')
        return []

def parse_int24(hex_str):
    v = int(hex_str, 16)
    if v >= 2**23:
        v -= 2**24
    return v

def to_ts(hex_or_str):
    val = int(hex_or_str, 16) if str(hex_or_str).startswith('0x') else int(hex_or_str)
    return datetime.fromtimestamp(val, tz=timezone.utc)

panics_raw  = load(panic_file)
expired_raw = load(expired_file)
swaps_raw   = load(swaps_file)

# ── Parse PanicActivated ──────────────────────────────────────────────────
panic_events = []
for e in panics_raw:
    try:
        topics = e.get('topics', [])
        raw    = e.get('data', '0x').lstrip('0x')
        ts     = to_ts(e['timeStamp'])
        block  = int(e['blockNumber'], 16)
        pool_id = topics[1] if len(topics) > 1 else '0x'
        cur_tick = parse_int24(raw[0:64][-6:])   if len(raw) >= 64  else 0
        ref_tick = parse_int24(raw[64:128][-6:]) if len(raw) >= 128 else 0
        expiry   = int(raw[128:192], 16)          if len(raw) >= 192 else 0
        panic_events.append({
            'ts': ts, 'block': block, 'pool_id': pool_id,
            'cur_tick': cur_tick, 'ref_tick': ref_tick,
            'delta': abs(cur_tick - ref_tick),
            'expiry': expiry, 'tx': e.get('transactionHash', '')
        })
    except Exception:
        pass

# ── Parse PanicExpired ────────────────────────────────────────────────────
expired_events = []
for e in expired_raw:
    try:
        topics  = e.get('topics', [])
        raw     = e.get('data', '0x').lstrip('0x')
        ts      = to_ts(e['timeStamp'])
        block   = int(e['blockNumber'], 16)
        pool_id = topics[1] if len(topics) > 1 else '0x'
        new_ref = parse_int24(raw[0:64][-6:]) if len(raw) >= 64 else 0
        expired_events.append({
            'ts': ts, 'block': block, 'pool_id': pool_id,
            'new_ref_tick': new_ref, 'tx': e.get('transactionHash', '')
        })
    except Exception:
        pass

# ── Fee attribution ───────────────────────────────────────────────────────
def get_fee(ts_unix):
    for p in panic_events:
        if p['ts'].timestamp() <= ts_unix <= p['expiry']:
            return PANIC_FEE, True
    return MIN_FEE, False

swap_fees = []
for tx in swaps_raw:
    try:
        ts_unix = int(tx['timeStamp'])
        fee, is_panic = get_fee(ts_unix)
        swap_fees.append({
            'ts': datetime.fromtimestamp(ts_unix, tz=timezone.utc),
            'block': int(tx.get('blockNumber', '0')),
            'fee': fee, 'is_panic': is_panic,
            'tx': tx.get('hash', '')
        })
    except Exception:
        pass

# ── Aggregate stats ───────────────────────────────────────────────────────
total_panics  = len(panic_events)
total_expired = len(expired_events)
total_swaps   = len(swap_fees)
panic_swaps   = sum(1 for s in swap_fees if s['is_panic'])
calm_swaps    = total_swaps - panic_swaps
panic_pct     = panic_swaps / total_swaps * 100 if total_swaps else 0.0
avg_fee       = (panic_swaps * PANIC_FEE + calm_swaps * MIN_FEE) / total_swaps if total_swaps else MIN_FEE

deltas    = [p['delta'] for p in panic_events]
max_delta = max(deltas) if deltas else 0
avg_delta = sum(deltas) / len(deltas) if deltas else 0.0

durations = [p['expiry'] - p['ts'].timestamp()
             for p in panic_events
             if 0 < p['expiry'] - p['ts'].timestamp() <= PANIC_DURATION * 2]
avg_dur   = sum(durations) / len(durations) if durations else 0.0

pools = list(set(p['pool_id'] for p in panic_events))

hourly_panics = defaultdict(int)
hourly_swaps  = defaultdict(int)
for p in panic_events:
    hourly_panics[p['ts'].hour] += 1
for s in swap_fees:
    hourly_swaps[s['ts'].hour] += 1

busiest_panic_hour = max(hourly_panics, key=hourly_panics.get) if hourly_panics else None
busiest_swap_hour  = max(hourly_swaps,  key=hourly_swaps.get)  if hourly_swaps  else None

daily = defaultdict(lambda: {'panic': 0, 'calm': 0, 'panics_triggered': 0})
for s in swap_fees:
    day = s['ts'].strftime('%Y-%m-%d')
    if s['is_panic']:
        daily[day]['panic'] += 1
    else:
        daily[day]['calm'] += 1
for p in panic_events:
    daily[p['ts'].strftime('%Y-%m-%d')]['panics_triggered'] += 1

# ── Print report ──────────────────────────────────────────────────────────
SEP = '─' * 60
print()
print(SEP)
print('  VolatilityGuardHookV5 — Analytics Report')
print(f'  Hook:  {HOOK}')
print(f'  Range: block {FROM_BLOCK} → {TO_BLOCK}')
print(f'  Generated: {datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")}')
print(SEP)

print()
print('  ┌─ PANIC EVENTS ──────────────────────────────────┐')
print(f'  │  Total PanicActivated  : {total_panics:>8}              │')
print(f'  │  Total PanicExpired    : {total_expired:>8}              │')
print(f'  │  Pools affected        : {len(pools):>8}              │')
print(f'  │  Avg tick delta        : {avg_delta:>8.1f}              │')
print(f'  │  Max tick delta        : {max_delta:>8}              │')
print(f'  │  Avg panic duration    : {avg_dur:>7.0f}s              │')
bph = f'{busiest_panic_hour}h' if busiest_panic_hour is not None else 'n/a'
print(f'  │  Busiest hour (UTC)    : {bph:>8}              │')
print(f'  └─────────────────────────────────────────────────┘')

print()
print('  ┌─ SWAP FEES ─────────────────────────────────────┐')
print(f'  │  Total swaps tracked   : {total_swaps:>8}              │')
print(f'  │  MIN_FEE  (0.10%) swaps: {calm_swaps:>8} ({100-panic_pct:5.1f}%)   │')
print(f'  │  PANIC_FEE(0.30%) swaps: {panic_swaps:>8} ({panic_pct:5.1f}%)   │')
print(f'  │  Weighted avg fee      : {avg_fee/100000:>8.4f}%            │')
bsh = f'{busiest_swap_hour}h' if busiest_swap_hour is not None else 'n/a'
print(f'  │  Busiest swap hour UTC : {bsh:>8}              │')
print(f'  └─────────────────────────────────────────────────┘')

print()
print('  Tick delta distribution (PanicActivated events):')
for (lo, hi), lbl in [
    ((0,   30),  '  0– 30'),
    ((30,  60),  '30– 60'),
    ((60,  90),  '60– 90'),
    ((90,  120), '90–120'),
    ((120, 200), '120–200'),
    ((200, 99999),'200+  '),
]:
    cnt = sum(1 for d in deltas if lo <= d < hi)
    bar = '█' * min(cnt, 40)
    print(f'  [{lbl}]  {bar} {cnt}')

print()
print('  Hourly panic heatmap (UTC):')
row = '  '
for h in range(24):
    cnt = hourly_panics.get(h, 0)
    row += ('·' if cnt == 0 else '░' if cnt <= 2 else '▒' if cnt <= 5 else '▓' if cnt <= 9 else '█')
print(row + '  0h→23h')

print()
print('  Daily breakdown (last 14 days):')
print(f'  {"Date":<12} {"Panics":>7} {"MIN swaps":>10} {"PANIC swaps":>12} {"PANIC%":>8}')
print('  ' + '─' * 52)
for day in sorted(daily.keys())[-14:]:
    v   = daily[day]
    tot = v['panic'] + v['calm']
    pct = v['panic'] / tot * 100 if tot else 0
    print(f'  {day:<12} {v["panics_triggered"]:>7} {v["calm"]:>10} {v["panic"]:>12} {pct:>7.1f}%')

print()
print('  Recent PanicActivated events (last 10):')
print(f'  {"Timestamp (UTC)":<22} {"Pool":<12} {"CurTick":>9} {"RefTick":>9} {"Δ":>5}  Tx')
print('  ' + '─' * 80)
for p in sorted(panic_events, key=lambda x: x['ts'])[-10:]:
    pid = (p['pool_id'][:10] + '…') if len(p['pool_id']) > 12 else p['pool_id']
    txs = (p['tx'][:14] + '…') if p['tx'] else 'n/a'
    print(f'  {p["ts"].strftime("%Y-%m-%d %H:%M:%S"):<22} {pid:<12} '
          f'{p["cur_tick"]:>9} {p["ref_tick"]:>9} {p["delta"]:>5}  {txs}')

print()
print(SEP)

# ── Write CSVs ────────────────────────────────────────────────────────────
os.makedirs(out_dir, exist_ok=True)

with open(f'{out_dir}/panic_events.csv', 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=['timestamp','block','pool_id','cur_tick','ref_tick','delta','expiry','tx'])
    w.writeheader()
    for p in sorted(panic_events, key=lambda x: x['ts']):
        w.writerow({'timestamp': p['ts'].isoformat(), 'block': p['block'],
                    'pool_id': p['pool_id'], 'cur_tick': p['cur_tick'],
                    'ref_tick': p['ref_tick'], 'delta': p['delta'],
                    'expiry': p['expiry'], 'tx': p['tx']})
print(f'  CSV → {out_dir}/panic_events.csv')

with open(f'{out_dir}/expired_events.csv', 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=['timestamp','block','pool_id','new_ref_tick','tx'])
    w.writeheader()
    for e in sorted(expired_events, key=lambda x: x['ts']):
        w.writerow({'timestamp': e['ts'].isoformat(), 'block': e['block'],
                    'pool_id': e['pool_id'], 'new_ref_tick': e['new_ref_tick'], 'tx': e['tx']})
print(f'  CSV → {out_dir}/expired_events.csv')

with open(f'{out_dir}/swap_fees.csv', 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=['timestamp','block','fee_bps_x10','is_panic','tx'])
    w.writeheader()
    for s in sorted(swap_fees, key=lambda x: x['ts']):
        w.writerow({'timestamp': s['ts'].isoformat(), 'block': s['block'],
                    'fee_bps_x10': s['fee'], 'is_panic': s['is_panic'], 'tx': s['tx']})
print(f'  CSV → {out_dir}/swap_fees.csv')

with open(f'{out_dir}/daily_summary.csv', 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=['date','panics_triggered','calm_swaps','panic_swaps','panic_pct'])
    w.writeheader()
    for day in sorted(daily.keys()):
        v   = daily[day]
        tot = v['panic'] + v['calm']
        pct = round(v['panic'] / tot * 100, 2) if tot else 0.0
        w.writerow({'date': day, 'panics_triggered': v['panics_triggered'],
                    'calm_swaps': v['calm'], 'panic_swaps': v['panic'], 'panic_pct': pct})
print(f'  CSV → {out_dir}/daily_summary.csv')

summary = {
    'hook': HOOK, 'from_block': FROM_BLOCK, 'to_block': TO_BLOCK,
    'chain_id': int(CHAIN_ID),
    'generated_at': datetime.now(timezone.utc).isoformat(),
    'panic_events': total_panics, 'expired_events': total_expired,
    'pools_affected': len(pools),
    'avg_tick_delta': round(avg_delta, 2), 'max_tick_delta': max_delta,
    'avg_panic_duration_sec': round(avg_dur, 1),
    'total_swaps': total_swaps, 'calm_swaps': calm_swaps,
    'panic_swaps': panic_swaps, 'panic_pct': round(panic_pct, 2),
    'weighted_avg_fee_pct': round(avg_fee / 100000, 6),
}
with open(f'{out_dir}/summary.json', 'w') as f:
    json.dump(summary, f, indent=2)
print(f'  JSON → {out_dir}/summary.json')
print()
PYEOF
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo -e "\n${BLD}VolatilityGuardHookV5 — Stats${RST}"
  echo    "Hook     : $HOOK"
  echo    "Chain    : $CHAIN_ID"
  echo    "Blocks   : $FROM_BLOCK → $TO_BLOCK"
  echo    "Output   : $OUTPUT_DIR"
  echo

  check_deps
  resolve_from_block
  mkdir -p "$OUTPUT_DIR"

  # Compute topic0 via Python (keccak256)
  TOPIC_PANIC=$(python3 -c "
import hashlib
print('0x' + hashlib.sha3_256(b'PanicActivated(bytes32,int24,int24,uint256)').hexdigest())
")
  TOPIC_EXPIRED=$(python3 -c "
import hashlib
print('0x' + hashlib.sha3_256(b'PanicExpired(bytes32,int24)').hexdigest())
")

  log "topic0 PanicActivated : $TOPIC_PANIC"
  log "topic0 PanicExpired   : $TOPIC_EXPIRED"
  echo

  PANIC_FILE="${OUTPUT_DIR}/raw_panic.json"
  EXPIRED_FILE="${OUTPUT_DIR}/raw_expired.json"
  SWAPS_FILE="${OUTPUT_DIR}/raw_swaps.json"

  fetch_logs "$TOPIC_PANIC"   "$PANIC_FILE"   "PanicActivated"
  fetch_logs "$TOPIC_EXPIRED" "$EXPIRED_FILE" "PanicExpired"
  fetch_swap_txs "$SWAPS_FILE"

  echo
  log "Running analytics..."
  run_analytics "$PANIC_FILE" "$EXPIRED_FILE" "$SWAPS_FILE" "$OUTPUT_DIR"

  ok "Done. Output files:"
  ls -lh "${OUTPUT_DIR}/"*.{csv,json} 2>/dev/null | awk '{print "  " $5 "  " $9}'
  echo
}

main "$@"