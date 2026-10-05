# agentbox

One disposable KVM virtual machine per project, so coding agents can run
unsupervised without you approving anything day to day.

Each box boots from a shared base image with Python, Node, PostgreSQL, `claude`
and `opencode` already installed, mounts your project directory from the host at
`~/workspace`, and is reachable over SSH — including from VS Code Remote-SSH.
The VM is throwaway; the workspace is not.

```sh
agentbox create myproj --workspace ~/code/myproj --net bridge --egress proxy
agentbox up myproj
agentbox ssh myproj -- 'cd ~/workspace && claude --dangerously-skip-permissions -p "fix the failing tests"'
agentbox egress-log myproj      # everything it tried to reach, and what was refused
```

> [!WARNING]
> **Alpha. No external security review has been performed.** The isolation
> claims in [`docs/THREAT-MODEL.md`](docs/THREAT-MODEL.md) are tested by this
> repository's own suites and nothing else. Do not rely on it to contain
> genuinely hostile code until someone other than the authors has tried to break
> it — and if you do try, please tell us what you find.

## Please attack this

This project is public in order to be reviewed. The threat model states what
agentbox claims (§4), what it explicitly does not defend (§5), the weaknesses
the authors already believe exist (§6), and the questions we would most like
answered (§7). The sharpest surfaces:

| File | Why it is interesting |
| --- | --- |
| `bin/agentbox-egress-proxy` | ~300 lines of hand-written HTTP parsing directly on a trust boundary. No fuzzing, no adversarial review. |
| `lib/net.sh` | The generated nftables ruleset — rule ordering, and the window during regeneration when no policy is loaded. |
| `bin/agentbox` `build_seed()` | What gets injected into the guest's early boot via cloud-init. |
| `cmd_up` virtio-fs setup | `--sandbox none`, and what actually bounds the daemon to one directory. |

Findings that force a rewrite of one of those are the most useful thing the
project can receive. See [SECURITY.md](SECURITY.md) for disclosure.

## Why a VM and not a container

The full argument is in [docs/DESIGN.md](docs/DESIGN.md), including why this is
QEMU+KVM rather than Firecracker. The short version: a container shares your
kernel, and the point of the exercise is to stop supervising the agent — which
means the boundary has to be worth not watching. A VM also lets the agent use
`sudo`, run its own systemd, and break its environment freely, because the
environment is disposable.

## Requirements

Ubuntu/Debian host with KVM. Everything except `nft`/`dnsmasq` is needed:

```sh
sudo apt install qemu-system-x86 qemu-utils virtiofsd xorriso jq nftables dnsmasq
sudo usermod -aG kvm "$USER"     # log out and back in
./bin/agentbox doctor
```

## Quick start

```sh
./bin/agentbox build                             # ~10 min, once
./bin/agentbox ssh-config --install              # wire box names into ~/.ssh/config
./bin/agentbox create myproj --workspace ~/code/myproj
./bin/agentbox up myproj
./bin/agentbox ssh myproj                        # shell inside
./bin/agentbox code myproj                       # VS Code, remote, on the workspace
```

> [!NOTE]
> VS Code Remote-SSH downloads its server **on your machine** and copies it over
> SSH. If your host has restricted or slow connectivity to Microsoft's CDN, the
> connection hangs at `Downloading VS Code server locally...` even though the box
> itself can reach it. Set `"remote.SSH.localServerDownload": "off"` to make the
> box fetch its own copy.

Put `bin/` on your `PATH` (or symlink `bin/agentbox` into `~/.local/bin`) and
drop the `./bin/` prefix from here on.

## What a box gives the agent

`~/workspace` is your host directory, shared over virtio-fs — the agent's edits
appear on the host immediately and survive the VM. `~/scratch` is VM-local and
disappears on `reset`. Installed and ready: Python 3 with `venv`/`pip`/`pipx`/`uv`,
Node with `npm`, PostgreSQL (role `agent` is superuser, `psql` works bare),
`git`, `build-essential`, `rg`, `fd`, `jq`, `sqlite3`, `tmux`, and passwordless
`sudo`.

`image/CLAUDE.md` is installed at `~/.claude/CLAUDE.md` in the guest, so every
agent session in every box starts knowing the layout, the conventions, and that
it is safe to act without asking. Edit that file and `agentbox build --force` to
roll the change out everywhere.

## Networking

Pick per box with `--net`:

**`slirp`** (default) — QEMU user-mode networking. No privileges, nothing to set
up, SSH forwarded to `127.0.0.1:222N`. Publish guest ports with
`--port 8080:3000`. No egress filtering is possible in this mode.

