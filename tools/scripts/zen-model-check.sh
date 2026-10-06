#!/usr/bin/env bash
# Which OpenCode Zen Go models actually answer with your key?
#   OPENCODE_API_KEY=... ./zen-model-check.sh            # test every model
#   OPENCODE_API_KEY=... ./zen-model-check.sh muse-spark-1.3-contributor gpt-5.6-luna
set -uo pipefail
BASE="https://opencode.ai/zen/go/v1"
: "${OPENCODE_API_KEY:?set OPENCODE_API_KEY}"

models=("$@")
if [ ${#models[@]} -eq 0 ]; then
  mapfile -t models < <(curl -sS "$BASE/models" | python3 -c \
    'import json,sys; [print(m["id"]) for m in json.load(sys.stdin)["data"]]')
fi

printf '%-34s %-6s %s\n' MODEL HTTP RESULT
for m in "${models[@]}"; do
  body=$(curl -sS -m 60 -w '\n%{http_code}' "$BASE/responses" \
    -H "authorization: Bearer $OPENCODE_API_KEY" \
    -H 'content-type: application/json' \
    -d "{\"model\":\"$m\",\"input\":\"Reply with exactly: OK\",\"max_output_tokens\":16}")
  code=$(tail -n1 <<<"$body")
  detail=$(sed '$d' <<<"$body" | python3 -c '
import json,sys
raw=sys.stdin.read()
try:
    d=json.loads(raw)
except Exception:
    print(raw[:90].replace("\n"," ")); raise SystemExit
err=d.get("error")
if err:
    print((err.get("message") if isinstance(err,dict) else str(err))[:90]); raise SystemExit
out=[c.get("text","") for item in d.get("output",[]) for c in item.get("content",[])]
print(("answered: "+" ".join(out).strip()[:60]) if out else "answered (no text)")
')
  printf '%-34s %-6s %s\n' "$m" "$code" "$detail"
done
