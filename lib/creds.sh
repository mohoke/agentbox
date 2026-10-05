# shellcheck shell=bash
# Credential handling for boxes.
#
# The deliberate trade-off, stated once so it is not forgotten:
#
#   Sharing the host's Claude credentials into a box means the box holds a live
#   OAuth token for your account. Isolation then limits what the agent can
#   *reach*; it does not limit what the agent can *do with that token*, and a
#   successful prompt injection inside the box can use it.
#
#   The default is none: a new box is given nothing and starts logged out, so
#   there is no token to leak. Sharing is opt-in per box with `--creds share`
#   (or AGENTBOX_CREDS=share), for when logging in per box is friction that
#   would push you back to running agents with no isolation at all.
#
# What is copied is kept to the minimum that keeps you logged in:
#
#   ~/.claude/.credentials.json   the OAuth token itself
#   git user.name / user.email    so commits are attributed correctly
#
# What is deliberately NOT copied:
#
#   ~/.claude.json                config plus per-project history. Tens of
#                                 kilobytes describing every other project you
#                                 work on. Nothing in it is needed to stay
#                                 authenticated, so it stays on the host.
#   ~/.config/gh, ~/.netrc,       shell/cloud credentials. Opt in per box with
#   ~/.aws, ~/.npmrc              `agentbox creds <box> push --also <path>`.
#
# Transfer is over the box's SSH channel after boot, never through the
# cloud-init seed: a seed ISO is an unencrypted file on disk that outlives the
# session.

CRED_SRC="$HOME/.claude/.credentials.json"

creds_available() { [[ -r $CRED_SRC ]]; }

# Minutes of life left in a credentials file, or "?" if it cannot be read.
creds_ttl_minutes() {
  python3 - "${1:-$CRED_SRC}" 2>/dev/null <<'PY' || echo "?"
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))["claudeAiOauth"]
    print(int((d["expiresAt"] / 1000 - time.time()) / 60))
except Exception:
    print("?")
PY
}

creds_warn_once() {
  # Shown at create time, once per box, so the choice is informed.
  local mode=$1
  case $mode in
    share)
      warn "this box will receive a copy of your Claude OAuth token"
      dim  "    An agent in this box can use your account. Isolation limits what it"
      dim  "    can reach, not what it can do with credentials you hand it."
      dim  "    To avoid this, omit --creds (the default is none), or later:"
      dim  "    agentbox creds <box> clear   (revoke from a box)" ;;
    none)
      dim  "no host credentials will be copied; run 'claude' inside the box to log in" ;;
  esac
}

