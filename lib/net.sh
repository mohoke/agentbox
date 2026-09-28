# shellcheck shell=bash
# Bridge-mode networking: one host bridge, one tap per box, and an nftables
# policy that decides what each box may talk to. Everything here needs root and
# is reached through sudo; nothing else in agentbox does.

# net_apply delegates per-box egress policy to lib/egress.sh. Sourcing it here
# makes that dependency real: without it, a caller that loads only net.sh gets a
# ruleset with every per-box rule silently missing, which fails open-ish and is
# exactly the kind of bug a firewall must not have.
# shellcheck source=./egress.sh
source "$AGENTBOX_ROOT/lib/egress.sh"

NFT_TABLE=agentbox
DNSMASQ_PID="$AGENTBOX_HOME/run/dnsmasq.pid"

uplink_iface() { ip -j route show default | jq -r '.[0].dev // empty'; }

# Can we run a privileged command without prompting? Once the bridge is up,
# every create/destroy/allow wants to refresh the policy, and a password prompt
# in the middle of an unrelated command is worse than a clear warning.
sudo_ok() { sudo -n true 2>/dev/null; }

net_is_up() { ip link show "$AGENTBOX_BRIDGE" >/dev/null 2>&1; }

# VPN clients and container runtimes reset ip_forward behind our back, which
# silently kills egress for every bridge box with nothing in the logs to explain
# it. Checked from both `net up` and `net refresh`, not just at box start.
check_ip_forward() {
  [[ $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null) == 1 ]] && return 0
  if sudo_ok; then
    sudo sysctl -qw net.ipv4.ip_forward=1
    warn "ip_forward had been reset to 0 (a VPN client is the usual cause); restored"
  else
    warn "ip_forward is 0, so no bridge box can reach the internet"
    dim  "    restore with: sudo sysctl -w net.ipv4.ip_forward=1"
  fi
}

require_net_up() {
  net_is_up || die "bridge $AGENTBOX_BRIDGE is down -- run: agentbox net up"
  check_ip_forward
}

# ---------------------------------------------------------------- bring up ---
net_up() {
  local up; up=$(uplink_iface)
  [[ -n $up ]] || die "no default route; cannot set up NAT"
  mkdir -p "$AGENTBOX_HOME/run"

  if ! net_is_up; then
    log "creating bridge $AGENTBOX_BRIDGE ($AGENTBOX_HOST_IP/24) uplink=$up"
    sudo ip link add name "$AGENTBOX_BRIDGE" type bridge
    sudo ip addr add "$AGENTBOX_HOST_IP/24" dev "$AGENTBOX_BRIDGE"
    sudo ip link set "$AGENTBOX_BRIDGE" up
  fi
  sudo sysctl -qw net.ipv4.ip_forward=1

  # A resolver bound to the bridge only. Guests get no other route to the host.
  if [[ ! -s $DNSMASQ_PID ]] || ! sudo kill -0 "$(<"$DNSMASQ_PID")" 2>/dev/null; then
    log "starting dnsmasq resolver on $AGENTBOX_HOST_IP"
    sudo dnsmasq --port=53 --listen-address="$AGENTBOX_HOST_IP" \
      --bind-interfaces --no-hosts --no-resolv \
      --server=1.1.1.1 --server=8.8.8.8 \
      --pid-file="$DNSMASQ_PID" --log-facility=- 2>/dev/null \
      || warn "dnsmasq failed to start; guests will have no DNS"
  fi

  net_apply || die "could not load the nftables policy; the bridge is up but unfiltered"
  ok "network up (bridge=$AGENTBOX_BRIDGE uplink=$up)"
}

net_down() {
  log "tearing down agentbox network"
  sudo nft delete table inet "$NFT_TABLE" 2>/dev/null || true
  if [[ -s $DNSMASQ_PID ]]; then sudo kill "$(<"$DNSMASQ_PID")" 2>/dev/null || true; fi
  sudo rm -f "$DNSMASQ_PID"
  local n i
  for n in $(list_boxes); do
    i=$(sed -n 's/^BOX_INDEX=//p' "$(box_conf "$n")")
    sudo ip link del "ag$i" 2>/dev/null || true
  done
  if net_is_up; then sudo ip link del "$AGENTBOX_BRIDGE" 2>/dev/null || true; fi
  ok "network down"
}

# ------------------------------------------------------------- tap devices ---
tap_up() {
  # tap_up <index> -- a persistent tap the unprivileged qemu can open by name.
  local dev="ag$1"
  ip link show "$dev" >/dev/null 2>&1 && return 0
  sudo ip tuntap add dev "$dev" mode tap user "$USER"
  sudo ip link set "$dev" master "$AGENTBOX_BRIDGE"
  sudo ip link set "$dev" up
}

tap_down() { sudo ip link del "ag$1" 2>/dev/null || true; }

