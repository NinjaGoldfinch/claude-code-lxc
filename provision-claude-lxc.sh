#!/usr/bin/env bash
#
# provision-claude-lxc.sh
#
# Creates a Debian 13 (trixie) LXC container on a Proxmox VE host, set up as a
# remote development box running Claude Code in Remote Control server mode.
#
# It handles:
#   * downloading + checksum-verifying the linuxcontainers.org rootfs
#   * creating an unprivileged LXC (onboot=1, nesting, keyctl)
#   * random root + dev-user passwords (for your password manager)
#   * an ed25519 SSH keypair for logging into the box
#   * separate ed25519 keys for GitHub *authentication* and *commit signing*
#   * the GitHub CLI (gh), used to authenticate and register both keys with
#     GitHub automatically when GH_TOKEN is supplied (interactive `gh auth
#     login` otherwise)
#   * hardened sshd (key-only, socket-activation disabled so Port works)
#   * Claude Code install + settings tuned for Remote Control
#   * a systemd unit that runs `claude remote-control` inside tmux and brings
#     it back after a reboot or a crash
#   * a credentials bundle written to the Proxmox host for you to file away
#
# RUN THIS ON THE PROXMOX HOST, AS ROOT.
#
#   chmod +x provision-claude-lxc.sh
#   ./provision-claude-lxc.sh
#
# Everything below can be overridden from the environment, e.g.
#   CTID=250 MEMORY=8192 GIT_EMAIL=me@example.com ./provision-claude-lxc.sh
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Container identity / resources
CTID="${CTID:-}"                                   # blank = next free ID
CT_HOSTNAME="${CT_HOSTNAME:-claude-dev}"
CORES="${CORES:-4}"
MEMORY="${MEMORY:-4096}"                           # MB. Claude Code wants 4GB+
SWAP="${SWAP:-2048}"                               # MB
DISK_GB="${DISK_GB:-32}"
ROOTFS_STORAGE="${ROOTFS_STORAGE:-local-lvm}"      # storage for the container disk
TEMPLATE_DIR="${TEMPLATE_DIR:-/var/lib/vz/template/cache}"
CT_TAGS="${CT_TAGS:-claude,dev}"

# Networking. Set CT_IP to a CIDR (e.g. 192.168.1.50/24) plus CT_GW for static.
BRIDGE="${BRIDGE:-vmbr0}"
CT_IP="${CT_IP:-dhcp}"
CT_GW="${CT_GW:-}"
CT_VLAN="${CT_VLAN:-}"
NAMESERVER="${NAMESERVER:-1.1.1.1 9.9.9.9}"
TIMEZONE="${TIMEZONE:-host}"
LOCALE="${LOCALE:-en_US.UTF-8}"

# Rootfs image (the one you linked; override to pick a newer build)
ROOTFS_URL="${ROOTFS_URL:-https://images.linuxcontainers.org/images/debian/trixie/amd64/default/20260904_05:24/rootfs.tar.xz}"

# Guest user + workspace
DEV_USER="${DEV_USER:-dev}"
WORKSPACE="${WORKSPACE:-/home/${DEV_USER}/projects}"
SSH_PORT="${SSH_PORT:-22}"

# Git identity used for commits and for the allowed_signers entry.
# Use the same address you have verified on GitHub, or commits show as unverified.
GIT_NAME="${GIT_NAME:-Claude Dev}"
GIT_EMAIL="${GIT_EMAIL:-CHANGE-ME@users.noreply.github.com}"

# Optional: a GitHub personal access token used to run `gh auth login
# --with-token` non-interactively and register the generated SSH keys with
# GitHub via `gh ssh-key add`, instead of pasting them into the web UI by
# hand. Needs BOTH `admin:public_key` (registers the authentication key) AND
# `admin:ssh_signing_key` (registers the signing key) on a classic token —
# without the latter, `gh ssh-key add --type signing` fails with a 404 and a
# scope hint. On a fine-grained token, grant "SSH keys" and "SSH signing
# keys" write access. Leave blank to skip: gh still gets installed, and the
# printed instructions cover `gh auth login` as an interactive alternative
# after first SSH login.
GH_TOKEN="${GH_TOKEN:-}"

# Extra toolchain
INSTALL_NODE="${INSTALL_NODE:-1}"                  # Node.js 22 from NodeSource
CLAUDE_CHANNEL="${CLAUDE_CHANNEL:-latest}"         # latest | stable