creds_push() {
  # creds_push <box_name> [extra_path ...]
  local name=$1; shift || true
  creds_available || { warn "no host credentials at $CRED_SRC -- skipping"; return 0; }

  # shellcheck disable=SC2086
  ssh -F "$SSH_CONFIG" $(ssh_opts) -o BatchMode=yes "$name" \
      'install -d -m 700 -o agent -g agent ~/.claude' 2>/dev/null \
    || { warn "could not reach box '$name' to push credentials"; return 1; }

  # shellcheck disable=SC2086
  ssh -F "$SSH_CONFIG" $(ssh_opts) -o BatchMode=yes "$name" \
      'cat > ~/.claude/.credentials.json && chmod 600 ~/.claude/.credentials.json' \
      < "$CRED_SRC" \
    || { warn "credential push failed"; return 1; }

  # Mark onboarding complete in the guest.
  #
  # A valid token is not sufficient for the interactive CLI: without
  # hasCompletedOnboarding in ~/.claude.json it runs first-run setup, whose
  # opening screen is the authentication prompt. The result looks exactly like
  # a rejected credential -- `claude -p` works while `claude` asks you to log
  # in. Only these two keys are set; ~/.claude.json on the host also holds the
  # per-project history of everything else you work on, which has no business
  # in a box.
  local onboard_version
  onboard_version=$(python3 -c "
import json, sys
try:
    print(json.load(open('$HOME/.claude.json')).get('lastOnboardingVersion', '') or '')
except Exception:
    print('')" 2>/dev/null)
  # shellcheck disable=SC2086
  ssh -F "$SSH_CONFIG" $(ssh_opts) -o BatchMode=yes "$name" \
      "python3 - $(printf '%q' "$onboard_version")" 2>/dev/null <<'PY' || \
        warn "could not mark onboarding complete; the box may show the setup screen"
import json, os, sys
path = os.path.expanduser("~/.claude.json")
try:
    with open(path) as fh:
        data = json.load(fh)
except (OSError, ValueError):
    data = {}
data["hasCompletedOnboarding"] = True
version = sys.argv[1] if len(sys.argv) > 1 else ""
if version:
    data["lastOnboardingVersion"] = version
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(data, fh, indent=2)
os.replace(tmp, path)
os.chmod(path, 0o600)
PY

  # Git identity is configuration, not a secret, but commits are wrong without it.
  local gname gmail
  gname=$(git config --global user.name  2>/dev/null || true)
  gmail=$(git config --global user.email 2>/dev/null || true)
  if [[ -n $gname && -n $gmail ]]; then
    # shellcheck disable=SC2086
    ssh -F "$SSH_CONFIG" $(ssh_opts) -o BatchMode=yes "$name" \
        "git config --global user.name $(printf '%q' "$gname") && \
         git config --global user.email $(printf '%q' "$gmail")" 2>/dev/null || true
  fi

  local extra
  for extra in "$@"; do
    [[ -r $extra ]] || { warn "cannot read $extra -- skipped"; continue; }
    local dest="${extra/#$HOME/\$HOME}"
    # shellcheck disable=SC2086
    ssh -F "$SSH_CONFIG" $(ssh_opts) -o BatchMode=yes "$name" \
        "mkdir -p \$(dirname $dest) && cat > $dest && chmod 600 $dest" < "$extra" \
      && ok "pushed $extra" || warn "failed to push $extra"
  done

  local ttl; ttl=$(creds_ttl_minutes)
  if [[ $ttl == "?" ]]; then
    ok "credentials pushed to '$name'"
  elif (( ttl < 0 )); then
    warn "pushed, but the token expired $(( -ttl )) minutes ago"
    creds_rotation_note
  elif (( ttl < 60 )); then
    warn "pushed, but this token expires in $ttl minutes"
    creds_rotation_note
  else
    ok "credentials pushed to '$name' (valid for ~$(( ttl / 60 ))h)"
  fi
}

# Explains the failure mode people actually hit, at the moment they hit it.
creds_rotation_note() {
  dim "    OAuth refresh tokens rotate when they are used. Once this host's own"
  dim "    Claude refreshes, the copy in the box is stale and cannot renew -- the"
  dim "    box then asks you to log in. Two fixes:"
  dim "      short term   agentbox creds <box> push     (re-copy the current token)"
  dim "      durable      run 'claude setup-token' on the host for a long-lived"
  dim "                   token, or set ANTHROPIC_API_KEY inside the box"
}

creds_clear() {
  local name=$1
  # shellcheck disable=SC2086
  ssh -F "$SSH_CONFIG" $(ssh_opts) -o BatchMode=yes "$name" \
      'rm -f ~/.claude/.credentials.json ~/.config/gh/hosts.yml ~/.netrc 2>/dev/null; true' \
    || { warn "could not reach box '$name'"; return 1; }
  ok "credentials removed from '$name' (the agent is now logged out there)"
  dim "    the token itself is still valid -- revoke it at console.anthropic.com if it leaked"
}

creds_status() {
  local name=$1
  # shellcheck disable=SC2086
  ssh -F "$SSH_CONFIG" $(ssh_opts) -o BatchMode=yes "$name" '
    if [ -f ~/.claude/.credentials.json ]; then
      echo "claude oauth token: present ($(stat -c %s ~/.claude/.credentials.json) bytes, mode $(stat -c %a ~/.claude/.credentials.json))"
    else
      echo "claude oauth token: absent"
    fi
    if [ -f ~/.claude/.credentials.json ]; then
      python3 -c "
import json, time
try:
    d = json.load(open(\"/home/agent/.claude/.credentials.json\"))[\"claudeAiOauth\"]
    m = int((d[\"expiresAt\"]/1000 - time.time())/60)
    print(\"token validity:     \" + (f\"expired {-m} min ago -- run: agentbox creds <box> push\" if m < 0 else f\"{m} min remaining\"))
except Exception as e:
    print(\"token validity:     unreadable\")
" 2>/dev/null || true
    fi
    printf "git identity:       %s <%s>\n" "$(git config --global user.name 2>/dev/null || echo unset)" \
                                           "$(git config --global user.email 2>/dev/null || echo unset)"
    for f in ~/.config/gh/hosts.yml ~/.netrc ~/.npmrc ~/.aws/credentials; do
      [ -f "$f" ] && echo "also present:       $f"
    done
    true'
}

cmd_creds() {
  # Quoted: an unquoted ${1:?...} whose message contains spaces is split into
  # words by `local`, which then rejects them as identifiers.
  local name="${1-}"
  [[ -n $name ]] || die "usage: agentbox creds <name> {push|clear|status} [--also PATH]"
  shift
  local action="${1-status}"
  [[ $# -gt 0 ]] && shift
  load_box "$name"
  box_running "$BOX_DIR" || die "box '$name' is not running -- agentbox up $name"

  local extras=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      --also) extras+=("$2"); shift 2 ;;
      *) die "creds: unknown option $1" ;;
    esac
  done

  case $action in
    push)   creds_push "$name" ${extras[@]+"${extras[@]}"} ;;
    clear)  creds_clear "$name" ;;
    status) creds_status "$name" ;;
    *) die "usage: agentbox creds <name> {push|clear|status} [--also PATH]" ;;
  esac
}
