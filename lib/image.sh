# shellcheck shell=bash
# Base-image lifecycle: layered provisioning, incremental edits, and rollback.
#
# Design note -- why there is no Boxfile DSL here.
# Packer, mkosi, bootc-image-builder and virt-customize all already solve
# "describe a VM image declaratively", and each is better at it than anything
# this project could maintain. Inventing a Dockerfile-alike would mean owning a
# parser, cache semantics and error reporting for no gain. So provisioning is
# just ordered shell in image/layers/, which every developer already reads, and
# incremental edits go through the two mechanisms below:
#
#   fast path  -- virt-customize (libguestfs), edits the qcow2 without booting
#   portable   -- a maintenance boot: run the change in a throwaway VM, re-seal
#
# The fast path is used automatically when libguestfs is installed.

have_virt_customize() { command -v virt-customize >/dev/null 2>&1; }

image_history_file() { printf '%s' "$IMAGES_DIR/history.json"; }

image_record() {
  # image_record <action> <detail>  -- append to the image's provenance log.
  local action=$1 detail=$2 hist; hist=$(image_history_file)
  [[ -f $hist ]] || echo '[]' > "$hist"
  local tmp; tmp=$(mktemp)
  jq --arg a "$action" --arg d "$detail" --arg t "$(date -Is)" \
     --arg s "$(stat -c %s "$BASE_IMAGE" 2>/dev/null || echo 0)" \
     '. += [{when:$t, action:$a, detail:$d, bytes:($s|tonumber)}]' \
     "$hist" > "$tmp" && mv "$tmp" "$hist"
}

image_keep_backup() {
  # Rotate the current base aside so `image rollback` has somewhere to go.
  local n=1
  while [[ -f $IMAGES_DIR/base.prev$n.qcow2 ]]; do n=$((n+1)); done
  (( n > 3 )) && { rm -f "$IMAGES_DIR/base.prev1.qcow2"
                   local i
                   for i in 2 3; do
                     [[ -f $IMAGES_DIR/base.prev$i.qcow2 ]] && \
                       mv "$IMAGES_DIR/base.prev$i.qcow2" "$IMAGES_DIR/base.prev$((i-1)).qcow2"
                   done
                   n=3; }
  cp --reflink=auto "$BASE_IMAGE" "$IMAGES_DIR/base.prev$n.qcow2"
  printf '%s' "$IMAGES_DIR/base.prev$n.qcow2"
}

image_boxes_on_old_base() {
  # Existing overlays keep pointing at the file they were created from, so a
  # reseal does not disturb running boxes -- but they will not see the change
  # until they are reset. Report which ones.
  local n out=()
  for n in $(list_boxes); do out+=("$n"); done
  printf '%s\n' "${out[@]-}"
}

# ------------------------------------------------------- maintenance boot ---
image_maintenance() {
  # image_maintenance <label> <script-text>
  # Applies a change to the sealed base image and re-seals it.
  local label=$1 script=$2
  [[ -f $BASE_IMAGE ]] || die "no base image -- run: agentbox build"

  local n
  for n in $(list_boxes); do
    box_running "$(box_dir "$n")" && \
      die "box '$n' is running; stop all boxes before editing the base image"
  done

  local backup; backup=$(image_keep_backup)
  dim "previous base kept at $(basename "$backup")"

  if have_virt_customize; then
    image_apply_virt "$label" "$script"
  else
    image_apply_boot "$label" "$script"
  fi

  chmod 444 "$BASE_IMAGE"
  image_record "$label" "$(head -c 200 <<<"$script" | tr '\n' ' ')"
  ok "base image updated ($(du -h "$BASE_IMAGE" | cut -f1))"
  dim "existing boxes keep the old image until: agentbox reset <box>"
}

image_apply_virt() {
  local label=$1 script=$2
  log "applying '$label' with virt-customize (no boot needed)"
  local sf; sf=$(mktemp); printf '%s\n' "$script" > "$sf"
  chmod 644 "$BASE_IMAGE"
  virt-customize -a "$BASE_IMAGE" --run "$sf" \
    || { rm -f "$sf"; die "virt-customize failed"; }
  rm -f "$sf"
}