# Where the credentials bundle lands on the Proxmox host
OUT_DIR_BASE="${OUT_DIR_BASE:-/root/claude-lxc}"

# GitHub's published ed25519 host key fingerprint. Verified at provision time so
# the known_hosts entry we bake in can't be poisoned by a MITM on the host.
# Cross-check: https://docs.github.com/en/authentication/keeping-your-account-secure/githubs-ssh-key-fingerprints
GITHUB_ED25519_FP="${GITHUB_ED25519_FP:-SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU}"
ALLOW_UNVERIFIED_GITHUB_HOSTKEY="${ALLOW_UNVERIFIED_GITHUB_HOSTKEY:-0}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_OK" "$C_0" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_WARN" "$C_0" "$*" >&2; }
die()  { printf '%s fail%s %s\n' "$C_ERR" "$C_0" "$*" >&2; exit 1; }

trap 'die "aborted at line $LINENO"' ERR

# Random alphanumeric string, no pipefail landmines, no shell-hostile characters.
rand_str() {
  local n="${1:-32}" s=""
  while [ "${#s}" -lt "$n" ]; do
    local chunk
    chunk="$(openssl rand -base64 $((n * 2)))"
    chunk="${chunk//[^A-Za-z0-9]/}"
    s="${s}${chunk}"
  done
  printf '%s' "${s:0:n}"
}

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

log "Preflight checks"
[ "$(id -u)" -eq 0 ] || die "run this as root on the Proxmox host"
need pct; need pvesm; need openssl; need curl; need ssh-keygen
command -v pveversion >/dev/null 2>&1 || warn "pveversion not found — is this really a PVE host?"

if [ -z "$CTID" ]; then
  CTID="$(pvesh get /cluster/nextid)"
  ok "allocated container ID ${CTID}"
fi
if pct status "$CTID" >/dev/null 2>&1; then
  die "container ${CTID} already exists — pick another CTID or destroy it first"
fi

pvesm status --storage "$ROOTFS_STORAGE" >/dev/null 2>&1 \
  || die "storage '${ROOTFS_STORAGE}' not found (pvesm status to list)"

mkdir -p "$TEMPLATE_DIR"
OUT_DIR="${OUT_DIR_BASE}-${CTID}"
mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
ok "credentials will be written to ${OUT_DIR}"

# ---------------------------------------------------------------------------
# Fetch and verify the rootfs image
# ---------------------------------------------------------------------------

log "Fetching rootfs image"
IMG_STAMP="$(printf '%s' "$ROOTFS_URL" | awk -F/ '{print $(NF-1)}' | tr -cd 'A-Za-z0-9_')"
TEMPLATE_FILE="${TEMPLATE_DIR}/debian-trixie-${IMG_STAMP}-rootfs.tar.xz"

if [ -s "$TEMPLATE_FILE" ]; then
  ok "template already present: ${TEMPLATE_FILE}"
else
  curl -fL --retry 3 --progress-bar -o "${TEMPLATE_FILE}.part" "$ROOTFS_URL" \
    || die "could not download ${ROOTFS_URL}"
  mv "${TEMPLATE_FILE}.part" "$TEMPLATE_FILE"
  ok "downloaded $(du -h "$TEMPLATE_FILE" | cut -f1)"
fi

# linuxcontainers.org publishes SHA256SUMS next to the image. Verify if reachable.
SUMS_URL="${ROOTFS_URL%/*}/SHA256SUMS"
if SUMS="$(curl -fsSL --retry 2 "$SUMS_URL" 2>/dev/null)"; then
  EXPECT="$(printf '%s\n' "$SUMS" | awk '$2 ~ /rootfs\.tar\.xz$/ {print $1; exit}')"
  if [ -n "$EXPECT" ]; then
    ACTUAL="$(sha256sum "$TEMPLATE_FILE" | awk '{print $1}')"
    [ "$EXPECT" = "$ACTUAL" ] || die "SHA256 mismatch for rootfs (expected ${EXPECT}, got ${ACTUAL})"
    ok "SHA256 verified"
  else
    warn "SHA256SUMS fetched but no rootfs.tar.xz entry — skipping verification"
  fi
else
  warn "could not fetch ${SUMS_URL} — skipping checksum verification"
fi

# ---------------------------------------------------------------------------
# Generate credentials on the host
# ---------------------------------------------------------------------------

log "Generating credentials"
ROOT_PW="$(rand_str 32)"
DEV_PW="$(rand_str 32)"

