#!/usr/bin/env bash
# Live bridge-mode test. Unlike test/net-rules.sh, which renders the nftables
# ruleset offline, this one loads it into the kernel and puts real packets
# through it -- the only way to know the policy actually holds.
#
# Needs sudo (tap devices) and `agentbox net up` beforehand:
#
#     sudo -v && ./test/bridge-live.sh
#
# Creates two throwaway boxes and removes them on exit.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
AB="$ROOT/bin/agentbox"
A=brlive-a-$$
B=brlive-b-$$
KEEP=${KEEP:-0}

cleanup() {
  if [[ $KEEP == 1 ]]; then
    echo "keeping $A and $B" >&2; return
  fi
  "$AB" down "$A" >/dev/null 2>&1 || true
  "$AB" down "$B" >/dev/null 2>&1 || true
  rm -rf "$HOME/.agentbox/boxes/$A" "$HOME/.agentbox/boxes/$B"
  "$AB" ssh-config >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass=0; fail=0; skip=0
ok_()   { printf '  \033[32mok\033[0m   %-52s %s\n' "$1" "${2-}"; pass=$((pass+1)); }
bad_()  { printf '  \033[31mFAIL\033[0m %-52s %s\n' "$1" "${2-}"; fail=$((fail+1)); }
skip_() { printf '  \033[33mskip\033[0m %-52s %s\n' "$1" "${2-}"; skip=$((skip+1)); }

# Runs a command in a box and reports only whether it succeeded.
inbox() { "$AB" ssh "$1" -- "${@:2}" >/dev/null 2>&1; }

sudo -n true 2>/dev/null || { echo "run 'sudo -v' first (tap devices need root)" >&2; exit 2; }
ip link show agbr0 >/dev/null 2>&1 || { echo "run 'agentbox net up' first" >&2; exit 2; }

echo "# creating two bridge boxes (proxy egress on A, open on B)"
"$AB" create "$A" --net bridge --egress proxy --cpus 2 --mem 2048 >/dev/null
"$AB" create "$B" --net bridge --egress open  --cpus 2 --mem 2048 >/dev/null
"$AB" up "$A" >/dev/null
"$AB" up "$B" >/dev/null

IP_A=$(sed -n 's/^BOX_IP=//p' "$HOME/.agentbox/boxes/$A/box.conf")
IP_B=$(sed -n 's/^BOX_IP=//p' "$HOME/.agentbox/boxes/$B/box.conf")
HOST_LAN=$(ip -j route show default | jq -r '.[0].prefsrc // empty')

echo "# egress policy: box A is proxy-filtered"
# Verify the host can reach the target first. A slow or blocked upstream is an
# environment condition, not a policy failure, and conflating the two makes the
# suite report a broken proxy whenever the network is having a bad day.
TARGET=api.anthropic.com
if ! curl -sS --max-time 25 -o /dev/null "https://$TARGET" 2>/dev/null; then
  skip_ "allowlisted host reachable through the proxy" \
        "(the host itself cannot reach $TARGET)"
else
  # Generous timeout: this traverses the proxy on top of whatever the upstream
  # already costs, and the host measurement above is the floor, not the budget.
  if inbox "$A" "curl -sS --max-time 45 -o /dev/null https://$TARGET"; then
    ok_ "allowlisted host reachable through the proxy"
  else
    # The audit log says which half failed: a `deny` is the policy refusing,
    # anything else is the upstream.
    verdict=$(python3 - "$HOME/.agentbox/boxes/$A/run/egress.jsonl" "$TARGET" <<'PYV'
import json, sys
host, out = sys.argv[2].lower(), "none"
try:
    for line in open(sys.argv[1], encoding="utf-8"):
        try: r = json.loads(line)
        except json.JSONDecodeError: continue
        if r.get("host", "").lower() == host:
            out = r.get("event", "none")
except OSError:
    pass
print(out)
PYV
)
    case $verdict in
      deny) bad_ "allowlisted host was DENIED by the proxy" "policy is wrong" ;;
      error) skip_ "allowlisted host reachable through the proxy" \
                   "(proxy allowed it; upstream connect failed)" ;;
      *)    bad_ "allowlisted host unreachable" "(verdict=$verdict; agentbox egress-log $A)" ;;
    esac
  fi
fi
if inbox "$A" 'curl -sS --max-time 12 -o /dev/null https://example.com'; then
  bad_ "NON-allowlisted host was reachable" "policy is not holding"
else
  ok_ "non-allowlisted host refused"
fi
if inbox "$A" 'curl -sS --max-time 10 --noproxy "*" -o /dev/null https://1.1.1.1'; then
  bad_ "direct egress bypassing the proxy succeeded"
else
  ok_ "direct egress (proxy bypassed) blocked by nftables"
fi
if inbox "$A" 'getent hosts example.com'; then
  bad_ "DNS resolution worked in proxy mode" "DNS tunnelling channel is open"
else
  ok_ "no DNS in proxy mode" "(exfil channel closed)"
fi

echo "# egress policy: box B is open"
if inbox "$B" 'curl -sS --max-time 15 -o /dev/null https://example.com'; then
  ok_ "open box reaches the internet"
else
  bad_ "open box has no internet"
fi

echo "# isolation invariants"
for n in "$A" "$B"; do
  idx=$(sed -n 's/^BOX_INDEX=//p' "$HOME/.agentbox/boxes/$n/box.conf")
  if bridge -d link show dev "ag$idx" 2>/dev/null | grep -q 'isolated on'; then
    ok_ "bridge port ag$idx is isolated"
  else
    bad_ "bridge port ag$idx is NOT isolated" "box-to-box relies on this"
  fi
done
if inbox "$B" "timeout 5 bash -c '</dev/tcp/$IP_A/22'"; then
  bad_ "box B reached box A's ssh" "box-to-box traffic is not blocked"
else
  ok_ "box-to-box traffic blocked"
fi
if inbox "$B" "timeout 5 bash -c '</dev/tcp/10.77.0.1/22'"; then
  bad_ "box reached the host's ssh on the bridge"
else
  ok_ "host ssh unreachable from a box"
fi
if [[ -n $HOST_LAN ]]; then
  if inbox "$B" "timeout 5 bash -c '</dev/tcp/$HOST_LAN/22'"; then
    bad_ "box reached the host over the LAN address"
  else
    ok_ "host LAN address unreachable from a box"
  fi
else
  skip_ "LAN reachability" "(no default-route source address found)"
fi
if inbox "$B" 'timeout 5 getent hosts example.com'; then
  ok_ "open box can use the bridge resolver"
else
  bad_ "open box cannot resolve DNS"
fi

echo "# audit log"
LOG="$HOME/.agentbox/boxes/$A/run/egress.jsonl"
if [[ -s $LOG ]] && grep -q '"event":"deny"' "$LOG"; then
  n_d=$(grep -c '"event":"deny"' "$LOG"); n_a=$(grep -c '"event":"allow"' "$LOG" || true)
  ok_ "egress log recorded decisions" "($n_a allow, $n_d deny)"
else
  bad_ "egress log missing or empty" "$LOG"
fi

echo "# allowlist is live-editable"
"$AB" allow "$A" example.com >/dev/null 2>&1
sleep 1
if inbox "$A" 'curl -sS --max-time 15 -o /dev/null https://example.com'; then
  ok_ "newly allowed host reachable without restart"
else
  bad_ "allowlist change did not take effect"
fi

echo
printf '%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
exit $(( fail > 0 ))
