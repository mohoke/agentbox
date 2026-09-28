#!/usr/bin/env bash
# Validates the nftables ruleset generated for bridge mode without touching the
# host network. Stubs out sudo/ip so `net_apply` renders to stdout instead of
# loading the policy, then asserts the security-relevant rules are present.
set -euo pipefail

AGENTBOX_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export AGENTBOX_ROOT
export AGENTBOX_HOME=$(mktemp -d)
trap 'rm -rf "$AGENTBOX_HOME" "$STUB"' EXIT

STUB=$(mktemp -d)
# `sudo nft -f FILE` prints FILE; every other privileged call is a no-op.
cat > "$STUB/sudo" <<'EOF'
#!/bin/bash
if [[ $1 == nft && $2 == -f ]]; then cat "$3"; fi
exit 0
EOF
# Pretend the bridge exists and the uplink is wlan0.
cat > "$STUB/ip" <<'EOF'
#!/bin/bash
case "$*" in
  *"-j route show default"*) echo '[{"dev":"wlan0"}]' ;;
  *"link show agbr0"*)       exit 0 ;;
esac
exit 0
EOF
# Simulate DNS being unavailable, so the test is deterministic AND exercises the
# graceful-degradation path: a resolver outage must fall back to cached IPs
# rather than emitting an empty set and sealing a box that should have egress.
cat > "$STUB/getent" <<'EOF'
#!/bin/bash
exit 2
EOF
chmod +x "$STUB/sudo" "$STUB/ip" "$STUB/getent"
PATH="$STUB:$PATH"

source "$AGENTBOX_ROOT/lib/common.sh"
load_config
source "$AGENTBOX_ROOT/lib/net.sh"

# A missing helper would silently produce a ruleset with no per-box rules, so
# assert the contract before testing its output.
# apply_bundle lives in bin/agentbox; pull in just that definition.
eval "$(sed -n '/^bundle_file()/,/^}/p;/^apply_bundle()/,/^}/p' "$AGENTBOX_ROOT/bin/agentbox")"

for fn in egress_forward_rules egress_input_rules box_proxy_port apply_bundle; do
  declare -F "$fn" >/dev/null || { echo "FATAL: $fn not defined" >&2; exit 1; }
done

# Three boxes, one per egress policy.
mk() { # mk <name> <index> <egress> [uplink]
  local d="$BOXES_DIR/$1"; mkdir -p "$d"
  cat > "$d/box.conf" <<EOF
BOX_INDEX=$2
BOX_NET=bridge
BOX_EGRESS=$3
BOX_UPLINK=${4-}
BOX_IP=$AGENTBOX_SUBNET.$2
BOX_MAC=52:54:00:ab:00:0$2
BOX_SSH_PORT=$((AGENTBOX_SSH_PORT_BASE + $2))
BOX_CPUS=2
BOX_MEM_MB=2048
BOX_WORKSPACE=$d/workspace
BOX_PORTS=
EOF
  printf 'api.anthropic.com\ngithub.com\n' > "$d/allow.txt"
  # Pre-seed the IP cache so the test does not depend on live DNS.
  printf '160.79.104.10\n140.82.121.4\n' > "$d/allow.ips"
}
mk wide     2 open
mk narrow   3 allow
mk sealed   4 none
mk filtered 5 proxy
mk tunnel   6 open wg-agent

RULES=$(net_apply 2>/dev/null)
echo "$RULES"
echo "--------------------------------------------------------------"

pass=0; fail=0
want() { # want <description> <grep-pattern>
  if grep -qE -- "$2" <<<"$RULES"; then
    printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1))
  else
    printf '  \033[31mFAIL\033[0m %s\n     expected: %s\n' "$1" "$2"; fail=$((fail+1))
  fi
}
deny() { # deny <description> <grep-pattern that must NOT appear>
  if grep -qE -- "$2" <<<"$RULES"; then
    printf '  \033[31mFAIL\033[0m %s (matched %s)\n' "$1" "$2"; fail=$((fail+1))
  else
    printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1))
  fi
}