LOGIN_KEY="${OUT_DIR}/id_ed25519_${CT_HOSTNAME}"
if [ ! -f "$LOGIN_KEY" ]; then
  ssh-keygen -t ed25519 -a 100 -N '' -C "${DEV_USER}@${CT_HOSTNAME} (login)" -f "$LOGIN_KEY" >/dev/null
fi
chmod 600 "$LOGIN_KEY"
ok "login keypair ready"

# ---------------------------------------------------------------------------
# Create the container
# ---------------------------------------------------------------------------

log "Creating LXC ${CTID} (${CT_HOSTNAME})"
NET0="name=eth0,bridge=${BRIDGE},firewall=1"
if [ "$CT_IP" = "dhcp" ]; then
  NET0="${NET0},ip=dhcp,ip6=auto"
else
  NET0="${NET0},ip=${CT_IP}"
  [ -n "$CT_GW" ] && NET0="${NET0},gw=${CT_GW}"
fi
[ -n "$CT_VLAN" ] && NET0="${NET0},tag=${CT_VLAN}"

pct create "$CTID" "$TEMPLATE_FILE" \
  --hostname "$CT_HOSTNAME" \
  --ostype debian \
  --arch amd64 \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap "$SWAP" \
  --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --net0 "$NET0" \
  --nameserver "$NAMESERVER" \
  --onboot 1 \
  --start 0 \
  --tags "$CT_TAGS" \
  --ssh-public-keys "${LOGIN_KEY}.pub" \
  --description "Claude Code remote dev box. Provisioned $(date -Is)."

pct set "$CTID" --timezone "$TIMEZONE" >/dev/null 2>&1 || warn "could not set timezone"
ok "container created"

log "Starting container"
pct start "$CTID"

# Wait for systemd, then for working DNS/network.
for _ in $(seq 1 60); do
  pct exec "$CTID" -- test -d /run/systemd/system >/dev/null 2>&1 && break
  sleep 1
done
pct exec "$CTID" -- test -d /run/systemd/system >/dev/null 2>&1 \
  || die "container did not reach systemd — check 'pct console ${CTID}'"

NET_OK=0
for _ in $(seq 1 45); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then NET_OK=1; break; fi
  sleep 2
done
[ "$NET_OK" -eq 1 ] || die "no network/DNS inside the container — check bridge ${BRIDGE} and NAMESERVER"
ok "container is up with working DNS"

# ---------------------------------------------------------------------------
# Push provisioning inputs (never via argv, so passwords stay out of ps output)
# ---------------------------------------------------------------------------

log "Provisioning the guest"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"; die "aborted at line $LINENO"' ERR

cat >"${STAGE}/provision.env" <<ENVEOF
DEV_USER='${DEV_USER}'
WORKSPACE='${WORKSPACE}'
SSH_PORT='${SSH_PORT}'
LOCALE='${LOCALE}'
GIT_NAME='${GIT_NAME}'
GIT_EMAIL='${GIT_EMAIL}'
CT_HOSTNAME='${CT_HOSTNAME}'
INSTALL_NODE='${INSTALL_NODE}'
CLAUDE_CHANNEL='${CLAUDE_CHANNEL}'
GITHUB_ED25519_FP='${GITHUB_ED25519_FP}'
ALLOW_UNVERIFIED_GITHUB_HOSTKEY='${ALLOW_UNVERIFIED_GITHUB_HOSTKEY}'
ROOT_PW='${ROOT_PW}'
DEV_PW='${DEV_PW}'
GH_TOKEN='${GH_TOKEN}'
ENVEOF

cp "${LOGIN_KEY}.pub" "${STAGE}/login_key.pub"

# --- guest script -----------------------------------------------------------
cat >"${STAGE}/provision.sh" <<'GUESTEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
. /root/provision.env
export DEBIAN_FRONTEND=noninteractive

say() { printf '\n--- %s\n' "$*"; }

say "Base packages"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl wget gnupg git openssh-server sudo tmux ripgrep fd-find \
  jq unzip zip xz-utils less nano vim-tiny htop rsync procps psmisc file \
  build-essential python3 python3-venv python3-pip locales tzdata bash-completion \
  iproute2 iputils-ping dnsutils man-db

say "Locale"
sed -i "s/^# *${LOCALE}/${LOCALE}/" /etc/locale.gen || true
grep -q "^${LOCALE}" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen >/dev/null
update-locale LANG="${LOCALE}" LC_ALL="${LOCALE}"

