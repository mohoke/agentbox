# Egress bundles

One file per ecosystem, one hostname per line, `#` for comments. Applied to a
box's `allow.txt` with:

    agentbox allow <box> --bundle rust
    agentbox create <box> --allow rust --allow github

Keep them short. The value of an allowlist is what it leaves out. To find what a
stack actually needs, run a box with `--egress proxy`, do the work, then read
`agentbox egress-log <box>` — refused hosts are listed explicitly.

`../egress-allow.txt` is the default seed applied to every new box.