# ---------------------------------------------------------- dns resolution ---
resolve_hosts() {
  # Print the A records for every host named on stdin, one IP per line.
  local h
  while read -r h; do
    h=${h%%#*}; h=${h// /}
    [[ -z $h ]] && continue
    getent ahostsv4 "$h" 2>/dev/null | awk '/STREAM/ {print $1}' | sort -u
  done | sort -u
}

box_allow_ips() {
  # box_allow_ips <box_dir> -- resolved allowlist, unioned with what we saw
  # before, so a DNS hiccup narrows the policy gradually instead of locking
  # the box out all at once.
  # Declared separately: bash expands every argument to `local` before running
  # it, so "$bd" would still be unbound if cache were set in the same statement.
  local bd=$1
  local cache="$bd/allow.ips"
  local fresh
  fresh=$(resolve_hosts < "$bd/allow.txt" || true)
  if [[ -n $fresh ]]; then
    { cat "$cache" 2>/dev/null; echo "$fresh"; } | sort -u | tail -n 500 > "$cache.tmp"
    mv "$cache.tmp" "$cache"
  fi
  cat "$cache" 2>/dev/null
}

# ------------------------------------------------------------- nft ruleset ---
net_apply() {
  net_is_up || return 0
  check_ip_forward
  local up; up=$(uplink_iface)
  local rules; rules=$(mktemp)

  {
    echo "table inet $NFT_TABLE {"
    # One set per box holding the IPs that box may reach.
    local n
    for n in $(list_boxes); do
      # shellcheck disable=SC1090
      ( source "$(box_conf "$n")"
        [[ $BOX_NET == bridge && $BOX_EGRESS == allow ]] || exit 0
        echo "  set allow_$BOX_INDEX {"
        echo "    type ipv4_addr"
        local ips; ips=$(box_allow_ips "$BOXES_DIR/$n")
        [[ -n $ips ]] && echo "    elements = { $(echo "$ips" | paste -sd, -) }"
        echo "  }" )
    done

    # Guest -> host. Only the resolver is exposed; the host's own services
    # (ssh, dev servers, databases) stay invisible from inside a box.
    echo "  chain input {"
    echo "    type filter hook input priority 0; policy accept;"
    # Return traffic first. The host opens ssh TO the guest, so the guest's
    # replies arrive here as an established flow; a per-box drop placed above
    # this would blackhole them and the box would never become reachable.
    # Conntrack state cannot be forged by the guest for a flow that does not
    # exist, so this does not weaken the per-box policy below.
    echo "    iifname \"$AGENTBOX_BRIDGE\" ct state established,related accept"

    # Per-box rules then precede the generic accepts. nftables is first-match,
    # so a blanket "dport 53 accept" above a proxy box's drop would hand that
    # box a DNS channel -- the exfiltration path proxy mode exists to remove.
    # A new DNS query is ct state NEW, so it falls through to the drop.
    for n in $(list_boxes); do
      # shellcheck disable=SC1090
      ( source "$(box_conf "$n")"
        [[ $BOX_NET == bridge ]] || exit 0
        egress_input_rules "$BOX_EGRESS" "$BOX_IP" "$BOX_INDEX" )
    done
    # Two explicit rules rather than `meta l4proto { tcp, udp } th dport 53`.
    # That combined form loads without complaint but does not match here, so
    # DNS fell through to the chain's drop and no bridge box could resolve --
    # while ICMP, matched by the next rule, still worked and made the network
    # look half-alive. Protocol-qualified matches are unambiguous.
    echo "    iifname \"$AGENTBOX_BRIDGE\" udp dport 53 accept"
    echo "    iifname \"$AGENTBOX_BRIDGE\" tcp dport 53 accept"
    echo "    iifname \"$AGENTBOX_BRIDGE\" icmp type echo-request accept"
    echo "    iifname \"$AGENTBOX_BRIDGE\" drop"
    echo "  }"

    echo "  chain forward {"
    echo "    type filter hook forward priority 0; policy accept;"
    echo "    ct state established,related accept"
    # Boxes are peers of nothing: no box-to-box, no reaching the host's LAN.
    echo "    iifname \"$AGENTBOX_BRIDGE\" oifname \"$AGENTBOX_BRIDGE\" drop"
    echo "    iifname \"$AGENTBOX_BRIDGE\" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 127.0.0.0/8 } drop"
    for n in $(list_boxes); do
      # shellcheck disable=SC1090
      ( source "$(box_conf "$n")"
        [[ $BOX_NET == bridge ]] || exit 0
        egress_forward_rules "$BOX_EGRESS" "$BOX_IP" "$BOX_INDEX" "${BOX_UPLINK-}" )
    done
    # Anything on the bridge without a box rule has no business leaving.
    echo "    iifname \"$AGENTBOX_BRIDGE\" drop"
    echo "  }"

    echo "  chain postrouting {"
    echo "    type nat hook postrouting priority srcnat; policy accept;"
    # Boxes pinned to a VPN masquerade out that interface; the rest use the
    # host's default uplink.
    for n in $(list_boxes); do
      # shellcheck disable=SC1090
      ( source "$(box_conf "$n")"
        [[ $BOX_NET == bridge && -n ${BOX_UPLINK-} ]] || exit 0
        echo "    ip saddr $BOX_IP oifname \"$BOX_UPLINK\" masquerade" )
    done
    echo "    ip saddr $AGENTBOX_SUBNET.0/24 oifname \"$up\" masquerade"
    echo "  }"
    echo "}"
  } > "$rules"

  if ! sudo_ok; then
    rm -f "$rules"
    warn "cannot refresh the nftables policy: sudo needs a password"
    dim  "    the policy already loaded is still in force; to pick up this change:"
    dim  "        sudo -v && agentbox net refresh"
    return 1
  fi

  sudo nft delete table inet "$NFT_TABLE" 2>/dev/null || true
  if ! sudo nft -f "$rules"; then
    cat "$rules" >&2
    rm -f "$rules"
    warn "nftables rejected the generated ruleset (printed above)"
    return 1
  fi
  rm -f "$rules"
}

net_status() {
  if net_is_up; then
    ok "bridge $AGENTBOX_BRIDGE up, uplink $(uplink_iface)"
    ip -br addr show "$AGENTBOX_BRIDGE"
    sudo nft list table inet "$NFT_TABLE" 2>/dev/null || warn "no nftables policy loaded"
  else
    warn "bridge $AGENTBOX_BRIDGE is down (slirp boxes are unaffected)"
  fi
}
