#!/bin/bash
# Runs image/layers/*.sh inside the build VM, in filename order.
# Kept as a real file rather than an inline cloud-init command: quoting a loop
# through bash -> YAML -> shell is a reliable way to corrupt it.
set -uo pipefail
shopt -s nullglob

status=0
for layer in /root/layers/*.sh; do
  echo "### agentbox layer: $(basename "$layer")"
  if ! bash "$layer"; then
    echo "### layer FAILED: $(basename "$layer")"
    status=1
    break
  fi
done

if [[ $status -eq 0 ]]; then
  echo AGENTBOX_LAYERS_OK > /dev/console
else
  echo AGENTBOX_LAYER_FAIL > /dev/console
fi
exit $status
