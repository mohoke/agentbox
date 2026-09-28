# shellcheck shell=bash
# Shared helpers for the agentbox CLI. Sourced, never executed.

set -euo pipefail

AGENTBOX_ROOT="${AGENTBOX_ROOT:?must be set by bin/agentbox}"
AGENTBOX_HOME="${AGENTBOX_HOME:-$HOME/.agentbox}"

IMAGES_DIR="$AGENTBOX_HOME/images"
BOXES_DIR="$AGENTBOX_HOME/boxes"
CACHE_DIR="$AGENTBOX_HOME/cache"
BASE_IMAGE="$IMAGES_DIR/base.qcow2"
BASE_MANIFEST="$IMAGES_DIR/base.json"
SSH_CONFIG="$AGENTBOX_HOME/ssh_config"
VIRTIOFSD="${VIRTIOFSD:-/usr/libexec/virtiofsd}"

# ---------------------------------------------------------------- output ----
if [[ -t 2 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=; C_OFF=
fi

log()  { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*" >&2; }
ok()   { printf '%s ok %s %s\n' "$C_GRN" "$C_OFF" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF" >&2; }

# ---------------------------------------------------------------- config ----
load_config() {
  # Defaults ship with the repo; the user's copy in $AGENTBOX_HOME wins.
  # shellcheck disable=SC1090,SC1091
  source "$AGENTBOX_ROOT/etc/agentbox.conf"
  [[ -f "$AGENTBOX_HOME/agentbox.conf" ]] && source "$AGENTBOX_HOME/agentbox.conf"
  mkdir -p "$IMAGES_DIR" "$BOXES_DIR" "$CACHE_DIR"
}

box_dir()  { printf '%s/%s' "$BOXES_DIR" "$1"; }
box_conf() { printf '%s/%s/box.conf' "$BOXES_DIR" "$1"; }

require_box() {
  [[ -n "${1:-}" ]] || die "missing box name"
  [[ -d "$(box_dir "$1")" ]] || die "no such box: $1  (agentbox ls)"
}

# Load a box's config into BOX_* variables.
load_box() {
  require_box "$1"
  BOX_NAME=$1
  BOX_DIR=$(box_dir "$1")
  # shellcheck disable=SC1090
  source "$(box_conf "$1")"
}

list_boxes() {
  [[ -d "$BOXES_DIR" ]] || return 0
  find "$BOXES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

# ------------------------------------------------------------- lifecycle ----
box_pid() {
  local pf="$1/run/qemu.pid"
  [[ -s "$pf" ]] || return 1
  local pid; pid=$(<"$pf")
  # Guard against PID reuse: the process must still be our qemu.
  [[ -n "$pid" && -d "/proc/$pid" ]] || return 1
  grep -qa 'qemu-system' "/proc/$pid/cmdline" 2>/dev/null || return 1
  printf '%s' "$pid"
}

box_running() { box_pid "$1" >/dev/null 2>&1; }

# First free index, used to derive MAC / IP / ssh port deterministically.
alloc_index() {
  local used=() n
  for n in $(list_boxes); do
    local i; i=$(sed -n 's/^BOX_INDEX=//p' "$(box_conf "$n")" 2>/dev/null)
    [[ -n "$i" ]] && used+=("$i")
  done
  local c
  for c in $(seq 2 250); do
    [[ " ${used[*]-} " == *" $c "* ]] || { printf '%s' "$c"; return; }
  done
  die "no free box index (max 249 boxes)"
}

qmp() {
  # qmp <box_dir> <command-json>  -- one-shot QMP request over the unix socket.
  local sock="$1/run/qmp.sock" cmd="$2"
  [[ -S "$sock" ]] || return 1
  python3 - "$sock" "$cmd" <<'PY'
import json, socket, sys
sock, cmd = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sock)
f = s.makefile('rw')
f.readline()                                  # greeting
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
f.write(cmd + "\n"); f.flush()
print(f.readline().strip())
PY
}

ssh_opts() {
  # Host keys change whenever a box is rebuilt; keep them out of known_hosts.
  printf '%s' "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
}

wait_for_ssh() {
  # wait_for_ssh <box_dir> <timeout_s>
  local bd=$1 timeout=${2:-180} t=0
  while (( t < timeout )); do
    box_running "$bd" || { warn "qemu exited; see: agentbox logs $BOX_NAME"; return 1; }
    # shellcheck disable=SC2086
    if ssh -F "$SSH_CONFIG" $(ssh_opts) -o ConnectTimeout=3 \
         -o BatchMode=yes "$BOX_NAME" true 2>/dev/null; then
      return 0
    fi
    sleep 2; t=$((t+2))
  done

  # A bare timeout tells the user nothing. Say which layer failed.
  warn "no ssh from '$BOX_NAME' after ${timeout}s -- diagnosing"
  if ! box_running "$bd"; then
    dim "    qemu is not running; the guest died. Last console output:"
    tail -n 15 "$bd/run/console.log" 2>/dev/null | sed 's/^/      /' >&2
    return 1
  fi
  dim "    qemu is alive (pid $(box_pid "$bd"))"
  # shellcheck disable=SC1090
  ( source "$(box_conf "$BOX_NAME")"
    if [[ $BOX_NET == bridge ]]; then
      if ping -c1 -W2 "$BOX_IP" >/dev/null 2>&1; then
        dim "    $BOX_IP answers ping, so the guest booted and configured its network"
        dim "    -> sshd is not up, or the nftables policy is dropping the reply"
      else
        dim "    $BOX_IP does not answer ping"
        dim "    -> the guest has not applied its static address (cloud-init), or the"
        dim "       tap is not attached to $AGENTBOX_BRIDGE"
        ip -br link show "ag$BOX_INDEX" 2>/dev/null | sed 's/^/      tap: /' >&2 \
          || dim "      tap ag$BOX_INDEX does not exist"
      fi
    else
      dim "    slirp mode; check that 127.0.0.1:$BOX_SSH_PORT is listening"
    fi )
  dim "    full console: agentbox logs $BOX_NAME"
  tail -n 8 "$bd/run/console.log" 2>/dev/null | sed 's/^/      /' >&2
  return 1
}

regen_ssh_config() {
  # One ssh_config for every box, so `ssh <box>` and VS Code Remote-SSH agree.
  local tmp; tmp=$(mktemp)
  {
    echo "# Generated by agentbox -- do not edit; regenerated on create/destroy."
    echo "# Add 'Include $SSH_CONFIG' to the top of ~/.ssh/config to use these names."
    echo
    local n
    for n in $(list_boxes); do
      # shellcheck disable=SC1090
      ( source "$(box_conf "$n")"
        echo "Host $n"
        if [[ $BOX_NET == slirp ]]; then
          echo "    HostName 127.0.0.1"
          echo "    Port $BOX_SSH_PORT"
        else
          echo "    HostName $BOX_IP"
          echo "    Port 22"
        fi
        echo "    User agent"
        echo "    IdentityFile $BOXES_DIR/$n/id_ed25519"
        echo "    IdentitiesOnly yes"
        echo "    StrictHostKeyChecking no"
        echo "    UserKnownHostsFile /dev/null"
        echo "    LogLevel ERROR"
        echo )
    done
  } >"$tmp"
  mv "$tmp" "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"
}