say "Users and passwords"
printf 'root:%s\n' "$ROOT_PW" | chpasswd
if ! id -u "$DEV_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" --shell /bin/bash "$DEV_USER"
fi
printf '%s:%s\n' "$DEV_USER" "$DEV_PW" | chpasswd
usermod -aG sudo "$DEV_USER"
# sudo needs the password — the whole point of putting it in your manager.
echo "Defaults:${DEV_USER} timestamp_timeout=30" > "/etc/sudoers.d/90-${DEV_USER}"
chmod 440 "/etc/sudoers.d/90-${DEV_USER}"

DEV_HOME="$(getent passwd "$DEV_USER" | cut -d: -f6)"

say "SSH authorized key"
install -d -m 700 -o "$DEV_USER" -g "$DEV_USER" "${DEV_HOME}/.ssh"
install -m 600 -o "$DEV_USER" -g "$DEV_USER" /root/login_key.pub "${DEV_HOME}/.ssh/authorized_keys"

say "sshd hardening"
cat > /etc/ssh/sshd_config.d/99-claude-lxc.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
X11Forwarding no
AllowAgentForwarding yes
AllowTcpForwarding yes
ClientAliveInterval 60
ClientAliveCountMax 3
AllowUsers ${DEV_USER} root
EOF
# Debian 13 defaults to socket activation, which ignores the Port directive.
# Switch to the classic service so sshd_config is authoritative.
systemctl disable --now ssh.socket >/dev/null 2>&1 || true
systemctl enable ssh.service >/dev/null 2>&1 || true
sshd -t
systemctl restart ssh.service

say "GitHub host key"
install -d -m 700 -o "$DEV_USER" -g "$DEV_USER" "${DEV_HOME}/.ssh"
ssh-keyscan -t ed25519 github.com > /tmp/gh_hostkey 2>/dev/null
GOT_FP="$(ssh-keygen -lf /tmp/gh_hostkey | awk '{print $2}')"
if [ "$GOT_FP" != "$GITHUB_ED25519_FP" ]; then
  if [ "$ALLOW_UNVERIFIED_GITHUB_HOSTKEY" = "1" ]; then
    echo "WARNING: github.com host key fingerprint ${GOT_FP} != expected ${GITHUB_ED25519_FP} (override set)"
  else
    echo "ERROR: github.com host key fingerprint mismatch."
    echo "  got:      ${GOT_FP}"
    echo "  expected: ${GITHUB_ED25519_FP}"
    echo "  Verify against GitHub's published fingerprints; if they rotated the key,"
    echo "  re-run with ALLOW_UNVERIFIED_GITHUB_HOSTKEY=1."
    exit 1
  fi
fi
cat /tmp/gh_hostkey >> "${DEV_HOME}/.ssh/known_hosts"
sort -u "${DEV_HOME}/.ssh/known_hosts" -o "${DEV_HOME}/.ssh/known_hosts"
chown "$DEV_USER:$DEV_USER" "${DEV_HOME}/.ssh/known_hosts"
chmod 644 "${DEV_HOME}/.ssh/known_hosts"
rm -f /tmp/gh_hostkey

say "GitHub auth + signing keys"
AUTH_KEY="${DEV_HOME}/.ssh/id_ed25519_github_auth"
SIGN_KEY="${DEV_HOME}/.ssh/id_ed25519_github_signing"
[ -f "$AUTH_KEY" ] || sudo -u "$DEV_USER" ssh-keygen -t ed25519 -a 100 -N '' \
  -C "${GIT_EMAIL} (github auth, ${CT_HOSTNAME})" -f "$AUTH_KEY" >/dev/null
[ -f "$SIGN_KEY" ] || sudo -u "$DEV_USER" ssh-keygen -t ed25519 -a 100 -N '' \
  -C "${GIT_EMAIL} (git signing, ${CT_HOSTNAME})" -f "$SIGN_KEY" >/dev/null

cat > "${DEV_HOME}/.ssh/config" <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile ${AUTH_KEY}
  IdentitiesOnly yes

Host *
  ServerAliveInterval 60
  ServerAliveCountMax 3
EOF
chown -R "$DEV_USER:$DEV_USER" "${DEV_HOME}/.ssh"
chmod 700 "${DEV_HOME}/.ssh"; chmod 600 "${DEV_HOME}/.ssh/config" "$AUTH_KEY" "$SIGN_KEY"

say "git config with SSH commit signing"
install -d -m 755 -o "$DEV_USER" -g "$DEV_USER" "${DEV_HOME}/.config/git"
printf '%s namespaces="git" %s\n' "$GIT_EMAIL" "$(cat "${SIGN_KEY}.pub")" \
  > "${DEV_HOME}/.config/git/allowed_signers"