want "no box-to-box traffic"          'iifname "agbr0" oifname "agbr0" drop'
want "host LAN unreachable"           'ip daddr \{ 10\.0\.0\.0/8.*192\.168\.0\.0/16.*\} drop'
want "host services unreachable"      'iifname "agbr0" drop'
want "DNS to host allowed (udp)"      'iifname "agbr0" udp dport 53 accept'
want "DNS to host allowed (tcp)"      'iifname "agbr0" tcp dport 53 accept'
want "return traffic allowed"         'ct state established,related accept'
want "NAT masquerades the subnet"     'ip saddr 10\.77\.0\.0/24 oifname "wlan0" masquerade'

want "open box: unrestricted egress"  'ip saddr 10\.77\.0\.2 accept'
want "allow box: set-scoped egress"   'ip saddr 10\.77\.0\.3 ip daddr @allow_3 accept'
want "allow box: default drop"        'ip saddr 10\.77\.0\.3 drop'
want "allow box: set is populated"    'elements = \{.*160\.79\.104\.10.*\}'
want "allow box: cache survives DNS outage" 'elements = \{.*140\.82\.121\.4.*\}'
want "sealed box: no egress at all"   'ip saddr 10\.77\.0\.4 drop'
deny "sealed box has no accept rule"  'ip saddr 10\.77\.0\.4 .*accept'
deny "open/none boxes get no set"     'set allow_(2|4)'

# Ordering matters: a drop placed before its accept would silently seal the box.
a=$(grep -n 'ip saddr 10\.77\.0\.3 ip daddr @allow_3 accept' <<<"$RULES" | cut -d: -f1 || true)
d=$(grep -n 'ip saddr 10\.77\.0\.3 drop' <<<"$RULES" | cut -d: -f1 || true)
if [[ -n $a && -n $d && $a -lt $d ]]; then
  printf '  \033[32mok\033[0m   allow rule precedes its drop (line %s < %s)\n' "$a" "$d"; pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m allow/drop ordering wrong (accept=%s drop=%s)\n' "$a" "$d"; fail=$((fail+1))
fi

# --- proxy mode -----------------------------------------------------------
want "proxy box: no forwarding at all"  'ip saddr 10\.77\.0\.5 drop'
# Scoped to the forward chain: the proxy box legitimately has an *input* rule
# permitting it to reach the host-side proxy port, which a whole-ruleset grep
# would wrongly flag as "it can forward out".
FWD=$(sed -n '/chain forward/,/^  }/p' <<<"$RULES")
if grep -qE 'ip saddr 10\.77\.0\.5 .*accept' <<<"$FWD"; then
  printf '  \033[31mFAIL\033[0m proxy box forwards out (should never)\n'; fail=$((fail+1))
else
  printf '  \033[32mok\033[0m   proxy box never forwards out\n'; pass=$((pass+1))
fi
want "proxy box: may reach the proxy"   'ip saddr 10\.77\.0\.5 tcp dport 8123 accept'

# Regression: nftables is first-match, so the proxy box's drop has to come
# BEFORE the blanket DNS accept, or proxy mode silently keeps a DNS channel.
IN=$(sed -n '/chain input/,/^  }/p' <<<"$RULES")
p_drop=$(grep -n 'ip saddr 10\.77\.0\.5 drop' <<<"$IN" | head -1 | cut -d: -f1 || true)
dns_ln=$(grep -n 'udp dport 53 accept'         <<<"$IN" | head -1 | cut -d: -f1 || true)
if [[ -n $p_drop && -n $dns_ln && $p_drop -lt $dns_ln ]]; then
  printf '  \033[32mok\033[0m   proxy box denied DNS (drop at %s precedes accept at %s)\n' "$p_drop" "$dns_ln"
  pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m proxy box can still reach DNS (drop=%s, dns accept=%s)\n' "$p_drop" "$dns_ln"
  fail=$((fail+1))
