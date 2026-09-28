# Networking

Two modes, four egress policies, and one bridge. This document describes what
each one does, what you control, and how to get internet or DNS into a box when
you want it.

## The two modes

### `--net slirp` (default)

QEMU's user-mode networking. Nothing is created on the host, no privileges are
needed, and there is no bridge, tap or firewall involved at all. QEMU
synthesises an entire network inside the process:

```
guest 10.0.2.15  →  gateway 10.0.2.2  →  (the host's own socket API)
                    resolver 10.0.2.3
```

The guest always has full internet and working DNS. **No egress filtering is
possible in this mode** — the traffic leaves as ordinary connections made by the
QEMU process, so host firewall rules cannot distinguish it from anything else
you run. The guest can also reach your LAN, because it is using your host's
network stack.

You reach the box on `127.0.0.1:222N`, forwarded by QEMU. Publish extra guest
ports with `--port 8080:3000`.

Use slirp when you want isolation of the *filesystem and process space* and do
not care about controlling the network.

### `--net bridge`

A real layer-2 bridge on the host, with a tap device per box and an nftables
policy that decides what each box may talk to. Needs `agentbox net up` once per
host boot, which is the only command that uses `sudo`.

```
                    ┌────────────── host ──────────────┐
                    │                                  │
  box A ── ag2 ─┐   │   agbr0 10.77.0.1/24             │
                ├───┼──►  dnsmasq :53                  ├──► wlp1s0 ──► internet
  box B ── ag3 ─┘   │     egress proxy :812N           │     (NAT)
                    │     nftables policy              │
                    └──────────────────────────────────┘
```

- The bridge holds `10.77.0.1/24`. Each box gets a static `10.77.0.<index>`,
  assigned by cloud-init from its seed, matched on MAC address.
- `dnsmasq` runs bound to `10.77.0.1` only. It is the guests' resolver and
  forwards to 1.1.1.1 and 8.8.8.8. It is not reachable from your LAN.
- Traffic out is masqueraded to your default uplink, or to a VPN interface if
  the box was created with `--vpn`.
- You can reach a bridge box directly at its IP — no port forwarding needed.

## The policy, chain by chain

Three nftables chains in table `inet agentbox`. Order matters, because nftables
is first-match.

**`input`** — what a guest may send to the host itself.

```
1  ct state established,related accept   return traffic for host-initiated flows
2  <per-box rules>                       proxy-mode boxes: proxy port, then drop
3  udp dport 53 accept                   the resolver, for every other box
4  tcp dport 53 accept                   (protocol-qualified: the combined
                                          `meta l4proto {tcp,udp} th dport 53`
                                          form loads but does not match)
5  icmp echo-request accept              ping
6  drop                                  everything else the host runs
```

Rule 1 must come first: you open SSH *to* the guest, so its replies arrive as an
established flow. A per-box drop above it would blackhole them and the box would
never become reachable. A *new* DNS query is `ct state NEW`, so it falls past
rule 1 into a proxy box's drop — which is how proxy mode removes DNS without
breaking SSH.

Rule 6 is why a box cannot reach a database, dev server or SSH daemon you happen
to be running on the host.

**`forward`** — what a guest may send anywhere else.

```
1  ct state established,related accept
2  iif agbr0 oif agbr0 drop              no box-to-box traffic
3  daddr {10/8, 172.16/12, 192.168/16, 169.254/16, 127/8} drop    no LAN
4  <per-box rules>                       depends on --egress
5  drop
```

Rule 3 is what stops a box reaching your router, your NAS, or another machine on
your network.

**`postrouting`** — NAT. Boxes pinned to a VPN masquerade out that interface;
everything else uses the host's default uplink.

## The four egress policies

| `--egress` | Internet | DNS | Filtering | Audited |
| --- | --- | --- | --- | --- |
| `open` | full | yes, via dnsmasq | none beyond the LAN/box-to-box rules | no |
| `allow` | allowlisted IPs | yes, via dnsmasq | resolved IP addresses | no |
| `proxy` | allowlisted hostnames | **no, deliberately** | hostname the guest requests | yes |
| `none` | none | no | n/a | n/a |

`proxy` is the strongest. It filters on the hostname in the guest's `CONNECT`
request rather than on resolved addresses, which matters because an IP allowlist
cannot distinguish two sites sharing a CDN address. The guest is given no DNS
route because the proxy resolves on its behalf — that removes DNS tunnelling as
an exfiltration channel rather than monitoring for it.

