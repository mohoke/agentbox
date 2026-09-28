# agentbox threat model

This document exists to be attacked. It states what agentbox claims to defend,
what it explicitly does not, and where the authors already believe it is weak.
If you are reviewing this project, **start here and then go looking for the
places where the claims below are not actually true.**

Last reviewed: 28 September 2026. Status: **alpha — no external security review
has been performed.**

## 1. What is being protected

The asset is **the host machine and everything on it that is not the current
project**: your other repositories, your SSH keys, your browser profile, your
cloud credentials, your LAN, and your personal files.

The agent is given one project directory and a Linux VM. Everything else on the
host should be out of reach, and should stay out of reach without you approving
individual actions.

Explicitly **not** the asset: the contents of the project directory itself, or
the credentials you deliberately hand the box. Both are, by design, things the
agent is supposed to be able to use.

## 2. Adversaries considered

| Adversary | Capability assumed | In scope |
| --- | --- | --- |
| **Confused agent** | A capable model acting on a misread situation. No malice; destructive commands, wrong database, `rm -rf` on the wrong path. | Yes — primary |
| **Indirect prompt injection** | An attacker who controls content the agent reads: a dependency's source, a README, an issue body, a web page, a `CLAUDE.md` in the repo. Can steer the agent but cannot execute code directly. | Yes — primary |
| **Malicious dependency** | Arbitrary code execution inside the VM as the `agent` user, at install or build time. | Yes |
| **Malicious agent CLI** | The agent binary itself is backdoored. | Partially — see §6 |
| **Local attacker on the host** | Already has a shell on your host as your user. | **No.** Game over already. |
| **Hypervisor-escape researcher** | A KVM/QEMU 0-day. | **No.** Out of scope; see §5.3 |
| **Network attacker** | On-path between host and internet. | **No.** Standard TLS assumptions apply. |

## 3. Trust boundaries

```
  host user (trusted)
      │
      ├── agentbox CLI ──────────── trusted, runs as you
      │      └── sudo: bridge, taps, nftables, dnsmasq only
      │
  ═══════════ KVM boundary ═══════════════════════════
      │
      ├── guest kernel + userland ── UNTRUSTED
      │      └── agent process, its dependencies, its tools
      │
  ═══════════ virtio-fs (one directory) ══════════════
      │
      └── ~/code/project ────────── SHARED, read-write, host-side
```

Three boundaries, in decreasing strength:

1. **KVM.** The strong one. A compromised guest must break QEMU or the kernel's
   KVM implementation to reach the host.
2. **nftables + the egress proxy.** What the guest can talk to. Enforced on the
   host, not in the guest, so a fully compromised guest cannot lift it.
3. **virtio-fs.** A deliberate hole, scoped to one directory. Anything the agent
   writes there lands on your filesystem. This is the point, and it is also the
   most likely route to harm.

## 4. What agentbox claims

Each claim below is testable. The test that covers it is named. **If you can
falsify one of these, that is the bug report we most want.**

| # | Claim | Covered by |
| --- | --- | --- |
| C1 | An agent cannot read or write host files outside the shared workspace. | `smoke.sh` |
| C2 | An agent cannot reach services on the host (ssh, databases, dev servers). | `net-rules.sh`, `bridge-live.sh` |
| C3 | An agent cannot reach your LAN or other machines on it. | `net-rules.sh`, `bridge-live.sh` |
| C4 | One box cannot reach another box. Enforced by bridge **port isolation** at layer 2, not by the nftables forward chain -- switched frames never reach that chain unless `br_netfilter` is loaded and `bridge-nf-call-iptables` is 1, neither of which agentbox controls. A live test caught this claim being false when that sysctl was 0. | `bridge-live.sh` (asserts the port flag and tests real traffic) |
| C5 | With `--egress proxy`, only allowlisted **hostnames** are reachable, and hostname matching is not defeatable by suffix or prefix confusion. | `egress-proxy.sh` |
| C6 | With `--egress proxy`, the guest has no DNS route, so DNS tunnelling is unavailable. | `bridge-live.sh` |
| C7 | With `--egress none`, no egress is possible. | `net-rules.sh` |
| C8 | With `--vpn IFACE`, traffic fails closed if the tunnel drops — it never falls back to the default route. | `net-rules.sh` |
| C9 | Destroying a box never deletes a workspace directory the user supplied. | manual; `cmd_destroy` |
| C10 | Host credentials never transit the cloud-init seed ISO (an unencrypted file at rest). | `creds.sh` — transfer is over SSH post-boot |

## 5. What agentbox does NOT defend against

This section is the important one. Read it before trusting the tool.

### 5.1 Credentials you give the box

**This is the biggest limitation and it is unavoidable by design.** By default
(`--creds share`) each box receives a copy of your Claude OAuth token. A prompt
injection inside the box can use that token to do anything your account can do.
Isolation bounds what the agent can *reach*; it does nothing about what it can
*do with a credential you handed it*.

The default is convenience-first on purpose: requiring a fresh login per box is
friction that pushes people back to running agents with no isolation at all,
which is worse. `--creds none` exists and is the stricter choice.

A credential-injecting egress proxy — where the proxy holds the secret and adds
it to outbound requests, so the guest never sees it — would remove this and is
the most valuable unbuilt feature. See §8.

