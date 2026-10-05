# Security policy

agentbox is a security tool in **alpha**. It has had no external security review.
Treat its guarantees as unproven until someone other than the authors has tried
to break them.

## Before anything else: read the threat model

[`docs/THREAT-MODEL.md`](docs/THREAT-MODEL.md) states what agentbox claims to
defend, what it explicitly does not, and a list of weaknesses the authors
already believe exist. It also has a section of open questions we would most
like answered.

The two limits that catch people out:

- **A box you gave credentials can act as you.** Isolation bounds what an agent
  can reach, not what it can do with a token you deliberately handed it. The
  default (`--creds none`) copies nothing in.
- **Code the agent writes runs outside the VM**, on your host, with your
  privileges, the moment you execute it. Review diffs.

## Reporting a vulnerability

**Please do not open a public issue for anything exploitable.**

Use GitHub's private vulnerability reporting: **Security → Report a
vulnerability** on the repository. If that is unavailable, open a public issue
containing only the words "security report, requesting private contact" and
nothing else, and a maintainer will follow up.

Useful reports include:

- which claim in the threat model (C1–C10) is falsified, or which section of §5
  turns out to be worse than stated;
- the version or commit tested, and the host OS and QEMU version;
- a minimal reproduction — configuration plus commands;
- what you got, versus what the documentation says should happen.

You do not need a working weaponised exploit. A clear argument that an invariant
does not hold is enough.

### What to expect

This is a volunteer project with no SLA, so these are intentions, not promises:

| | |
| --- | --- |
| Acknowledgement | within 7 days |
| Initial assessment | within 14 days |
| Fix or public documentation | depends on severity and complexity |
| Credit | offered by default; tell us if you would rather not be named |

We would rather document an unfixable weakness honestly than leave it implied
that it does not exist. If a reported issue cannot be fixed, it goes into the
threat model.

## Scope

**In scope:** anything that falsifies a claim in §4 of the threat model — escaping
the egress policy, reaching the host or LAN from a guest, box-to-box traffic,
filesystem access beyond the shared workspace, credential leakage through the
seed ISO or on-disk state, or privilege escalation via the `sudo` paths in
`lib/net.sh` and `lib/egress.sh`.

**Out of scope**, because the threat model already excludes them:

- QEMU/KVM hypervisor escapes — report those to the QEMU and kernel projects.
- Anything requiring an attacker who already has a shell on the host as you.
- The agent doing damage inside its own workspace or with credentials you gave
  it. That is the documented design.
- The `curl | bash` installers used during image build. Known and documented in
  §5.8; a better design is welcome as a pull request rather than a report.

## Supported versions

Alpha. Only the current `main` is supported. There are no backports.

## A standing invitation

The reason this project is public is to be reviewed. If you are a security
researcher looking at agent isolation, the sharpest surfaces are:

1. `bin/agentbox-egress-proxy` — hand-written HTTP parsing on a trust boundary.
2. `lib/net.sh` — the generated nftables ruleset, especially rule ordering and
   the regeneration window.
3. `bin/agentbox` `build_seed()` — what goes into the guest's cloud-init.
4. The virtio-fs configuration in `cmd_up` — `--sandbox none` and what bounds it.

Findings that make us rewrite one of these are the most useful contribution the
project can receive.