It does **not** inspect TLS. An agent that can reach an allowed host can still
exfiltrate through it. Domain filtering constrains *where* data can go, not
whether it goes.

## What you control

**At create time:**

```sh
--net slirp|bridge        which mode
--egress open|allow|proxy|none
--vpn IFACE               pin egress to a tunnel, fail-closed
--port HOST:GUEST         publish a guest port (slirp)
--allow BUNDLE            start with an ecosystem's hostnames
```

**While a box exists:**

```sh
agentbox allow <box> example.com          add one hostname
agentbox allow <box> --bundle rust        add an ecosystem
agentbox allow --list                     what bundles exist
agentbox egress-log <box>                 what it reached, what was refused
agentbox net refresh                      reload the policy after an edit
```

The allowlist is `~/.agentbox/boxes/<box>/allow.txt` — plain text, one host per
line. The proxy re-reads it when it changes, so additions take effect without a
restart. The nftables IP set used by `--egress allow` needs `net refresh`.

**Changing a box's mode after creation:** edit
`~/.agentbox/boxes/<box>/box.conf`, then `agentbox reseed <box>` to rebuild its
cloud-init seed, then `down` and `up`.

**Host-wide defaults** live in `~/.agentbox/agentbox.conf` (copy from
`etc/agentbox.conf`): the bridge name, the subnet, the resolver address, the
SSH port base, and the default egress policy for new boxes.

## "I just want internet and DNS in the box"

Any of these give you both:

```sh
agentbox create myproj --workspace ~/code/myproj                  # slirp, unfiltered
agentbox create myproj --net bridge --egress open --workspace ...  # bridged, unfiltered
```

If you want filtering but find the allowlist too tight, widen it rather than
turning it off — `agentbox egress-log <box>` prints exactly which hostnames were
refused, so the list writes itself:

```sh
agentbox create myproj --net bridge --egress proxy --allow python --allow github
# ... work for a while ...
agentbox egress-log myproj          # shows the denials
agentbox allow myproj files.example.com
```

**If you specifically want DNS inside a proxy-mode box**, that is a one-line
change in `lib/egress.sh` — remove the per-box `drop` for UDP/TCP 53 in
`egress_input_rules`, or add a `dport 53 accept` above it. It is off by default
because DNS is a working exfiltration channel and proxy mode exists to close
channels. Know what you are turning back on.

## Troubleshooting

**A bridge box has no DNS.** Check the resolver is up and answering:

```sh
pgrep -af dnsmasq
nslookup example.com 10.77.0.1
```

Then check what the guest believes:

```sh
agentbox ssh <box> -- 'resolvectl status | head -20; cat /etc/netplan/50-cloud-init.yaml'
```

The guest should show `10.77.0.1` as its DNS server, set by the cloud-init
network config from its seed.

**A bridge box cannot reach the internet.** Almost always DNS first — test with
an address rather than a name to separate the two:

```sh
agentbox ssh <box> -- 'curl -sS --max-time 10 -o /dev/null https://1.1.1.1 && echo "routing ok"'
agentbox ssh <box> -- 'getent hosts example.com || echo "dns broken"'
```

**Connections time out rather than failing cleanly.** In `proxy` mode a client
that ignores `HTTP_PROXY` connects directly, and nftables drops it — so it fails
closed, but with a timeout instead of a clear error. Check `agentbox egress-log`:
if the host does not appear there at all, the client bypassed the proxy.

**The box is unreachable over ssh.** Networking is the most common thing to
break in a box, and ssh is how you would normally investigate it -- so use the
serial console instead, which does not depend on the guest's network at all:

```sh
agentbox console <box>          # Ctrl-] to detach
```

It logs in as `agent` automatically. The socket lives under `~/.agentbox` and is
reachable only by you, so it grants nothing beyond what the box's ssh key
already would. From there, `ip addr`, `ip route` and `systemctl status
systemd-networkd` tell you what the guest thinks its network is.

A box created before console support was added has no console socket. Give it
one with `agentbox reseed <box>` followed by `down` and `up` -- the reseed is
what makes cloud-init re-run and set up the autologin.

**The policy will not reload.** `net_apply` needs non-interactive sudo. If it
warns, the previously loaded rules are still in force; run
`sudo -v && agentbox net refresh`.
