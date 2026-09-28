#!/usr/bin/env bash
# A/B test: does `meta l4proto { tcp, udp } th dport 53` actually fail to match
# on this kernel, or was the DNS outage entirely the VPN blocking the subnet?
#
# Commit 'net: fix DNS never working for any bridge box' asserts the former and
# a test now forbids that form permanently. If it turns out to work, that commit
# is wrong and the assertion should go.
#
# Needs a working bridge box and sudo. Reverts itself.
#
#   sudo -v && ./test/ab-dns-rule.sh <box>
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BOX=${1:?usage: ab-dns-rule.sh <running bridge box>}
NET="$ROOT/lib/net.sh"
BACKUP=$(mktemp)
cp "$NET" "$BACKUP"
restore() { cp "$BACKUP" "$NET"; rm -f "$BACKUP"; "$ROOT/bin/agentbox" net refresh >/dev/null 2>&1 || true; }
trap restore EXIT

probe() {  # returns 0 if the guest can resolve
  "$ROOT/bin/agentbox" ssh "$BOX" -- \
    'timeout 6 getent ahostsv4 example.com >/dev/null 2>&1' >/dev/null 2>&1
}

echo "# A: current rules (udp dport 53 / tcp dport 53, protocol-qualified)"
"$ROOT/bin/agentbox" net refresh >/dev/null
sleep 1
if probe; then echo "  resolves: YES"; A=yes; else echo "  resolves: NO"; A=no; fi

echo "# B: the combined form that was replaced"
python3 - "$NET" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = '''    echo "    iifname \\"$AGENTBOX_BRIDGE\\" udp dport 53 accept"
    echo "    iifname \\"$AGENTBOX_BRIDGE\\" tcp dport 53 accept"'''
new = '''    echo "    iifname \\"$AGENTBOX_BRIDGE\\" meta l4proto { tcp, udp } th dport 53 accept"'''
assert old in s, "current DNS rules not found -- has lib/net.sh changed?"
p.write_text(s.replace(old, new))
PY
"$ROOT/bin/agentbox" net refresh >/dev/null
sleep 1
if probe; then echo "  resolves: YES"; B=yes; else echo "  resolves: NO"; B=no; fi

echo
if [[ $A == yes && $B == no ]]; then
  echo "VERDICT: the combined form genuinely does not match on this kernel."
  echo "         The fix and its assertion are correct."
elif [[ $A == yes && $B == yes ]]; then
  echo "VERDICT: both forms work. The DNS outage was the VPN blocking the subnet,"
  echo "         not the rule syntax. The commit claiming otherwise is WRONG and"
  echo "         the 'no unqualified l4proto dns rule' assertion should be removed."
else
  echo "VERDICT: inconclusive -- A itself failed, so something else is broken."
fi
