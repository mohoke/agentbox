#!/usr/bin/env bash
# End-to-end check: creates a throwaway box, boots it, and verifies that the
# environment a coding agent actually depends on is present and working.
# Usage: test/smoke.sh [--keep]
set -euo pipefail

AB=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/bin/agentbox
BOX=smoketest-$$
WS=$(mktemp -d)
KEEP=0
[[ ${1-} == --keep ]] && KEEP=1

pass=0; fail=0
check() { # check <label> <command...>
  local label=$1; shift
  if out=$("$@" 2>&1); then
    printf '  \033[32mok\033[0m   %-32s %s\n' "$label" "$(head -1 <<<"$out")"
    pass=$((pass+1))
  else
    printf '  \033[31mFAIL\033[0m %-32s %s\n' "$label" "$(head -3 <<<"$out")"
    fail=$((fail+1))
  fi
}
in_box() { "$AB" ssh "$BOX" -- "$@"; }

cleanup() {
  if (( KEEP )); then
    echo "keeping box $BOX (workspace $WS)" >&2
  else
    "$AB" down "$BOX" >/dev/null 2>&1 || true
    rm -rf "$HOME/.agentbox/boxes/$BOX" "$WS"
    "$AB" ssh-config >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "# creating $BOX (workspace $WS)"
echo "hello from the host" > "$WS/host-file.txt"
"$AB" create "$BOX" --workspace "$WS" --cpus 2 --mem 2048 >/dev/null
"$AB" up "$BOX"

echo "# guest environment"
check "python3"        in_box 'python3 --version'
check "python venv"    in_box 'cd /tmp && python3 -m venv v && v/bin/pip --version && rm -rf v'
check "uv"             in_box 'uv --version'
check "node"           in_box 'node --version'
check "claude"         in_box 'claude --version'
check "opencode"       in_box 'opencode --version'
check "git"            in_box 'git --version'
check "ripgrep"        in_box 'rg --version | head -1'
check "build-essential" in_box 'gcc --version | head -1'
check "postgres up"    in_box 'psql -tAc "select version()" | cut -c1-30'
check "postgres write" in_box 'createdb smoke_$$ && psql -d smoke_$$ -tAc "create table t(x int); insert into t values (1); select count(*) from t" && dropdb smoke_$$'
check "passwordless sudo" in_box 'sudo -n id -u'

echo "# agent briefing"
check "~/.claude/CLAUDE.md" in_box 'head -1 ~/.claude/CLAUDE.md'
check "box-info"            in_box 'box-info | head -1'

echo "# shared workspace (virtio-fs)"
check "host file visible"  in_box 'cat ~/workspace/host-file.txt'
check "guest write"        in_box 'echo "hello from the guest" > ~/workspace/guest-file.txt'
check "guest write lands on host" cat "$WS/guest-file.txt"
check "ownership matches"  in_box 'test "$(stat -c %U ~/workspace/host-file.txt)" = agent'
check "scratch is vm-local" in_box 'touch ~/scratch/x && test ! -e '"$WS"'/x'

echo "# isolation"
check "host home not visible" in_box "test ! -e ~/workspace/../../../home/$USER/.ssh"
check "no host ssh port"      in_box 'timeout 3 bash -c "</dev/tcp/10.0.2.2/22" 2>/dev/null && exit 1 || exit 0'

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
exit $(( fail > 0 ))
