#!/bin/bash
# Runs once as root inside the build VM, then powers it off.
# Everything here is baked into base.qcow2 and shared by every box.
set -euo pipefail
exec > >(tee -a /var/log/agentbox-provision.log) 2>&1

NODE_MAJOR="${NODE_MAJOR:-22}"
export DEBIAN_FRONTEND=noninteractive

echo "### agentbox provision starting $(date -Is)"

# ------------------------------------------------------------------ system ---
apt-get update
apt-get -y upgrade
apt-get -y install --no-install-recommends \
  build-essential pkg-config make gcc g++ git curl wget ca-certificates gnupg \
  python3 python3-venv python3-pip python3-dev pipx \
  postgresql postgresql-contrib libpq-dev \
  sqlite3 jq ripgrep fd-find tmux htop less unzip zip rsync file \
  bind9-dnsutils iproute2 \
  openssh-server ncdu bash-completion man-db locales tzdata

# Ubuntu ships fd as fdfind to avoid a name clash; agents expect `fd`.
ln -sf "$(command -v fdfind)" /usr/local/bin/fd

# ------------------------------------------------------------------- node ----
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
apt-get -y install --no-install-recommends nodejs

# ------------------------------------------------------- the agent account ---
# uid/gid 1000 must match the host user so virtiofs ownership lines up.
if id ubuntu >/dev/null 2>&1; then
  pkill -u ubuntu || true
  deluser --remove-home ubuntu 2>/dev/null || userdel -r ubuntu || true
fi
getent group ubuntu >/dev/null && delgroup ubuntu 2>/dev/null || true
getent group agent  >/dev/null || groupadd -g 1000 agent
id agent 2>/dev/null || useradd -m -u 1000 -g 1000 -G sudo,adm -s /bin/bash agent
install -d -o agent -g agent -m 0755 /home/agent/workspace /home/agent/scratch \
                                     /home/agent/.claude /home/agent/.config
printf 'agent ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-agent
chmod 0440 /etc/sudoers.d/90-agent

# ------------------------------------------------------------- postgresql ----
systemctl enable postgresql
systemctl start  postgresql
su - postgres -c "psql -tAc \"select 1 from pg_roles where rolname='agent'\"" | grep -q 1 \
  || su - postgres -c "createuser --superuser agent"
su - postgres -c "psql -tAlq | cut -d'|' -f1 | grep -qw agent" \
  || su - postgres -c "createdb -O agent agent"
# Local-only: the cluster listens on the unix socket and loopback, nothing else.
PGCONF=$(su - postgres -c "psql -tAc 'show config_file'")
sed -i "s/^#\?listen_addresses.*/listen_addresses = 'localhost'/" "$PGCONF"
systemctl restart postgresql

# ------------------------------------------------------------ agent tools ----
# Installed as `agent`, not root, so they live in the account that uses them.
su - agent -c 'bash -s' <<'AGENT'
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.local/bin"

install_claude() {
  curl -fsSL https://claude.ai/install.sh | bash && return 0
  echo "native claude installer failed; falling back to npm" >&2
  npm config set prefix "$HOME/.local"
  npm install -g @anthropic-ai/claude-code
}
install_claude || echo "WARNING: claude install failed"

curl -fsSL https://opencode.ai/install | bash || echo "WARNING: opencode install failed"

curl -fsSL https://astral.sh/uv/install.sh | sh || echo "WARNING: uv install failed"

cat >> "$HOME/.bashrc" <<'RC'

# ---- agentbox ----
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.bun/bin:$PATH"
export PGHOST=/var/run/postgresql
export PGUSER=agent
export PIP_REQUIRE_VIRTUALENV=true
export EDITOR=${EDITOR:-vi}
cd "$HOME/workspace" 2>/dev/null || true
RC
AGENT

