---
name: Security review finding (non-exploitable)
about: A weakness in the security model that is not directly exploitable. Anything exploitable goes through private disclosure instead.
title: "[review] "
labels: security, review
---

<!--
If this is EXPLOITABLE -- you can escape the egress policy, reach the host from
a guest, or extract credentials -- close this and use private reporting:
Security -> Report a vulnerability. See SECURITY.md.

This template is for design-level findings: an assumption that does not hold, a
control that is weaker than documented, a gap in the threat model.
-->

## Which claim or section does this concern?

<!-- e.g. "claim C5 in docs/THREAT-MODEL.md §4", or "§5.5, TLS is not inspected" -->

## What the documentation says

## What you found instead

## Why it matters

<!-- What does an attacker gain? Be concrete about the capability, not the severity label. -->

## Suggested direction, if you have one

<!-- Optional. A description of the fix is as welcome as a patch. -->

## Environment

- commit:
- host OS / kernel:
- qemu version:
- egress mode (`open` / `allow` / `proxy` / `none`):