image_apply_boot() {
  local label=$1 script=$2
  local work="$IMAGES_DIR/maint.qcow2" console="$IMAGES_DIR/maint-console.log"
  rm -f "$work" "$console"

  log "applying '$label' via maintenance boot (install libguestfs-tools to skip this)"
  qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$work" >/dev/null

  local full; full=$(cat <<EOF
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
$script
apt-get clean 2>/dev/null || true
rm -rf /var/lib/apt/lists/*
cloud-init clean --logs --seed 2>/dev/null || true
rm -f /etc/ssh/ssh_host_*
fstrim -av 2>/dev/null || true
sync
EOF
)
  local ud; ud=$(mktemp)
  {
    echo "#cloud-config"
    echo "write_files:"
    echo "  - path: /root/maint.sh"
    echo "    permissions: '0755'"
    echo "    encoding: b64"
    echo "    content: $(base64 -w0 <<<"$full")"
    echo "runcmd:"
    echo "  - [ bash, -lc, \"/root/maint.sh && echo AGENTBOX_MAINT_OK > /dev/console || echo AGENTBOX_MAINT_FAIL > /dev/console\" ]"
    echo "  - [ bash, -lc, \"rm -f /root/maint.sh; sync; poweroff\" ]"
  } > "$ud"
  SEED_HOSTNAME=agentbox-maint make_seed_iso "$IMAGES_DIR/maint-seed.iso" "$ud"
  rm -f "$ud"

  qemu-system-x86_64 \
    -name agentbox-maint -machine q35,accel=kvm -cpu host -smp 4 -m 4096 \
    -drive "file=$work,if=virtio,format=qcow2,discard=unmap,cache=writeback" \
    -drive "file=$IMAGES_DIR/maint-seed.iso,if=virtio,format=raw,readonly=on" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -serial "file:$console" -display none -no-reboot \
    || die "maintenance VM failed to run (see $console)"

  grep -q AGENTBOX_MAINT_OK "$console" \
    || die "change did not apply cleanly -- inspect $console (base image untouched)"

  log "re-sealing"
  qemu-img convert -O qcow2 "$work" "$BASE_IMAGE.tmp"
  rm -f "$BASE_IMAGE"
  mv "$BASE_IMAGE.tmp" "$BASE_IMAGE"
  rm -f "$work" "$IMAGES_DIR/maint-seed.iso"
}

# ------------------------------------------------------------- subcommands --
cmd_image() {
  local sub=${1:-list}; shift || true
  case $sub in
    list|status)   image_cmd_list ;;
    install)       [[ $# -gt 0 ]] || die "usage: agentbox image install <pkg>..."
                   image_maintenance "install: $*" \
                     "apt-get update && apt-get -y install --no-install-recommends $*" ;;
    remove)        [[ $# -gt 0 ]] || die "usage: agentbox image remove <pkg>..."
                   image_maintenance "remove: $*" \
                     "apt-get -y purge $* && apt-get -y autoremove --purge" ;;
    run)           [[ -f ${1-} ]] || die "usage: agentbox image run <script.sh>"
                   image_maintenance "run: $(basename "$1")" "$(cat "$1")" ;;
    exec)          [[ $# -gt 0 ]] || die "usage: agentbox image exec <shell command>"
                   image_maintenance "exec" "$*" ;;
    history)       image_cmd_history ;;
    rollback)      image_cmd_rollback "${1-}" ;;
    layers)        image_cmd_layers ;;
    *) die "usage: agentbox image {list|install|remove|run|exec|history|rollback|layers}" ;;
  esac
}

image_cmd_list() {
  [[ -f $BASE_IMAGE ]] || { warn "no base image -- run: agentbox build"; return 0; }
  printf 'base   %s  %s\n' "$(du -h "$BASE_IMAGE" | cut -f1)" "$BASE_IMAGE"
  [[ -f $BASE_MANIFEST ]] && jq -r '"built  \(.built)  ubuntu \(.release), node \(.node)"' "$BASE_MANIFEST"
  local f
  for f in "$IMAGES_DIR"/base.prev*.qcow2; do
    [[ -f $f ]] && printf 'backup %s  %s\n' "$(du -h "$f" | cut -f1)" "$(basename "$f")"
  done
  local hist; hist=$(image_history_file)
  [[ -f $hist ]] && printf 'edits  %s recorded (agentbox image history)\n' "$(jq 'length' "$hist")"
  printf 'method %s\n' "$(have_virt_customize && echo 'virt-customize (fast)' || echo 'maintenance boot (install libguestfs-tools for the fast path)')"
}

image_cmd_history() {
  local hist; hist=$(image_history_file)
  [[ -f $hist ]] || { warn "no edits recorded yet"; return 0; }
  jq -r '.[] | "\(.when[:19])  \(.action)"' "$hist"
}

image_cmd_rollback() {
  local which=${1-}
  local latest=""
  local n
  for n in 3 2 1; do
    [[ -f $IMAGES_DIR/base.prev$n.qcow2 ]] && { latest="$IMAGES_DIR/base.prev$n.qcow2"; break; }
  done
  [[ -n $which ]] && latest="$IMAGES_DIR/base.prev$which.qcow2"
  [[ -f $latest ]] || die "no backup to roll back to (agentbox image list)"

  for n in $(list_boxes); do
    box_running "$(box_dir "$n")" && die "box '$n' is running; stop it first"
  done
  printf 'Roll the base image back to %s?\n' "$(basename "$latest")" >&2
  read -r -p "Type yes to confirm: " reply; [[ $reply == yes ]] || die "aborted"

  rm -f "$BASE_IMAGE"
  mv "$latest" "$BASE_IMAGE"
  chmod 444 "$BASE_IMAGE"
  image_record "rollback" "$(basename "$latest")"
  ok "rolled back -- existing boxes need: agentbox reset <box>"
}

image_cmd_layers() {
  local dir="$AGENTBOX_ROOT/image/layers"
  [[ -d $dir ]] || { warn "no layers directory at $dir"; return 0; }
  printf 'layers applied during `agentbox build`, in order:\n'
  local f
  for f in "$dir"/*.sh; do
    [[ -f $f ]] || continue
    printf '  %-28s %s\n' "$(basename "$f")" \
      "$(sed -n '2s/^# *//p' "$f" | head -c 60)"
  done
}