# ------------------------------------------------------------ tools on PATH ---
# The agent CLIs install per-user under ~/.local/bin and ~/.opencode/bin, but
# Ubuntu's .bashrc returns early for non-interactive shells -- so `ssh box cmd`,
# which is how an agent is actually driven, would never see them. Symlink into
# /usr/local/bin, which is on the default PATH for every kind of session.
# Symlinks point at the launcher, not the versioned binary, so self-updates that
# repoint ~/.local/bin/claude are picked up automatically.
cat > /usr/local/sbin/agentbox-link-tools <<'LINK'
#!/bin/sh
for b in /home/agent/.local/bin/claude /home/agent/.local/bin/uv \
         /home/agent/.local/bin/uvx  /home/agent/.opencode/bin/opencode; do
  [ -e "$b" ] && ln -sfn "$b" "/usr/local/bin/$(basename "$b")"
done
exit 0
LINK
chmod +x /usr/local/sbin/agentbox-link-tools
/usr/local/sbin/agentbox-link-tools

# ------------------------------------------------- baked-in agent context ----
install -d -m 0755 /opt/agentbox
install -m 0644 /tmp/agentbox-CLAUDE.md /opt/agentbox/CLAUDE.md
install -o agent -g agent -m 0644 /tmp/agentbox-CLAUDE.md /home/agent/.claude/CLAUDE.md
# opencode reads AGENTS.md; keep one source of truth.
ln -sf /opt/agentbox/CLAUDE.md /home/agent/.config/AGENTS.md
chown -h agent:agent /home/agent/.config/AGENTS.md

# ------------------------------------------------- shared workspace mount ----
# tag=workspace is supplied by virtiofsd when the host shares a project dir.
# nofail keeps boxes that have no share bootable.
grep -q '^workspace' /etc/fstab || cat >> /etc/fstab <<'FSTAB'
workspace /home/agent/workspace virtiofs rw,nofail,x-systemd.device-timeout=5s 0 0
FSTAB

# ------------------------------------------------------------------- sshd ----
cat > /etc/ssh/sshd_config.d/10-agentbox.conf <<'SSHD'
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
AllowUsers agent
SSHD
systemctl enable ssh

# --------------------------------------------------------- boot-time trim ----
cat > /usr/local/bin/box-info <<'INFO'
#!/bin/bash
echo "box:      $(hostname)"
echo "workspace:$(findmnt -no SOURCE,FSTYPE /home/agent/workspace 2>/dev/null || echo ' (vm-local)')"
echo "python:   $(python3 --version 2>&1)"
echo "node:     $(node --version 2>&1)"
echo "claude:   $(claude --version 2>&1 | head -1)"
echo "opencode: $(opencode --version 2>&1 | head -1)"
echo "postgres: $(psql -tAc 'select version()' 2>&1 | head -1 | cut -c1-40)"
INFO
chmod +x /usr/local/bin/box-info

cat > /etc/update-motd.d/99-agentbox <<'MOTD'
#!/bin/sh
echo
echo "  agentbox -- isolated project VM. ~/workspace is shared with the host."
echo "  ~/.claude/CLAUDE.md describes this environment. \`box-info\` for versions."
echo
MOTD
chmod +x /etc/update-motd.d/99-agentbox
rm -f /etc/update-motd.d/10-help-text /etc/update-motd.d/50-motd-news

# Faster boots: nothing in a disposable box needs these.
systemctl disable --now snapd.service snapd.socket unattended-upgrades \
  apt-daily.timer apt-daily-upgrade.timer motd-news.timer 2>/dev/null || true

# ------------------------------------------------------------------ finish ----
apt-get -y autoremove --purge
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/agentbox-CLAUDE.md /root/.cache
truncate -s0 /var/log/*.log 2>/dev/null || true
# Drop the host keys baked in by the build VM so every box generates its own on
# first boot; otherwise all boxes share an identity and could impersonate each
# other. cloud-init's ssh module regenerates whatever is missing.
rm -f /etc/ssh/ssh_host_*

# Reset cloud-init so each box re-runs its own seed (hostname, ssh key, mounts).
cloud-init clean --logs --seed
fstrim -av || true
sync

echo "### agentbox provision complete $(date -Is)"
touch /opt/agentbox/.provisioned
