#!/usr/bin/env bash
# Tests the domain-filtering egress proxy on loopback: allowlist matching
# (including the suffix-confusion cases that make naive matching unsafe),
# real tunnelling, port restriction, hot reload, and the audit log.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
PORT=$(( 18000 + RANDOM % 2000 ))
trap 'kill $(cat "$WORK/pid" 2>/dev/null) 2>/dev/null || true; rm -rf "$WORK"' EXIT

cat > "$WORK/allow.txt" <<'EOF'
# test allowlist
example.com
.githubusercontent.com
*.pypi.org
EOF

python3 "$ROOT/bin/agentbox-egress-proxy" --allow-file "$WORK/allow.txt" \
  --listen 127.0.0.1 --port "$PORT" --log "$WORK/egress.jsonl" \
  >"$WORK/err" 2>&1 &
echo $! > "$WORK/pid"
for _ in $(seq 1 50); do
  (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && { exec 3>&-; break; }
  sleep 0.1
done

# The proxy's own audit log is the oracle. curl's exit status cannot be used:
# a 403 answer to a CONNECT surfaces as http_code 000, which is indistinguishable
# from a host that was permitted but simply failed to resolve.
verdict_for() {
  python3 -c '
import json, sys
host = sys.argv[2].lower()
verdict = "none"
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        r = json.loads(line)
    except json.JSONDecodeError:
        continue
    if r.get("host", "").lower() == host and r.get("event") in ("allow", "deny", "error"):
        # "error" means policy permitted it and the upstream connect failed --
        # still an allow decision as far as the filter is concerned.
        verdict = "allow" if r["event"] in ("allow", "error") else "deny"
print(verdict)' "$WORK/egress.jsonl" "$1"
}

pass=0; fail=0
check() { # check <desc> <expected: allow|deny> <host> [scheme]
  local desc=$1 want=$2 host=$3 scheme=${4:-https}
  curl -s -o /dev/null --max-time 10 --proxy "http://127.0.0.1:$PORT" \
       "$scheme://$host" >/dev/null 2>&1 || true
  local got; got=$(verdict_for "$host")
  if [[ $got == "$want" ]]; then
    printf '  \033[32mok\033[0m   %-46s (%s)\n' "$desc" "$got"; pass=$((pass+1))
  else
    printf '  \033[31mFAIL\033[0m %-46s wanted %s, got %s\n' "$desc" "$want" "$got"; fail=$((fail+1))
  fi
}

echo "# allowlist matching"
check "exact host allowed"                 allow example.com
check "subdomain of allowed host"          allow www.example.com
check "leading-dot rule matches subdomain" allow raw.githubusercontent.com
check "glob rule matches subdomain"        allow files.pypi.org

echo "# the cases naive matching gets wrong"
check "suffix confusion rejected"          deny  example.com.evil.test
check "prefix confusion rejected"          deny  notexample.com
check "unrelated host rejected"            deny  malicious.test
check "dot-rule not widened to parent"     deny  githubusercontent.com.evil.test

echo "# protocol and port handling"
check "plain http also filtered"           deny  malicious.test http
check "plain http allowed host tunnels"    allow example.com http
curl -s -o /dev/null --max-time 8 --proxy "http://127.0.0.1:$PORT" \
     "https://example.com:2222" >/dev/null 2>&1 || true
if grep -q '"reason":"port 2222 not permitted"' "$WORK/egress.jsonl"; then
  printf '  \033[32mok\033[0m   %-46s (deny)\n' "non-web port rejected on allowed host"; pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m %-46s\n' "non-web port rejected on allowed host"; fail=$((fail+1))
fi

echo "# hot reload"
printf 'httpbin.org\n' >> "$WORK/allow.txt"
sleep 0.4
check "host added without restart"         allow httpbin.org

echo "# audit log"
n_deny=$(grep -c '"event":"deny"' "$WORK/egress.jsonl" 2>/dev/null || true)
if [[ ${n_deny:-0} -ge 5 ]]; then
  printf '  \033[32mok\033[0m   %-46s (%s denials)\n' "denials recorded" "$n_deny"; pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m %-46s (only %s)\n' "denials recorded" "${n_deny:-0}"; fail=$((fail+1))
fi
if python3 -c "
import json,sys
rows=[json.loads(l) for l in open('$WORK/egress.jsonl')]
d=[r for r in rows if r.get('event')=='deny']
assert d and all({'host','reason','ts'} <= set(r) for r in d)
" 2>/dev/null; then
  printf '  \033[32mok\033[0m   %-46s\n' "log lines well-formed JSON with reasons"; pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m %-46s\n' "log lines well-formed JSON with reasons"; fail=$((fail+1))
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
exit $(( fail > 0 ))
