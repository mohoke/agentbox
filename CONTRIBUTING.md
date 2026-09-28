# Contributing

This project is published to be reviewed and extended, not to accumulate stars.
The most valuable contributions, in order:

1. **Breaking a security claim.** See [SECURITY.md](SECURITY.md) and §4 of the
   [threat model](docs/THREAT-MODEL.md). If you falsify one of C1–C10, that is
   the best thing you can send us.
2. **Hardening a known weakness.** §6 and §8 of the threat model list what we
   already know is wrong. Those are open for anyone.
3. **Environments.** A layer for a stack we do not cover, or an egress bundle for
   an ecosystem we got wrong. These are designed to be easy — see below.
4. **Portability.** Other distributions, other host setups, other agents.

## Getting set up

```sh
git clone <repo> && cd agentbox
./bin/agentbox doctor          # tells you what is missing
./bin/agentbox build           # ~15 min, once
```

On Debian/Ubuntu the prerequisites are:

```sh
sudo apt install qemu-system-x86 qemu-utils virtiofsd xorriso jq nftables dnsmasq
sudo usermod -aG kvm "$USER"   # log out and back in
```

## Running the tests

Three suites, two of which need nothing special:

```sh
./test/net-rules.sh      # 25 assertions on the generated nftables policy, offline
./test/egress-proxy.sh   # 14 checks on domain filtering, loopback only
./test/smoke.sh          # boots a real VM, 21 checks, ~2 min (needs KVM)
```

A fourth needs root and a live bridge, because it puts real packets through the
kernel's copy of the policy:

```sh
sudo -v && ./bin/agentbox net up && ./test/bridge-live.sh
```

**Any change to `lib/net.sh`, `lib/egress.sh` or `bin/agentbox-egress-proxy`
must come with a test.** Those three files are the security boundary; a change
there without a corresponding assertion will be asked for one.

## Extending it

The extension points exist so that adding an environment does not mean forking.

### Image layers — adding tools to the base image

Drop a shell script in `image/layers/`. It runs inside the build VM after the
base provisioning, in filename order, and is baked into the sealed image.

```sh
# image/layers/20-rust.sh
#!/bin/bash
# Rust toolchain via rustup.
set -euo pipefail
su - agent -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
ln -sf /home/agent/.cargo/bin/cargo /usr/local/bin/cargo
```

Rules: start with `set -euo pipefail` so a failure fails the build rather than
sealing a broken image; be idempotent, so the layer can be replayed with
`agentbox image run`; put a one-line `#` comment on line 2, which
`agentbox image layers` displays; and keep secrets out — the layer ends up in
every box built from the image.

To apply one to an existing base image without a full rebuild:

```sh
agentbox image run image/layers/20-rust.sh
```

### Egress bundles — allowlists for an ecosystem

Domain allowlists live in `etc/allow.d/`. One file per ecosystem, one host per
line. These are the easiest contribution in the project and the one most likely
to be wrong for a stack we do not use.

```
# etc/allow.d/rust.txt
static.rust-lang.org
crates.io
static.crates.io
index.crates.io
```

Then `agentbox allow <box> --bundle rust`, or `--allow rust` at create time.

When adding a bundle, list only what the toolchain actually needs — the point of
an allowlist is that it is short. If you are unsure, run a box with
`--egress proxy`, do the work, and read `agentbox egress-log <box>`: it tells you
exactly which hosts were refused.

### What we would rather not take

This is deliberately a small, opinionated tool. Proposals that abstract the
hypervisor, add an orchestration layer, introduce a configuration DSL, or make
the workspace model pluggable will probably be declined — not because they are
bad ideas, but because each one trades away the simplicity that makes the
security properties reviewable. If you want one of those, say what problem it
solves first and we will look for a smaller fix.

Image provisioning is plain shell on purpose. Packer, mkosi, bootc and
`virt-customize` all already solve declarative image building better than we
could; `lib/image.sh` documents when to graduate to them.

## Code style

It is bash. Some house rules that exist because breaking them caused real bugs
here:

- `set -euo pipefail` in every script.
- Declare each `local` separately when one references another. Bash expands all
  arguments to `local` before running it, so `local a=$1 b="$a/x"` leaves `b`
  wrong — and under `set -u` it aborts the function mid-way. This shipped once
  and silently emptied a firewall allowlist.
- Do not inline loops into cloud-init `runcmd`. Quoting through
  bash → YAML → shell will corrupt them. Write a script file and call it; see
  `image/run-layers.sh`.
- Comments explain *why*, not *what*. If a line looks odd but is deliberate, say
  what goes wrong without it.
- `bash -n` every file you touch. `shellcheck` if you have it.

## Pull requests

Small and focused. Explain what you changed and what you ran to verify it —
actual output, not an assertion that it works. If you touched the security
boundary, say which test covers the change.

Please do not include generated artifacts: `~/.agentbox` state, built images, or
`research/build/vendor/`.

## Code of conduct

[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Briefly: be decent, assume competence,
argue about the code.