fi
# Return traffic must be accepted before any per-box drop, or the host can
# never ssh in to a proxy-mode box: its replies arrive as an established flow.
ct_ln=$(grep -n 'ct state established,related accept' <<<"$IN" | head -1 | cut -d: -f1 || true)
if [[ -n $ct_ln && -n $p_drop && $ct_ln -lt $p_drop ]]; then
  printf '  \033[32mok\033[0m   return traffic accepted before per-box drops (ssh works)\n'
  pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m per-box drop precedes ct-established: ssh to the box would hang\n'
  fail=$((fail+1))
fi

# Non-proxy boxes must keep their resolver.
o_drop=$(grep -n 'ip saddr 10\.77\.0\.2 drop' <<<"$IN" | head -1 | cut -d: -f1 || true)
if [[ -z $o_drop ]]; then
  printf '  \033[32mok\033[0m   non-proxy box keeps DNS access\n'; pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m non-proxy box lost DNS access\n'; fail=$((fail+1))
fi
want "proxy box: nothing else to host"  'ip saddr 10\.77\.0\.5 drop'

# --- vpn kill switch ------------------------------------------------------
want "vpn box: leaves only via tunnel"  'ip saddr 10\.77\.0\.6 oifname "wg-agent" accept'
want "vpn box: fails closed otherwise"  'ip saddr 10\.77\.0\.6 drop'
want "vpn box: masquerades out tunnel"  'ip saddr 10\.77\.0\.6 oifname "wg-agent" masquerade'

# The kill switch is only a kill switch if the accept is bound to the tunnel
# interface. An unqualified accept for this box would leak to the default route
# the moment the VPN dropped.
if grep -qE 'ip saddr 10\.77\.0\.6 accept' <<<"$RULES"; then
  printf '  \033[31mFAIL\033[0m vpn box has an unqualified accept (would leak)\n'; fail=$((fail+1))
else
  printf '  \033[32mok\033[0m   vpn box has no unqualified accept\n'; pass=$((pass+1))
fi

v_a=$(grep -n 'ip saddr 10\.77\.0\.6 oifname "wg-agent" accept' <<<"$RULES" | cut -d: -f1 || true)
v_d=$(grep -n 'ip saddr 10\.77\.0\.6 drop' <<<"$RULES" | cut -d: -f1 || true)
if [[ -n $v_a && -n $v_d && $v_a -lt $v_d ]]; then
  printf '  \033[32mok\033[0m   vpn accept precedes its kill-switch drop\n'; pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m vpn rule ordering wrong (accept=%s drop=%s)\n' "$v_a" "$v_d"; fail=$((fail+1))
fi

# --- allowlist and bundles ------------------------------------------------
echo "pypi.org" >> "$BOXES_DIR/narrow/allow.txt"
grep -qx "pypi.org" "$BOXES_DIR/narrow/allow.txt" && { printf '  \033[32mok\033[0m   allowlist is append-only text\n'; pass=$((pass+1)); }

before=$(wc -l < "$BOXES_DIR/narrow/allow.txt")
apply_bundle "$BOXES_DIR/narrow" rust >/dev/null 2>&1
if grep -qx "crates.io" "$BOXES_DIR/narrow/allow.txt"; then
  printf '  \033[32mok\033[0m   bundle adds its hosts\n'; pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m bundle did not add its hosts\n'; fail=$((fail+1))
fi
# Re-applying must not duplicate entries: allow.txt feeds both the nftables set
# and the proxy, and duplicates inflate both.
apply_bundle "$BOXES_DIR/narrow" rust >/dev/null 2>&1
if [[ $(grep -cx "crates.io" "$BOXES_DIR/narrow/allow.txt") -eq 1 ]]; then
  printf '  \033[32mok\033[0m   re-applying a bundle is idempotent\n'; pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m bundle duplicated entries on re-apply\n'; fail=$((fail+1))
fi
# Comment lines in a bundle must not leak into the allowlist.
if grep -q '^#' "$BOXES_DIR/narrow/allow.txt" && \
   grep -qE '^# Rust' "$BOXES_DIR/narrow/allow.txt"; then
  printf '  \033[31mFAIL\033[0m bundle comments leaked into allow.txt\n'; fail=$((fail+1))
else
  printf '  \033[32mok\033[0m   bundle comments are stripped\n'; pass=$((pass+1))
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
exit $(( fail > 0 ))