chown "$DEV_USER:$DEV_USER" "${DEV_HOME}/.config/git/allowed_signers"

sudo -u "$DEV_USER" git config --global user.name "$GIT_NAME"
sudo -u "$DEV_USER" git config --global user.email "$GIT_EMAIL"
sudo -u "$DEV_USER" git config --global init.defaultBranch main
sudo -u "$DEV_USER" git config --global pull.rebase true
sudo -u "$DEV_USER" git config --global gpg.format ssh
sudo -u "$DEV_USER" git config --global user.signingkey "${SIGN_KEY}.pub"
sudo -u "$DEV_USER" git config --global commit.gpgsign true
sudo -u "$DEV_USER" git config --global tag.gpgsign true
sudo -u "$DEV_USER" git config --global gpg.ssh.allowedSignersFile "${DEV_HOME}/.config/git/allowed_signers"

say "GitHub CLI (gh)"
install -d -m 0755 /etc/apt/keyrings
if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
     -o /etc/apt/keyrings/githubcli-archive-keyring.gpg 2>/dev/null; then
  chmod 644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq
  apt-get install -y -qq gh || echo "WARNING: gh package install failed"
else
  echo "WARNING: could not fetch the GitHub CLI signing key; skipping gh install"
fi

say "GitHub CLI authentication"
if ! command -v gh >/dev/null 2>&1; then
  echo "gh is not installed; skipping automatic auth and key registration."
  echo "Set it up later with: gh auth login --git-protocol ssh --hostname github.com"
elif [ -z "$GH_TOKEN" ]; then
  echo "No GH_TOKEN provided; skipping automatic auth and key registration."
  echo "After first login, run:"
  echo "  gh auth login --git-protocol ssh --hostname github.com"
  echo "  gh ssh-key add ~/.ssh/id_ed25519_github_auth.pub --type authentication --title '${GIT_EMAIL} (github auth, ${CT_HOSTNAME})'"
  echo "  gh ssh-key add ~/.ssh/id_ed25519_github_signing.pub --type signing --title '${GIT_EMAIL} (git signing, ${CT_HOSTNAME})'"
else
  if printf '%s' "$GH_TOKEN" \
       | sudo -u "$DEV_USER" -H gh auth login --hostname github.com --git-protocol ssh --with-token \
       2>/tmp/gh_login.err; then
    ok_msg="gh authenticated as $(sudo -u "$DEV_USER" -H gh api user -q .login 2>/dev/null || echo '<unknown>')"
    echo "$ok_msg"
    sudo -u "$DEV_USER" -H gh auth setup-git >/dev/null 2>&1 \
      || echo "WARNING: gh auth setup-git failed"
    sudo -u "$DEV_USER" -H gh ssh-key add "$AUTH_KEY.pub" --type authentication \
        --title "${GIT_EMAIL} (github auth, ${CT_HOSTNAME})" 2>/tmp/gh_authkey.err \
      || echo "WARNING: could not register the authentication key with gh (it may already be registered): $(cat /tmp/gh_authkey.err 2>/dev/null)"
    sudo -u "$DEV_USER" -H gh ssh-key add "$SIGN_KEY.pub" --type signing \
        --title "${GIT_EMAIL} (git signing, ${CT_HOSTNAME})" 2>/tmp/gh_signkey.err \
      || echo "WARNING: could not register the signing key with gh (it may already be registered): $(cat /tmp/gh_signkey.err 2>/dev/null)"
  else
    echo "WARNING: gh auth login --with-token failed: $(cat /tmp/gh_login.err 2>/dev/null)"
    echo "Falling back to manual setup after first login (see README)."
  fi
  rm -f /tmp/gh_login.err /tmp/gh_authkey.err /tmp/gh_signkey.err
fi

if [ "$INSTALL_NODE" = "1" ]; then
  say "Node.js 22"
  install -d -m 0755 /etc/apt/keyrings
  if curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
       | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg 2>/dev/null; then
    chmod 644 /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list
    apt-get update -qq && apt-get install -y -qq nodejs || {
      echo "NodeSource failed; falling back to Debian nodejs"
      rm -f /etc/apt/sources.list.d/nodesource.list
      apt-get update -qq && apt-get install -y -qq nodejs npm || true
    }
  else
    apt-get install -y -qq nodejs npm || true
  fi
  # global npm prefix in the user's home so `npm -g` never needs sudo
  sudo -u "$DEV_USER" npm config set prefix "${DEV_HOME}/.npm-global" >/dev/null 2>&1 || true
