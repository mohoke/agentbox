#!/bin/bash
# Runs inside a box, piped over ssh by `agentbox netdiag`. Separates the
# failures that look identical from outside: no address, no route, no resolver,
# a resolver that is unreachable, and a proxy that is being bypassed.
#
# Uses only what the base image ships -- no dig, no dnsutils.

say() { printf '  %-34s %s\n' "$1" "$2"; }

# Probe whatever resolver the guest is actually configured with. Falling back to
# the address the host passed would test the wrong thing -- and in slirp mode it
# would quietly succeed by NATing out to the host's bridge, which says nothing
# about the guest's own resolution path.
cur=$(resolvectl status 2>/dev/null | awk '/Current DNS Server/{print $NF; exit}')
DNS=${cur:-${1:-10.77.0.1}}

echo "guest: $(hostname)"

# ---------------------------------------------------------------- address ---
addr=$(ip -4 -br addr show eth0 2>/dev/null | awk '{print $3}')
say "address" "${addr:-NONE (cloud-init did not apply the network config)}"
gw=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
say "default gateway" "${gw:-NONE}"

# ------------------------------------------------------------------ proxy ---
if [[ -n ${https_proxy-}${HTTPS_PROXY-} ]]; then
  say "proxy env" "${https_proxy:-$HTTPS_PROXY}"
else
  say "proxy env" "unset (direct egress expected)"
fi

# ----------------------------------------------------------------- routing --
# An IP literal, so this says nothing about DNS.
if code=$(timeout 8 curl -sS -o /dev/null -w '%{http_code}' https://1.1.1.1 2>/dev/null); then
  say "routing (https to an IP)" "reachable, http $code"
else
  say "routing (https to an IP)" "UNREACHABLE"
fi

# --------------------------------------------------------------- resolver ---
say "resolver the guest believes" "${cur:-none configured (probing $DNS)}"

if timeout 3 bash -c "</dev/tcp/$DNS/53" 2>/dev/null; then
  say "resolver tcp/53" "open"
else
  say "resolver tcp/53" "closed or filtered"
fi

# A raw UDP query, so systemd-resolved's caching and fallbacks are out of the
# picture. This is the question that matters: does the packet reach dnsmasq.
python3 - "$DNS" <<'PY'
import socket, struct, sys
host = sys.argv[1]
q = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
for label in (b"example", b"com"):
    q += bytes([len(label)]) + label
q += b"\x00\x00\x01\x00\x01"
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(4)
try:
    s.sendto(q, (host, 53))
    data, _ = s.recvfrom(512)
    ancount = struct.unpack("!H", data[6:8])[0]
    rcode = data[3] & 0x0F
    print(f"  {'resolver udp/53 (raw query)':<34} answered, rcode={rcode}, {ancount} record(s)")
except socket.timeout:
    print(f"  {'resolver udp/53 (raw query)':<34} NO REPLY (dropped, or dnsmasq not answering)")
except Exception as exc:
    print(f"  {'resolver udp/53 (raw query)':<34} {type(exc).__name__}: {exc}")
PY

if timeout 6 getent ahostsv4 example.com >/dev/null 2>&1; then
  say "name lookup (getent, ipv4)" "works"
else
  say "name lookup (getent, ipv4)" "FAILS"
fi

# ------------------------------------------------------------------ ipv6 ----
n6=$(ip -6 addr show scope global 2>/dev/null | grep -c inet6)
say "global ipv6 addresses" "$n6 (0 is expected; there is no ipv6 uplink)"

# ---------------------------------------------------------------- verdict ---
echo
if [[ -z $addr ]]; then
  echo "  => the guest never configured its address. Check the cloud-init seed"
  echo "     and the serial console: agentbox logs <box>"
elif timeout 6 getent ahostsv4 example.com >/dev/null 2>&1; then
  echo "  => dns and routing both work."
elif timeout 8 curl -sS -o /dev/null https://1.1.1.1 2>/dev/null; then
  echo "  => routing works, dns does not. The packets to $DNS:53 are the problem,"
  echo "     not the route. In proxy mode this is deliberate."
else
  echo "  => neither dns nor routing works. Check the forward chain on the host:"
  echo "     sudo nft list table inet agentbox"
fi
