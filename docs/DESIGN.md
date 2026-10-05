# agentbox — design notes

## Is the idea good?

The core instinct is right, and it is the one most people get wrong: the thing
worth isolating is **the agent's blast radius**, not the agent's individual
actions. Per-action permission prompts are a tax you pay forever and that
degrades as you get tired of reading them; a boundary you draw once and then
stop thinking about is strictly better. One VM per project is that boundary,
and it buys three things at once:

1. **Containment.** A bad `rm -rf`, a poisoned npm postinstall, or a prompt
   injection from a scraped web page reaches one project's VM and nothing else.
2. **Reproducibility.** The environment is a build artifact. "Works on my
   machine" stops being a category of bug, and a broken box is a `reset` away.
3. **Permission to be autonomous.** This is the real payoff. Inside a box you
   can hand the agent `--dangerously-skip-permissions` honestly, because the
   thing it might damage is disposable.

Two caveats worth having in view before you build on it:

- **A VM boundary is not a secrets boundary.** The moment the agent holds a
  credential — your Anthropic OAuth token, a GitHub PAT, a staging DB password
  — isolation stops protecting that credential. The agent can use it, and so
  can anything that successfully manipulates the agent. Isolation limits what
  an agent can *reach*, not what it can *do with what you gave it*. Scope
  credentials per box; never copy your host `~/.claude` into a VM.
- **Egress is the leak path, not the filesystem.** People fixate on filesystem
  isolation and then give the VM unrestricted internet, which makes the
  filesystem question mostly moot. The interesting control is the network
  policy, which is why it gets first-class treatment here.

## Why not Firecracker

Firecracker is excellent at what it was built for: running many short-lived,
untrusted, *fungible* workloads on a fleet, where a 125 ms boot and a 5 MiB
memory overhead multiplied by ten thousand is the whole ballgame. Your case is
the opposite shape — a handful of long-lived, heavyweight, individually
precious dev boxes on one laptop. You'd be paying Firecracker's costs without
collecting its benefits:

| | Firecracker | QEMU + KVM (this design) |
| --- | --- | --- |
| Host file sharing | **None.** No virtio-fs, no 9p. Sharing a project dir means a block device, a network FS, or git push/pull. | virtio-fs; `~/workspace` in the VM *is* the host directory. |
| Boot media | You build and maintain an uncompressed kernel + ext4 rootfs. | Boots a stock Ubuntu cloud image unmodified. |
| Networking | You create the tap, assign the IP, write the NAT rules. No DHCP, no user-mode fallback. | Same tap path when you want it, plus a zero-privilege user-mode option. |
| Disk layout | Raw images; no copy-on-write. Each box is a full copy. | qcow2 backing files: each box is a thin CoW overlay on one shared base. |
| Devices | No PCI, no hotplug, no GPU. | Whatever you need later. |
| Boot time | ~125 ms | ~8 s cold |

That last row is the one that looks decisive and isn't. You boot a project box
once and leave it up for days. Eight seconds, once, is not a cost worth
restructuring an architecture around — whereas "no file sharing" is a
structural constraint you'd feel every single day.

The right reason to revisit this is **fan-out**: if you later want thirty
ephemeral boxes to run a test matrix or race several agents on the same task,
Firecracker's snapshot/restore (clone a pre-warmed VM in ~150 ms) genuinely has
no equivalent here. The CLI boundary in this design is deliberately thin enough
that swapping the VMM underneath it later is a contained change.

## Why not containers

Worth stating plainly, since it is the cheaper option: a container with a
separate user namespace gets you maybe 85% of this at 10% of the cost. What you
give up is a shared kernel — every container escape in the last decade has been
a kernel bug — and the ability to let the agent use `sudo`, load modules, run
its own systemd, or mess with the network freely. Given that the *point* is to
stop supervising the agent, the stronger boundary earns its keep.

## Architecture

```
host                                                    guest (per project)
────────────────────────────────────────────────────    ─────────────────────
~/.agentbox/images/base.qcow2  ◄── qcow2 backing ────    /            (CoW, disposable)
~/.agentbox/boxes/<n>/disk.qcow2 ──────────────────►
~/code/<project>/              ◄── virtio-fs ───────►    ~/workspace  (shared, durable)
                                                         ~/scratch    (VM-local, fast)
agbr0 10.77.0.1  ──nftables/NAT──►  internet             eth0 10.77.0.N
      ▲                                                        │
      └──────────────── tap agN ──────────────────────────────┘
ssh -F ~/.agentbox/ssh_config <n>  ──────────────────►   sshd (key-only, user `agent`)
```

Three decisions carry most of the weight:

**The base image is a build artifact, sealed read-only.** `agentbox build`
boots a stock Ubuntu cloud image once with a cloud-init seed, runs
`image/provision.sh` inside it, `cloud-init clean`s the result, and marks it
`chmod 444`. Every box is then a qcow2 overlay on top — creating a box is
instant and costs a few hundred KB, and `agentbox reset` throws the overlay
away to get a guaranteed-clean environment back. Rebuilding the base is how you
roll out a new toolchain to every project at once.

**The workspace lives on the host.** This is the inversion that makes the whole
thing comfortable. The VM is disposable *because* nothing irreplaceable is
inside it. Your git history, your editor, your backups, and your normal
`ls ~/code/myproject` all keep working from the host, unchanged. virtio-fs
carries the directory into the guest at `~/workspace`, where the guest `agent`
user is uid 1000 so ownership lines up with yours and no uid-shifting is needed.

**Network policy is per box, and there are three of them.** `open` is plain NAT.
`allow` resolves a domain list into an nftables IP set and drops everything
else. `none` is an air-gapped box that can still reach its own Postgres and
whatever you put in `~/workspace`. Independently of the policy, no box can
reach another box, the host's LAN, or any host service except the DNS resolver
on the bridge.

## Known limits, stated honestly

- **IP-based allowlisting is porous.** Allowing `github.com` allows every other
  site on the same CDN addresses. It raises the cost of casual exfiltration and
  stops an agent from wandering; it is not a hard information barrier. A
  filtering HTTPS proxy (guest trusts a local CA, proxy enforces SNI/CONNECT
  rules) is the real version of this feature and the obvious next increment.
- **virtio-fs is a deliberate hole in the boundary**, scoped to exactly one
  directory. Anything the agent writes to `~/workspace` lands on your host
  filesystem — which is the entire point, and also why you should review the
  diff before you run a build script the agent wrote.
- **`agentbox net up` needs sudo** once per host boot (bridge, NAT, dnsmasq).
  Everything else — build, create, up, down, ssh — runs fully unprivileged.
  `--net slirp` avoids the sudo entirely at the cost of the egress policy.
- **No snapshot/restore, no fan-out.** One box per project, booted by hand.
  See "Why not Firecracker" for when this stops being enough.
- **Credentials are per box and are not managed for you.** `agentbox` copies
  nothing into a guest by default; `--creds share` opts in. See README →
  Credentials.