fi

say "Claude Code"
# Native installer: per-user, auto-updating. Falls back to the signed apt repo.
if sudo -u "$DEV_USER" -H bash -lc \
     "curl -fsSL https://claude.ai/install.sh | bash -s ${CLAUDE_CHANNEL}"; then
  echo "installed via native installer"
else
  echo "native installer failed; using the apt repository"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o /etc/apt/keyrings/claude-code.asc
  FP="$(gpg --show-keys --with-colons /etc/apt/keyrings/claude-code.asc | awk -F: '/^fpr:/{print $10; exit}')"
  [ "$FP" = "31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE" ] \
    || { echo "ERROR: Claude Code signing key fingerprint mismatch: $FP"; exit 1; }
  echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
    > /etc/apt/sources.list.d/claude-code.list
  apt-get update -qq
  apt-get install -y -qq claude-code
fi

# PATH for interactive + non-interactive shells
cat > /etc/profile.d/10-claude-dev.sh <<'EOF'
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac
case ":$PATH:" in
  *":$HOME/.npm-global/bin:"*) ;;
  *) PATH="$HOME/.npm-global/bin:$PATH" ;;
esac
export PATH
EOF
chmod 644 /etc/profile.d/10-claude-dev.sh

say "Claude Code settings"
install -d -m 700 -o "$DEV_USER" -g "$DEV_USER" "${DEV_HOME}/.claude"
cat > "${DEV_HOME}/.claude/settings.json" <<EOF
{
  "autoUpdatesChannel": "${CLAUDE_CHANNEL}",
  "remoteControlAtStartup": true,
  "includeCoAuthoredBy": true,
  "theme": "dark"
}
EOF
chown "$DEV_USER:$DEV_USER" "${DEV_HOME}/.claude/settings.json"
chmod 600 "${DEV_HOME}/.claude/settings.json"
install -d -m 755 -o "$DEV_USER" -g "$DEV_USER" "$WORKSPACE"

say "tmux + helper scripts"
cat > "${DEV_HOME}/.tmux.conf" <<'EOF'
set -g mouse on
set -g history-limit 50000
set -g default-terminal "tmux-256color"
set -g status-bg colour238
set -g status-fg colour255
EOF
chown "$DEV_USER:$DEV_USER" "${DEV_HOME}/.tmux.conf"

# The supervised loop. Remote Control makes outbound HTTPS only, so nothing
# needs to be exposed. It requires a claude.ai login (Pro/Max/Team/Enterprise);
# an API key will not work, and ANTHROPIC_BASE_URL must stay unset.
cat > /usr/local/bin/claude-remote-session <<EOF
#!/usr/bin/env bash
set -uo pipefail
cd "${WORKSPACE}" || exit 1
unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL DISABLE_TELEMETRY DO_NOT_TRACK \\
      DISABLE_GROWTHBOOK CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
export PATH="\$HOME/.local/bin:\$HOME/.npm-global/bin:\$PATH"

while true; do
  if ! command -v claude >/dev/null 2>&1; then
    echo "claude not on PATH; retrying in 30s"; sleep 30; continue
  fi
  echo "starting: claude remote-control --name ${CT_HOSTNAME}"
  claude remote-control --name "${CT_HOSTNAME}"
  code=\$?
  echo
  echo "remote-control exited (\$code)."
  echo "If it says you are not signed in, run:  claude   then  /login"
  echo "Retrying in 15s. Ctrl-C twice to stop, or: sudo systemctl stop claude-remote"
  sleep 15
done
EOF
chmod 755 /usr/local/bin/claude-remote-session

cat > /usr/local/bin/claude-attach <<EOF
#!/usr/bin/env bash
exec tmux attach -t claude
EOF
chmod 755 /usr/local/bin/claude-attach

say "systemd unit"
cat > /etc/systemd/system/claude-remote.service <<EOF
[Unit]
Description=Claude Code Remote Control session (tmux)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${DEV_USER}
Group=${DEV_USER}
WorkingDirectory=${WORKSPACE}
Environment=HOME=${DEV_HOME}
Environment=TERM=xterm-256color
ExecStart=/usr/bin/tmux new-session -d -s claude /usr/local/bin/claude-remote-session
ExecStop=/usr/bin/tmux kill-session -t claude
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable claude-remote.service >/dev/null

cat >> "${DEV_HOME}/.bashrc" <<'EOF'

