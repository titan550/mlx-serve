#!/usr/bin/env bash
# test_ablation_model_setting.sh — the model setting `"ablation"` in model-settings.json, end to end on a pack whose
# plugin serves ablation (Flash Next): a random profile loaded at launch, then with the setting written the row lists
# the profile, a chat and a /v1/messages request that name no ablation carry X-Ablation with no key and the chat's
# answer moves off the stock one, strength 0 answers the stock bytes, /props reports the setting, and a setting naming
# a profile the server does not have fails the request with a 503 that /props explains. Scratch HOME; the pack's
# memory must be free (unload it from any other server first).
#
#   QWEN4_MODEL=<pack dir> ./tests/test_ablation_model_setting.sh [port]   # SKIPs without the pack
source "$(dirname "$0")/_lib_models.sh"
source "$(dirname "$0")/lib/server.sh"

set -u
MODEL="${QWEN4_MODEL:-$(find_model ddalcu/Qwen3.8-Flash-Next-MLX-Serve-iQ-MLX-4.7bpw ddalcu/Qwen3.8-Flash-Next-MLX-Serve-4bit || echo "")}"
PORT="${1:-11413}"
BIN="${MLX_SERVE_BIN:-./zig-out/bin/mlx-serve}"
WORK="$HOME/claude-tmp/ablation-setting/$PORT"
LOG="$WORK/server.log"
URL="http://127.0.0.1:$PORT"
[ -n "$MODEL" ] && [ -f "$MODEL/config.json" ] || { echo "SKIP: no Flash Next pack (QWEN4_MODEL)"; exit 0; }
rm -rf "$WORK" && mkdir -p "$WORK/home/.mlx-serve"
SETTINGS="$WORK/home/.mlx-serve/model-settings.json"
pass=0; fail=0

python3 -I - "$MODEL" "$WORK" <<'EOF'
import hashlib, json, os, random, struct, sys
model, work = sys.argv[1], sys.argv[2]
cfg_bytes = open(os.path.join(model, "config.json"), "rb").read()
hidden = json.loads(cfg_bytes).get("text_config", json.loads(cfg_bytes))["hidden_size"]
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

# setting <json|-> writes this pack's entry (atomically, as the app does) and waits out the server's 1 s recheck.
setting() {
  python3 -I -c 'import json,os,sys
path, model, value = sys.argv[1], sys.argv[2], sys.argv[3]
doc = {} if value == "-" else {model: {"ablation": json.loads(value)}}
json.dump(doc, open(path + ".tmp", "w")); os.replace(path + ".tmp", path)' "$SETTINGS" "$MODEL" "$1"
  sleep 1.2
}
setting -
HOME="$WORK/home" "$BIN" --model "$MODEL" --serve --port "$PORT" --log-level info \
  --ablation-profiles "$WORK/profiles" --ablation-key-file "$WORK/key" >"$LOG" 2>&1 &
SRV=$!
trap 'srv_stop "$SRV"' EXIT
srv_wait_health "$URL" 900 1 "$SRV" || { echo "FAIL: server did not come up; see $LOG"; exit 1; }

# post <route> <name>: a fixed prompt to /v1/chat/completions or /v1/messages; body and headers saved, status printed.
post() {
  python3 -I -c 'import json,sys
m=[{"role":"user","content":"Name three uses of a paperclip, one line each."}]
d={"model":"x","max_tokens":48,"temperature":0,"messages":m}
if sys.argv[1] == "chat": d["enable_thinking"] = False
print(json.dumps(d))' "$1" |
    curl -s -m 600 -o "$WORK/$2.json" -D "$WORK/$2.h" -w '%{http_code}' "$URL/v1/$([ "$1" = chat ] && echo chat/completions || echo messages)" \
      -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' -d @-
}
text() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["choices"][0]["message"]["content"])' "$WORK/$1.json"; }
# props_ablation <python expr over a (the /props "ablation" object)>: true when it holds.
props_ablation() {
  python3 -I -c 'import json,sys,urllib.request,urllib.parse
u=sys.argv[1]; mid=json.load(urllib.request.urlopen(u+"/v1/models"))["data"][0]["id"]
a=json.load(urllib.request.urlopen(u+"/props?model="+urllib.parse.quote(mid)))["ablation"]
sys.exit(0 if eval(sys.argv[2]) else 1)' "$URL" "$1"
}
check() { if eval "$2"; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }

check "stock chat answers 200" '[ "$(post chat stock)" = 200 ]'
check "the row lists the profile made from this pack, with its strength" 'curl -s "$URL/v1/models" | grep -q "\"ablation_profiles\":\[{\"name\":\"rand\",\"strength\":1,\"max_strength\":30}]"' 
setting '{"profile":"rand","strength":1,"prefix_cache":"shared"}'
check "chat under the setting answers 200" '[ "$(post chat on)" = 200 ]'
check "it carries X-Ablation with no key" 'grep -qi "^x-ablation: profile=rand; strength=1.000" "$WORK/on.h"'
check "the setting moves the answer" '[ "$(text on)" != "$(text stock)" ]'
check "/v1/messages runs under it too" '[ "$(post messages msg)" = 200 ] && grep -qi "^x-ablation: profile=rand" "$WORK/msg.h"'
check "/props reports the setting" 'props_ablation "a[\"setting\"]==dict(profile=\"rand\",strength=1,prefix_cache=\"shared\") and a[\"error\"] is None"'
setting '{"profile":"rand","strength":0}'
check "strength 0 answers the stock bytes" '[ "$(post chat zero)" = 200 ] && [ "$(text zero)" = "$(text stock)" ]'
setting '{"profile":"missing"}'
check "a profile the server lacks is a 503" '[ "$(post chat bad)" = 503 ]'
check "/props names why" 'props_ablation "\"unknown ablation profile\" in (a[\"error\"] or \"\")"'
setting -
check "with the setting gone the stock answer is back" '[ "$(post chat off)" = 200 ] && [ "$(text off)" = "$(text stock)" ]'
echo "test_ablation_model_setting: $pass passed, $fail failed"
[ "$fail" = 0 ]
