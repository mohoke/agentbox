# Image layers

Shell scripts here run inside the build VM after `image/provision.sh`, in
filename order, and their output is baked into the sealed base image. This is
the declarative-enough middle ground: ordered shell that any developer can read,
with no DSL to learn and no parser to maintain.

    10-python-extras.sh
    20-company-ca.sh
    30-dotfiles.sh

Rules that make layers behave:

- Start with `set -euo pipefail`. A layer that fails fails the whole build
  rather than sealing a half-provisioned image.
- Make them idempotent. `agentbox image run` can replay one against an
  existing base image without a full rebuild.
- Put a one-line `# comment` on line 2; `agentbox image layers` shows it.
- Keep secrets out. This file ends up in every box built from the image.

To add a package without editing anything:

    agentbox image install postgresql-client-16

To apply a layer to the current base image without a full rebuild:

    agentbox image run image/layers/10-python-extras.sh