# --- claude dev box ---
alias ca='claude-attach'
if [ -z "${TMUX:-}" ] && [ -n "${SSH_TTY:-}" ]; then
  echo "Claude Remote Control session: run 'ca' (or 'claude-attach') to attach."
fi
EOF
chown "$DEV_USER:$DEV_USER" "${DEV_HOME}/.bashrc"

say "Cleanup"
apt-get -qq autoremove -y >/dev/null 2>&1 || true
apt-get -qq clean
shred -u /root/provision.env 2>/dev/null || rm -f /root/provision.env
rm -f /root/login_key.pub

echo
echo "GUEST_PROVISION_OK"
GUESTEOF
# --- end guest script -------------------------------------------------------

pct push "$CTID" "${STAGE}/provision.env" /root/provision.env --perms 0600
pct push "$CTID" "${STAGE}/login_key.pub"  /root/login_key.pub --perms 0644
pct push "$CTID" "${STAGE}/provision.sh"   /root/provision.sh  --perms 0700
rm -rf "$STAGE"
trap 'die "aborted at line $LINENO"' ERR

pct exec "$CTID" -- /bin/bash /root/provision.sh
pct exec "$CTID" -- rm -f /root/provision.sh
ok "guest provisioned"

log "Starting the Claude Remote Control service"
pct exec "$CTID" -- systemctl start claude-remote.service || warn "service start returned non-zero"

# ---------------------------------------------------------------------------
# Collect keys and write the credentials bundle
# ---------------------------------------------------------------------------

log "Collecting credentials"
DEV_HOME_HOST="/home/${DEV_USER}"
for f in id_ed25519_github_auth id_ed25519_github_auth.pub \
         id_ed25519_github_signing id_ed25519_github_signing.pub; do
  pct pull "$CTID" "${DEV_HOME_HOST}/.ssh/${f}" "${OUT_DIR}/${f}" >/dev/null 2>&1 \
    || warn "could not pull ${f}"
done
chmod 600 "${OUT_DIR}"/id_ed25519_github_* 2>/dev/null || true

CT_ADDR="$(pct exec "$CTID" -- bash -c "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null || true)"
[ -n "$CT_ADDR" ] || CT_ADDR="<container-ip>"

HOSTKEY_FPS="$(pct exec "$CTID" -- bash -c 'for k in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$k"; done' 2>/dev/null || true)"
GH_AUTH_PUB="$(cat "${OUT_DIR}/id_ed25519_github_auth.pub" 2>/dev/null || echo '<pull failed>')"
GH_SIGN_PUB="$(cat "${OUT_DIR}/id_ed25519_github_signing.pub" 2>/dev/null || echo '<pull failed>')"
CLAUDE_VER="$(pct exec "$CTID" -- sudo -u "$DEV_USER" -H bash -lc 'claude --version' 2>/dev/null || echo 'unknown')"
GH_AUTH_STATUS="$(pct exec "$CTID" -- sudo -u "$DEV_USER" -H bash -lc 'gh auth status 2>&1' 2>/dev/null || echo 'gh not installed or not authenticated')"

if [ -n "$GH_TOKEN" ]; then
  GH_CRED_NOTE="Registered automatically via 'gh ssh-key add' during provisioning
(GH_TOKEN was supplied). Current status on the box:

${GH_AUTH_STATUS}

If either registration warned above, add the key manually at the URL below."
else
  GH_CRED_NOTE="No GH_TOKEN was supplied, so these were NOT registered with GitHub.
Easiest: ssh in and run
  gh auth login --git-protocol ssh --hostname github.com
  gh ssh-key add ~/.ssh/id_ed25519_github_auth.pub --type authentication --title '${GIT_EMAIL} (github auth, ${CT_HOSTNAME})'
  gh ssh-key add ~/.ssh/id_ed25519_github_signing.pub --type signing --title '${GIT_EMAIL} (git signing, ${CT_HOSTNAME})'
Or add the public keys below by hand at the URL under each one."
fi

CRED_FILE="${OUT_DIR}/CREDENTIALS.txt"
umask 077
cat > "$CRED_FILE" <<EOF
================================================================================
 Claude Code dev container — ${CT_HOSTNAME} (CTID ${CTID})
 Provisioned $(date -Is) on $(hostname)
 Claude Code version: ${CLAUDE_VER}
================================================================================

