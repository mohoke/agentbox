---
name: Environment or bundle contribution
about: A new image layer or egress bundle, or a correction to one
title: "[env] "
labels: enhancement, environment
---

## What stack is this for?

## Type

- [ ] Image layer (`image/layers/*.sh`) — tools in the base image
- [ ] Egress bundle (`etc/allow.d/*.txt`) — hostnames a stack needs
- [ ] A correction to an existing one

## For an egress bundle: how did you determine the host list?

<!--
The best answer is empirical: run a box with `--egress proxy`, do real work, and
read `agentbox egress-log <box>` for the refused hosts. Please keep the list to
what the toolchain actually needs -- a short allowlist is the entire point.
-->

## What you verified

<!-- e.g. "created a box with --allow rust, cargo build succeeded on <project>" -->
