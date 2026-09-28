# shellcheck shell=bash
# Egress control: the domain-filtering proxy, VPN uplink routing, and the
# kill switch that stops VPN-bound traffic leaking to the default route.
#
# Sourced by bin/agentbox after lib/net.sh.

PROXY_BIN="${PROXY_BIN:-$AGENTBOX_ROOT/bin/agentbox-egress-proxy}"

# Each box gets its own proxy port so its allowlist and audit log stay separate.
box_proxy_port() { printf '%s' "$(( 8118 + $1 ))"; }

# Routing table id used for a box's VPN policy route.
box_rt_table()   { printf '%s' "$(( 200 + $1 ))"; }

# ------------------------------------------------------------------ proxy ---
proxy_start() {
  # proxy_start <box_dir> <index>  -- listens on the bridge address only, so it
  # is unreachable from the host's LAN and from boxes that are not routed to it.
  local bd=$1 idx=$2
  local port; port=$(box_proxy_port "$idx")
  local pidfile="$bd/run/proxy.pid"

  if [[ -s $pidfile ]] && kill -0 "$(<"$pidfile")" 2>/dev/null; then
    return 0
  fi
  [[ -x $PROXY_BIN ]] || die "egress proxy not found at $PROXY_BIN"

  setsid python3 "$PROXY_BIN" \
      --allow-file "$bd/allow.txt" \
      --listen "$AGENTBOX_HOST_IP" --port "$port" \
      --log "$bd/run/egress.jsonl" \
      >"$bd/run/proxy.err" 2>&1 &
  echo $! > "$pidfile"

  local t=0
  while (( t < 40 )); do
    if (exec 3<>"/dev/tcp/$AGENTBOX_HOST_IP/$port") 2>/dev/null; then exec 3>&- ; return 0; fi
    sleep 0.1; t=$((t+1))
  done
  warn "egress proxy did not come up (see $bd/run/proxy.err)"
  return 1
}

proxy_stop() {
  local bd=$1
  [[ -s $bd/run/proxy.pid ]] || return 0
  kill "$(<"$bd/run/proxy.pid")" 2>/dev/null || true
  rm -f "$bd/run/proxy.pid"
}

# ------------------------------------------------------------ vpn routing ---
vpn_iface_up() { ip -br link show "$1" 2>/dev/null | grep -qE 'UP|UNKNOWN'; }

vpn_route_apply() {
  # vpn_route_apply <box_ip> <index> <iface>
  # Policy-route this box's traffic out the VPN interface. Without this the
  # masquerade rule would rewrite the source address but the packet would still
  # follow the main table to the physical uplink.
  local ip=$1 idx=$2 iface=$3
  local table; table=$(box_rt_table "$idx")

  vpn_iface_up "$iface" || die "vpn interface '$iface' is not up"
  sudo ip route replace default dev "$iface" table "$table" 2>/dev/null \
    || die "could not add default route via $iface (table $table)"
  sudo ip rule del from "$ip" lookup "$table" 2>/dev/null || true
  sudo ip rule add from "$ip" lookup "$table" priority 1000
}

vpn_route_clear() {
  local ip=$1 idx=$2
  local table; table=$(box_rt_table "$idx")
  sudo ip rule del from "$ip" lookup "$table" 2>/dev/null || true
  sudo ip route flush table "$table" 2>/dev/null || true
}

# ------------------------------------------------------------- nft helpers --
# Emitted into the forward chain by net_apply, per box.
egress_forward_rules() {
  # egress_forward_rules <egress> <ip> <index> <uplink>
  local mode=$1 ip=$2 idx=$3 uplink=$4
  local br=$AGENTBOX_BRIDGE

  case $mode in
    open)
      if [[ -n $uplink ]]; then
        # VPN kill switch: this box may leave ONLY via the tunnel. If the
        # interface drops, the rule stops matching and the final drop catches
        # the packet, so traffic fails closed instead of falling back.
        echo "    iifname \"$br\" ip saddr $ip oifname \"$uplink\" accept"
        echo "    iifname \"$br\" ip saddr $ip drop"
      else
        echo "    iifname \"$br\" ip saddr $ip accept"
      fi ;;
    allow)
      local oif=""; [[ -n $uplink ]] && oif="oifname \"$uplink\" "
      echo "    iifname \"$br\" ip saddr $ip ip daddr @allow_$idx ${oif}accept"
      echo "    iifname \"$br\" ip saddr $ip drop" ;;
    proxy|none)
      # Both deny all forwarding. In proxy mode the box reaches the outside
      # world only through the host-side proxy, which is an input-chain path,
      # never a forwarded one.
      echo "    iifname \"$br\" ip saddr $ip drop" ;;
  esac
}

# Emitted into the input chain: what a box may send to the host itself.
egress_input_rules() {
  # egress_input_rules <egress> <ip> <index>
  local mode=$1 ip=$2 idx=$3
  local br=$AGENTBOX_BRIDGE
  if [[ $mode == proxy ]]; then
    # Reaching the proxy is the box's only route out. DNS is deliberately NOT
    # opened: the proxy resolves on the guest's behalf, which removes DNS
    # tunnelling as an exfiltration channel entirely.
    echo "    iifname \"$br\" ip saddr $ip tcp dport $(box_proxy_port "$idx") accept"
    echo "    iifname \"$br\" ip saddr $ip drop"
  fi
}

# ------------------------------------------------------------------ report --
egress_log_summary() {
  # egress_log_summary <box_dir> [n]  -- human-readable tail of the audit log.
  local bd=$1 n=${2:-40} log="$bd/run/egress.jsonl"
  [[ -s $log ]] || { warn "no egress log yet (proxy mode not in use, or no traffic)"; return 0; }
  python3 - "$log" "$n" <<'PY'
import json, sys, collections
path, n = sys.argv[1], int(sys.argv[2])
rows, counts = [], collections.Counter()
for line in open(path, encoding="utf-8"):
    try: r = json.loads(line)
    except json.JSONDecodeError: continue
    if r.get("event") in ("allow", "deny", "error"):
        rows.append(r); counts[(r["event"], r.get("host", "?"))] += 1

allowed = sum(v for (e, _), v in counts.items() if e == "allow")
denied  = sum(v for (e, _), v in counts.items() if e == "deny")
print(f"  {allowed} allowed, {denied} denied, {len(rows)} total events\n")
if denied:
    print("  denied hosts (these are what the box tried to reach and could not):")
    for (e, host), c in sorted(counts.items(), key=lambda kv: -kv[1]):
        if e == "deny":
            print(f"    {c:5d}  {host}")
    print()
print(f"  last {min(n, len(rows))} events:")
for r in rows[-n:]:
    mark = {"allow": "ok  ", "deny": "DENY", "error": "err "}[r["event"]]
    size = ""
    if r.get("bytes_down") is not None:
        size = f"  {r['bytes_up']}up/{r['bytes_down']}down"
    print(f"    {r['ts'][11:19]} {mark} {r.get('host','?')}:{r.get('port','')}"
          f"{size}  {r.get('reason','')}")
PY
}