-- 1Password: Server / Login item -----------------------------------------------
Title:           ${CT_HOSTNAME} (Proxmox LXC ${CTID})
Host:            ${CT_ADDR}
SSH port:        ${SSH_PORT}
Username:        ${DEV_USER}
Password:        ${DEV_PW}
Root password:   ${ROOT_PW}
Notes:           Password auth over SSH is DISABLED. The passwords above are for
                 the Proxmox console (pct console ${CTID} / pct enter ${CTID})
                 and for sudo. Key-based SSH only.

-- 1Password: SSH Key item — box login ------------------------------------------
Private key file: ${LOGIN_KEY}
Public key:       $(cat "${LOGIN_KEY}.pub")

Connect with:
  ssh -i ${LOGIN_KEY} -p ${SSH_PORT} ${DEV_USER}@${CT_ADDR}

Container SSH host key fingerprints (verify on first connect):
${HOSTKEY_FPS}

-- 1Password: SSH Key item — GitHub authentication ------------------------------
Private key file: ${OUT_DIR}/id_ed25519_github_auth
Public key (AUTHENTICATION key):
${GH_AUTH_PUB}
  https://github.com/settings/ssh/new  ->  Key type: Authentication Key

-- 1Password: SSH Key item — GitHub commit signing ------------------------------
Private key file: ${OUT_DIR}/id_ed25519_github_signing
Public key (SIGNING key):
${GH_SIGN_PUB}
  https://github.com/settings/ssh/new  ->  Key type: Signing Key

-- GitHub CLI (gh) registration --------------------------------------------------
${GH_CRED_NOTE}

Both private keys also live in the container at
  /home/${DEV_USER}/.ssh/  — the copies here are for your password manager.
Once filed, you can delete ${OUT_DIR} from the Proxmox host.

-- Git identity ------------------------------------------------------------------
user.name:   ${GIT_NAME}
user.email:  ${GIT_EMAIL}
Commit signing is ON (gpg.format=ssh). If GIT_EMAIL is still the placeholder,
update it and rewrite allowed_signers:

  git config --global user.email you@example.com
  printf '%s namespaces="git" %s\n' you@example.com \\
    "\$(cat ~/.ssh/id_ed25519_github_signing.pub)" > ~/.config/git/allowed_signers

-- Day to day --------------------------------------------------------------------
Attach to the running session:   ssh in, then  ca
Service control:                 sudo systemctl {status,restart,stop} claude-remote
Session logs:                    journalctl -u claude-remote
Workspace:                       ${WORKSPACE}
Autostart:                       container onboot=1 + claude-remote.service enabled
================================================================================
EOF
chmod 600 "$CRED_FILE"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

if [ -n "$GH_TOKEN" ]; then
  GH_NEXT_STEP="GitHub CLI (gh) was authenticated during provisioning and both SSH keys were
registered automatically. Check the credentials bundle's 'gh auth status'
output if either registration step warned above."
else
  GH_NEXT_STEP="GitHub CLI (gh) is installed but not signed in (no GH_TOKEN was given). Once
you're in, finish it with:
       gh auth login --git-protocol ssh --hostname github.com
       gh ssh-key add ~/.ssh/id_ed25519_github_auth.pub --type authentication --title '${GIT_EMAIL} (github auth, ${CT_HOSTNAME})'
       gh ssh-key add ~/.ssh/id_ed25519_github_signing.pub --type signing --title '${GIT_EMAIL} (git signing, ${CT_HOSTNAME})'"
fi

cat <<EOF

${C_OK}${C_B}Container ${CTID} (${CT_HOSTNAME}) is up.${C_0}

Credentials bundle: ${C_B}${CRED_FILE}${C_0}

${C_B}One manual step is left: signing in to Claude Code.${C_0}
Remote Control needs a claude.ai login (Pro, Max, Team, or Enterprise). An API
key will not work. OAuth can't open a browser in here, so it prints a URL and
takes a code back.

  1) ssh -i ${LOGIN_KEY} -p ${SSH_PORT} ${DEV_USER}@${CT_ADDR}
  2) cd ${WORKSPACE} && claude
       - accept the workspace-trust prompt
       - run /login and follow the URL + code flow
       - Ctrl-C out once you're signed in
  3) sudo systemctl restart claude-remote
  4) ca            # attach to tmux; the session URL and QR code are shown there

Then open claude.ai/code or the Claude mobile app and pick the session named
"${CT_HOSTNAME}". It survives reboots: the container starts on boot and
claude-remote.service brings the tmux session back with it.

${C_B}GitHub CLI:${C_0} ${GH_NEXT_STEP}

EOF