### 5.2 Anything the agent writes to your workspace

Code the agent writes lands on your host filesystem, and you will eventually run
it. A build script, a test fixture, a `Makefile`, a git hook, a `package.json`
`postinstall` — any of these executes **outside** the VM with your full
privileges. **agentbox does not protect you from running the code it helped
write.** Review diffs.

### 5.3 Hypervisor escape

If QEMU or KVM has an exploitable bug, the boundary fails. We do not use
`jailer`-style confinement of the QEMU process itself, do not drop QEMU's
privileges beyond running as your user, and do not apply seccomp or AppArmor to
it. **This is a known gap and a good place to contribute.**

### 5.4 IP-allowlist mode is porous

`--egress allow` matches resolved IP addresses. Allowing `github.com` also
allows every other site on those CDN addresses. It raises the cost of casual
exfiltration; it is not an information barrier. Prefer `--egress proxy`.

### 5.5 The proxy does not inspect TLS

`--egress proxy` filters on the hostname in the `CONNECT` request. It does not
terminate TLS, so it cannot see what is sent to an allowed host. An agent that
can reach an allowed host can exfiltrate through it — a GitHub gist, an issue
comment, a DNS-over-HTTPS endpoint that happens to be allowlisted. Domain
filtering constrains *where* data can go, not *whether* data goes.

Additionally: a client that ignores `HTTP_PROXY` and connects directly is
blocked by nftables rather than by the proxy, so it fails closed — but it fails
with a timeout rather than a clear error, which is confusing.

### 5.6 Denial of service, resource exhaustion, cryptomining

A box can burn its allotted CPU and memory. There is no quota on disk growth
inside the overlay, and a box with `--egress open` can mine cryptocurrency on
your electricity. Not currently addressed.

### 5.7 Guest-to-guest via the shared workspace

If two boxes are pointed at the same workspace directory, they can communicate
through it, and C4 does not hold at the filesystem layer. Nothing prevents this
configuration.

### 5.8 Supply chain of the base image

The base image is built from a stock Ubuntu cloud image plus packages from
Ubuntu, NodeSource, npm and two `curl | bash` installers (`claude.ai/install.sh`,
`opencode.ai/install`). **We pipe remote scripts into bash during image build.**
That is a real supply-chain exposure, mitigated only by it happening once, in a
throwaway VM, with the result sealed. There is no signature verification and no
pinning. This is a legitimate criticism and we would welcome a better design.

## 6. Known weaknesses the authors already believe exist

Listed so reviewers spend time on new ground rather than rediscovering these.

- **The egress proxy is ~300 lines of hand-written Python speaking HTTP.** It
  parses attacker-adjacent input. It has had no fuzzing and no adversarial
  review. Request smuggling, header injection, and resource exhaustion via many
  half-open connections are all plausible. `bin/agentbox-egress-proxy`.
- **`net_apply` regenerates the entire nftables table on every change**, with a
  `delete table` immediately before `nft -f`. There is a window, however brief,
  with no policy loaded. A running box could transmit during it.
- **Allowlist IP cache only grows.** `box_allow_ips` unions new resolutions with
  cached ones and truncates at 500 entries. A domain that was once allowed keeps
  its old addresses until eviction, and those addresses may be reassigned.
- **cloud-init seeds are world-readable ISOs** in `~/.agentbox/boxes/<n>/`. They
  contain the box's SSH public key and network config — not secrets, but they do
  describe your setup. Directory permissions are inherited from `$HOME`.
- **No verification that the base image is the one we built.** Boxes trust
  `base.qcow2` by path. Nothing detects tampering.
- **`--sandbox none` on virtiofsd.** Required because this host restricts
  unprivileged user namespaces. The daemon runs as your user, so it can reach
  any file you can — it is only pointed at one directory by configuration, not
  confined to it by the kernel.
- **A malicious agent CLI is only partially contained.** It runs in the VM, so
  C1–C7 hold, but it holds your token (§5.1) and can write to your workspace
  (§5.2).

## 7. Questions we would like reviewers to answer

1. Can you get out of `--egress proxy` mode? Hostname confusion, HTTP request
   smuggling through the CONNECT handler, IPv6, or a protocol the proxy
   mishandles.
2. Can a guest reach the host during the `net_apply` reload window?
3. Is the virtio-fs configuration sound? Can a guest traverse outside the shared
   directory via symlinks, `..`, or `openat2` tricks?
4. Is the cloud-init seed a viable injection vector into the guest's early boot?
5. Does the VPN kill switch actually fail closed under interface flap, not just
   in the generated ruleset?
6. Is there a path from a compromised guest to the host QEMU process that does
   not require a KVM 0-day — for example through the QMP socket, the virtiofsd
   socket, or the serial log?

## 8. Planned mitigations, not yet built

- **Credential-injecting proxy** so the guest never holds a token (§5.1). This is
  the single highest-value improvement.
- **Confine the QEMU process**: seccomp, AppArmor, a dedicated uid (§5.3).
- **Atomic ruleset swap** to close the reload window (§6).
- **Pin and verify** what the base image installs (§5.8).
- **Per-box resource quotas** (§5.6).

## 9. Reporting

Do not open a public issue for an exploitable weakness. See
[SECURITY.md](../SECURITY.md).