**`bridge`** — a tap on a host bridge with NAT and an nftables policy. Needs
`agentbox net up` once per host boot (the only command that uses sudo). The box
gets a real IP you can reach directly from the host, and `--egress` decides what
it can reach:

| `--egress` | Effect |
| --- | --- |
| `open` | Plain NAT to the internet. |
| `allow` | Only IPs resolved from the box's `allow.txt`. Everything else drops. |
| `proxy` | **Domain-filtered** through a host-side CONNECT proxy, fully audited, with no DNS egress at all. |
| `none` | No egress at all. Local Postgres and `~/workspace` still work. |

`proxy` is the strongest of the four and the one to prefer. It filters on the
hostname the guest actually requests rather than on resolved IPs, which is what
Anthropic's native `/sandbox`, Claude Code cloud and Codex Cloud all do — an IP
allowlist cannot distinguish two sites sharing a CDN address. Because the proxy
resolves on the guest's behalf, boxes in this mode are given no DNS route,
which removes DNS tunnelling as an exfiltration channel rather than monitoring
for it. Every decision is written to a JSONL audit log:

```sh
agentbox create myproj --net bridge --egress proxy --workspace ~/code/myproj
agentbox egress-log myproj        # what it reached, and what was refused
```

### Routing a box through a VPN

`--vpn IFACE` pins a box's egress to one interface with a fail-closed kill
switch: the accept rule is bound to that interface, so if the tunnel drops the
packet falls through to a drop rather than leaking to the default route.

```sh
agentbox create myproj --net bridge --vpn wg-agent --workspace ~/code/myproj
```

```sh
agentbox net up
agentbox create myproj --net bridge --egress allow --workspace ~/code/myproj
agentbox allow myproj registry.npmjs.org files.pythonhosted.org
```

`etc/egress-allow.txt` seeds every new box with the Anthropic, npm, PyPI, GitHub
and Ubuntu endpoints. Per-ecosystem bundles live in `etc/allow.d/` and compose
on top:

```sh
agentbox allow --list                      # python, node, rust, go, github
agentbox create myproj --allow rust --allow github --egress proxy
agentbox allow myproj --bundle python
```

Bundles are the easiest thing to contribute and the most likely to be wrong for
a stack we do not use — see [CONTRIBUTING.md](CONTRIBUTING.md). Under any policy, a box can never reach another box, your
LAN, or a service on the host other than the bridge's DNS resolver.

The allowlist matches resolved IP addresses, which means a domain sharing a CDN
address with an allowed one is reachable too. It stops an agent from wandering;
it is not a hard barrier against a determined exfiltration attempt. If you need
that, use `--egress none` and hand the box what it needs through `~/workspace`.

## Credentials

**By default (`--creds none`) a box receives no credentials**, so it starts
logged out and an agent in it has no token to act with. Log in inside the box, or
push a token in deliberately:

```sh
agentbox creds myproj status      # what this box holds, and how long it is valid
agentbox creds myproj push        # copy the current host token in
agentbox creds myproj clear       # revoke from one box
agentbox create myproj --creds share   # opt in to logged-in-on-boot
```

If the friction of logging in per box is not worth it, `--creds share` copies
your host Claude OAuth token into the box so agents are logged in the moment it
boots. Be clear about what it costs. A box holding your token can act as you.
Isolation bounds what an agent can *reach*; it does nothing about what it can *do
with a credential you handed it*, and a successful prompt injection inside the
box can use it.

What is copied is kept to the minimum that keeps you logged in — the token itself
and your git identity. `~/.claude.json` is deliberately **not** copied: it is tens
of kilobytes of config and per-project history describing every other project you
work on, and none of it is needed to stay authenticated. Transfer happens over the
box's SSH channel after boot, never through the cloud-init seed, which is an
unencrypted file on disk.

### Why a shared box eventually asks you to log in

This only applies to boxes created with `--creds share`. OAuth refresh tokens
**rotate when they are used**. Once the Claude on your host refreshes its token,
the copy inside the box is stale: its access token expires and it cannot renew,
so it prompts for login. This is inherent to two clients sharing one OAuth
credential, not something agentbox can paper over.

`agentbox creds <box> push` fixes it for another few hours, and `agentbox up`
re-pushes the current token automatically. For a box you keep running, the durable
answer is a credential that is not shared with your interactive session:

```sh
claude setup-token                              # a long-lived token, on the host
agentbox ssh myproj -- 'echo export ANTHROPIC_API_KEY=... >> ~/.bashrc'
```

`agentbox creds <box> status` shows the remaining validity, so you can tell this
apart from an actual authentication problem.

Set `AGENTBOX_CREDS=share` in `~/.agentbox/agentbox.conf` to make token-sharing
your default. For GitHub, prefer a deploy key or a fine-grained PAT scoped to the
one repository over your personal token.

## Everyday commands

```sh
agentbox ls                       # every box, state, address, workspace
agentbox status myproj            # config, versions, disk usage
agentbox logs myproj -f           # serial console log, for boots that go wrong
agentbox console myproj           # attach to the console; works when ssh does not
agentbox netdiag myproj           # why the network is not working, host and guest
agentbox agent myproj             # run claude in ~/workspace, attached
agentbox down myproj              # graceful shutdown
agentbox reset myproj             # wipe the VM disk, keep the workspace
agentbox reseed myproj            # rebuild the cloud-init seed after editing box.conf
agentbox destroy myproj           # remove the box (asks before touching a workspace)
```

Running an agent unattended is the point of all this:

```sh
agentbox ssh myproj -- 'cd ~/workspace && claude --dangerously-skip-permissions -p "run the test suite and fix what fails"'
```

## Changing the base image

Provisioning is ordered shell in `image/layers/`, not a bespoke DSL — there is a
note in `lib/image.sh` explaining why, and pointers to Packer, mkosi, bootc and
`virt-customize` if you outgrow it. Incremental edits do not need a full rebuild:

```sh
agentbox image install postgresql-client-16   # apply to the base, re-seal
agentbox image run image/layers/20-rust.sh
agentbox image history                        # what has been applied
agentbox image rollback                       # undo the last change
```

Edits use `virt-customize` when libguestfs is installed (no boot), and otherwise
a maintenance boot. The previous base image is kept so `rollback` always has
somewhere to go. Existing boxes keep the image they were created from until
`agentbox reset <box>`.

## Tests

```sh
test/net-rules.sh      # offline: 28 assertions on the generated nftables policy
test/egress-proxy.sh   # 14 checks on domain filtering, incl. suffix confusion
test/smoke.sh          # end-to-end: boots a real box, 21 checks, ~2 min
```

One more needs root and a live bridge, because it puts real packets through the
kernel's copy of the policy rather than asserting on generated text:

```sh
sudo -v && agentbox net up && test/bridge-live.sh
```

Any change to `lib/net.sh`, `lib/egress.sh` or `bin/agentbox-egress-proxy` needs
a test — those three files are the security boundary.

`net-rules.sh` stubs `sudo`/`ip`/`getent` and renders the ruleset to stdout instead
of loading it, so it verifies the security-relevant rules — no box-to-box traffic,
no LAN, no host services, correct accept-before-drop ordering, and the cached-IP
fallback when DNS is down — without touching the host network.

## Layout

```
bin/agentbox            the CLI
lib/common.sh           config, box state, ssh plumbing
lib/net.sh              bridge, taps, nftables policy (the only sudo path)
lib/egress.sh           egress proxy lifecycle, VPN routing, kill switch
lib/image.sh            base-image edits, history, rollback
lib/creds.sh            what a box is given, and what is withheld
bin/agentbox-egress-proxy  domain-filtering CONNECT proxy with an audit log
image/provision.sh      runs once inside the build VM; defines the base image
image/CLAUDE.md         guest ~/.claude/CLAUDE.md — the agent's briefing
etc/agentbox.conf       host defaults (copy to ~/.agentbox/agentbox.conf to override)
etc/egress-allow.txt    default allowlist for new boxes
test/                   smoke.sh (end-to-end) and net-rules.sh (offline policy)
```

State lives in `~/.agentbox`: `images/base.qcow2` (shared, read-only),
`boxes/<name>/` (qcow2 overlay, SSH key, cloud-init seed, allowlist), and
`ssh_config`.

## Documentation

| | |
| --- | --- |
| [docs/DESIGN.md](docs/DESIGN.md) | Why it is built this way; QEMU vs Firecracker vs containers |
| [docs/NETWORKING.md](docs/NETWORKING.md) | The two modes, the nftables chains, what you control, troubleshooting |
| [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md) | What is defended, what is not, and the known holes |
| [SECURITY.md](SECURITY.md) | How to report something exploitable |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Tests, extension points, code style |

## Licence

Apache-2.0. See [LICENSE](LICENSE).
