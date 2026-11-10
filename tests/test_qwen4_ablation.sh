#!/usr/bin/env bash
# test_qwen4_ablation.sh — directional ablation on a Flash Next (qwen4_exp) pack, end to end: a random
# direction as the only profile under --ablation-profiles, then strength 0 answers with the stock bytes, strength 1
# changes the answer, both carry X-Ablation, a request without the key is a 401, the profile loaded, and the projection
# rode the two-launch hyper-connection read. The pack's memory must be free (unload it from any other server first).
#
#   QWEN4_MODEL=<pack dir> ./tests/test_qwen4_ablation.sh [port]   # SKIPs without the pack
#
# Hermetic twins: `qwen4_exp served: an ablated slot's streams keep no component along its direction` and the
# `hc decode2: an ablated pending write` tests.
source "$(dirname "$0")/_lib_models.sh"
source "$(dirname "$0")/lib/server.sh"

set -u
MODEL="${QWEN4_MODEL:-$(find_model ddalcu/Qwen3.8-Flash-Next-MLX-Serve-iQ-MLX-4.7bpw ddalcu/Qwen3.8-Flash-Next-MLX-Serve-4bit || echo "")}"
PORT="${1:-11412}"
BIN="${MLX_SERVE_BIN:-./zig-out/bin/mlx-serve}"
WORK="$HOME/claude-tmp/qwen4-ablation/$PORT"
LOG="$WORK/server.log"
URL="http://127.0.0.1:$PORT"
[ -n "$MODEL" ] && [ -f "$MODEL/config.json" ] || { echo "SKIP: no Flash Next pack (QWEN4_MODEL)"; exit 0; }
rm -rf "$WORK" && mkdir -p "$WORK"
pass=0; fail=0

python3 -I - "$MODEL" "$WORK" <<'EOF'
import hashlib, json, os, random, struct, sys
model, work = sys.argv[1], sys.argv[2]
cfg_bytes = open(os.path.join(model, "config.json"), "rb").read()
cfg = json.loads(cfg_bytes)
hidden = cfg.get("text_config", cfg)["hidden_size"]
rng = random.Random(7)
v = [rng.gauss(0, 1) for _ in range(hidden)]
n = sum(x * x for x in v) ** 0.5
data = struct.pack(f"<{hidden}f", *[x / n for x in v])
header = json.dumps({"direction": {"dtype": "F32", "shape": [hidden], "data_offsets": [0, len(data)]}}).encode()
header += b" " * (-len(header) % 8)
prof = os.path.join(work, "profiles", "rand")
os.makedirs(prof)
open(os.path.join(prof, "direction.safetensors"), "wb").write(struct.pack("<Q", len(header)) + header + data)
json.dump({"format": "mlx-serve-ablation", "version": 1, "hidden_size": hidden,
           "base_config_sha256": hashlib.sha256(cfg_bytes).hexdigest()}, open(os.path.join(prof, "manifest.json"), "w"))
fd = os.open(os.path.join(work, "key"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
os.write(fd, os.urandom(32).hex().encode())
os.close(fd)
EOF
KEY="$(cat "$WORK/key")"

"$BIN" --model "$MODEL" --serve --port "$PORT" --log-level info \
  --ablation-profiles "$WORK/profiles" --ablation-key-file "$WORK/key" >"$LOG" 2>&1 &
SRV=$!
trap 'srv_stop "$SRV"' EXIT
srv_wait_health "$URL" 900 1 "$SRV" || { echo "FAIL: server did not come up; see $LOG"; exit 1; }

# chat <strength|-> <key|-> <name>: the body to <name>.json, the headers to <name>.h; prints the status.
chat() {
  local hdr=(-H 'content-type: application/json')
  [ "$2" != - ] && hdr+=(-H "X-Ablation-Key: $2")
  python3 -I -c 'import json,sys
d={"model":"x","max_tokens":48,"temperature":0,"enable_thinking":False,"messages":[{"role":"user","content":"Name three uses of a paperclip, one line each."}]}
if sys.argv[1] != "-": d["ablation"]={"profile":"rand","strength":float(sys.argv[1])}
print(json.dumps(d))' "$1" |
    curl -s -m 600 -o "$WORK/$3.json" -D "$WORK/$3.h" -w '%{http_code}' "$URL/v1/chat/completions" "${hdr[@]}" -d @-
}
text() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["choices"][0]["message"]["content"])' "$WORK/$1.json"; }
check() { if eval "$2"; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }

check "stock request answers 200" '[ "$(chat - - stock)" = 200 ]'
check "strength 0 answers 200" '[ "$(chat 0 "$KEY" zero)" = 200 ]'
check "strength 1 answers 200" '[ "$(chat 1 "$KEY" one)" = 200 ]'
check "no key is a 401" '[ "$(chat 1 - nokey)" = 401 ]'
check "strength 0 carries X-Ablation at 0" 'grep -qi "^x-ablation: profile=rand; strength=0.000" "$WORK/zero.h"'
check "strength 1 carries X-Ablation at 1" 'grep -qi "^x-ablation: profile=rand; strength=1.000" "$WORK/one.h"'
check "strength 0 is the stock answer" '[ "$(text zero)" = "$(text stock)" ]'
check "strength 1 changes the answer" '[ "$(text one)" != "$(text stock)" ]'
check "the profile loaded" 'grep -q "\[ablation\] enabled: 1 profile(s)" "$LOG"'
check "the projection rode the hyper-connection read" 'grep -q "directional ablation folded into the hyper-connection read" "$LOG"'
echo "test_qwen4_ablation: $pass passed, $fail failed"
[ "$fail" = 0 ]
