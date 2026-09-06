#!/usr/bin/env bash
#
# claude-lxc-runtime.sh
#
# Installs or refreshes the Claude Code Remote Control *runtime* inside the
# container: the claude-instance CLI, the supervised session wrapper, the
# systemd template unit and target, the PATH snippet and the shell aliases.
#
# This is the single source of truth for those files. provision-claude-lxc.sh
# runs it during provisioning; update-claude-lxc.sh runs it again later to pick
# up new code. Keeping it in one file is the point — the two callers cannot
# drift apart.
#
# It is idempotent and deliberately narrow. It touches CODE only. It never
# reads or writes:
#   * passwords, the login key, or anything under ~/.ssh
#   * ~/.claude (settings, credentials, history) — your claude.ai login is safe
#   * git config, allowed_signers, or the gh auth state
#   * /etc/claude-instances/*.env — your instances and their workspaces survive
#   * ~/.tmux.conf, once it exists — yours to edit
#
# RUN THIS AS ROOT INSIDE THE CONTAINER.
#
#   ./claude-lxc-runtime.sh [--restart]
#
# --restart cycles claude-remote.target afterwards so running instances pick up
# the new code. Without it, changes apply the next time an instance restarts.
#
# Configuration comes from /etc/claude-lxc.conf (written at provision time);
# DEV_USER, WORKSPACE_ROOT and CT_HOSTNAME in the environment override it.
#
set -Eeuo pipefail

RESTART=0
while [ $# -gt 0 ]; do
  case "$1" in
    --restart) RESTART=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "claude-lxc-runtime: unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\n--- %s\n' "$*"; }
die() { printf 'claude-lxc-runtime: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this as root inside the container"

CONF=/etc/claude-lxc.conf
# shellcheck source=/dev/null
# Capture the environment first: sourcing the config file plain-assigns these,
# which would otherwise silently beat an explicit override from the caller.
ENV_DEV_USER="${DEV_USER:-}"
ENV_WORKSPACE_ROOT="${WORKSPACE_ROOT:-}"
ENV_CT_HOSTNAME="${CT_HOSTNAME:-}"
[ -r "$CONF" ] && . "$CONF"
DEV_USER="${ENV_DEV_USER:-${DEV_USER:-}}"
WORKSPACE_ROOT="${ENV_WORKSPACE_ROOT:-${WORKSPACE_ROOT:-}}"
CT_HOSTNAME="${ENV_CT_HOSTNAME:-${CT_HOSTNAME:-}}"

DEV_USER="${DEV_USER:-dev}"
id -u "$DEV_USER" >/dev/null 2>&1 || die "user '${DEV_USER}' does not exist — is this a claude-code-lxc container?"
DEV_HOME="$(getent passwd "$DEV_USER" | cut -d: -f6)"
[ -n "$DEV_HOME" ] || die "could not resolve the home directory for ${DEV_USER}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-${DEV_HOME}/projects}"
CT_HOSTNAME="${CT_HOSTNAME:-$(hostname)}"

# Persist what the next run (and update-claude-lxc.sh) needs to know.
umask 022
cat > "$CONF" <<CONFEOF
# Written by claude-lxc-runtime.sh. Consumed on update.
DEV_USER='${DEV_USER}'
WORKSPACE_ROOT='${WORKSPACE_ROOT}'
CT_HOSTNAME='${CT_HOSTNAME}'
CONFEOF
chmod 644 "$CONF"

say "PATH snippet"
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

say "tmux defaults"
# Written once and then left alone; it is yours to edit after that.
if [ ! -e "${DEV_HOME}/.tmux.conf" ]; then
  cat > "${DEV_HOME}/.tmux.conf" <<'EOF'
set -g mouse on
set -g history-limit 50000
set -g default-terminal "tmux-256color"
set -g status-bg colour238
set -g status-fg colour255
EOF
  chown "$DEV_USER:$DEV_USER" "${DEV_HOME}/.tmux.conf"
else
  echo "keeping existing ${DEV_HOME}/.tmux.conf"
fi

say "Remote Control runtime"
# --- instance registry -----------------------------------------------------
# An instance is a name plus a workspace; everything else is derived from it:
#   registry   /etc/claude-instances/<name>.env
#   unit       claude-remote@<name>.service   (part of claude-remote.target)
#   tmux       claude-<name>
#   session    <name shown in the claude.ai/code picker>
# All instances share ~/.claude, so one `/login` authenticates every one of
# them. They must not share a workspace: Claude Code keys session state off the
# working directory.
install -d -m 755 -o root -g root /etc/claude-instances

# The supervised loop, one process per instance. Remote Control makes outbound
# HTTPS only, so nothing needs to be exposed. It requires a claude.ai login
# (Pro/Max/Team/Enterprise); an API key will not work, and ANTHROPIC_BASE_URL
# must stay unset. Every setting it needs comes from the registry file, so this
# script needs nothing expanded into it at provision time.
cat > /usr/local/bin/claude-remote-session <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

INSTANCE="${1:-}"
[ -n "$INSTANCE" ] || { echo "usage: claude-remote-session <instance>" >&2; exit 2; }
REG="/etc/claude-instances/${INSTANCE}.env"
[ -r "$REG" ] || { echo "no such instance: ${INSTANCE} (expected ${REG})" >&2; exit 2; }
# shellcheck source=/dev/null
. "$REG"

cd "$WORKSPACE" || { echo "workspace ${WORKSPACE} is gone" >&2; exit 1; }

# Each of these silently breaks Remote Control, so clear them defensively:
# an API key cannot establish a session, a gateway base URL cannot reach it,
# and the telemetry opt-outs disable the feature-flag lookup it depends on.
unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL DISABLE_TELEMETRY DO_NOT_TRACK \
      DISABLE_GROWTHBOOK CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

while true; do
  if ! command -v claude >/dev/null 2>&1; then
    echo "claude not on PATH; retrying in 30s"; sleep 30; continue
  fi
  echo "starting: claude --remote-control ${SESSION_NAME}   (workspace ${WORKSPACE})"
  claude --remote-control "$SESSION_NAME"
  code=$?
  echo
  echo "remote control for '${INSTANCE}' exited (${code})."
  echo "If it says you are not signed in, run:  claude   then  /login"
  echo "Retrying in 15s. Ctrl-C twice to stop, or:"
  echo "  sudo claude-instance stop ${INSTANCE}"
  sleep 15
done
EOF
chmod 755 /usr/local/bin/claude-remote-session

# --- claude-instance: the runtime interface --------------------------------
# Expanded prelude first (it needs the provisioning values), literal body
# second, so nothing in the logic has to be backslash-escaped.
cat > /usr/local/bin/claude-instance <<EOF
#!/usr/bin/env bash
# Manage Claude Code Remote Control instances. Generated by provision-claude-lxc.sh.
DEV_USER='${DEV_USER}'
WORKSPACE_ROOT='${WORKSPACE_ROOT}'
CT_HOSTNAME='${CT_HOSTNAME}'
EOF
cat >> /usr/local/bin/claude-instance <<'EOF'
set -uo pipefail

REG_DIR=/etc/claude-instances
TARGET=claude-remote.target

die()   { printf 'claude-instance: %s\n' "$*" >&2; exit 1; }
unit()  { printf 'claude-remote@%s.service' "$1"; }
regf()  { printf '%s/%s.env' "$REG_DIR" "$1"; }
tmuxs() { printf 'claude-%s' "$1"; }

# Same rule the provisioner enforces: unambiguous as a systemd unit instance,
# a tmux session name and a directory name all at once.
valid_name() {
  case "$1" in
    [a-z0-9]*) [ "${#1}" -le 31 ] && [ -z "${1//[a-z0-9_-]/}" ] ;;
    *) return 1 ;;
  esac
}

# Mutating subcommands need root for systemctl and /etc; attach and logs do not.
need_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  command -v sudo >/dev/null 2>&1 || die "must be run as root"
  exec sudo -E "$0" "$@"
}

# tmux sessions belong to the dev user, so reach them as that user when root.
as_dev() {
  if [ "$(id -u)" -eq 0 ] && [ "$(id -un)" != "$DEV_USER" ]; then
    sudo -u "$DEV_USER" -H "$@"
  else
    "$@"
  fi
}

names() {
  local f n
  shopt -s nullglob
  for f in "$REG_DIR"/*.env; do n="${f##*/}"; printf '%s\n' "${n%.env}"; done
  shopt -u nullglob
}

load() {
  local f; f="$(regf "$1")"
  [ -r "$f" ] || die "no such instance: $1  (try: claude-instance list)"
  INSTANCE=""; WORKSPACE=""; SESSION_NAME=""
  # shellcheck source=/dev/null
  . "$f"
}

check_workspace() {
  case "$1" in
    /*) ;;
    *) die "workspace must be an absolute path, got '$1'" ;;
  esac
  case "$1" in
    *[[:space:]]*|*\'*) die "workspace must not contain whitespace or quotes" ;;
  esac
}

cmd_list() {
  local n state enabled tmux_state
  printf '%-16s %-26s %-34s %-10s %-9s %s\n' NAME SESSION WORKSPACE ACTIVE ENABLED TMUX
  for n in $(names); do
    load "$n"
    state="$(systemctl is-active "$(unit "$n")" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$(unit "$n")" 2>/dev/null || true)"
    if as_dev tmux has-session -t "$(tmuxs "$n")" 2>/dev/null; then
      tmux_state=up
    else
      tmux_state=down
    fi
    printf '%-16s %-26s %-34s %-10s %-9s %s\n' \
      "$n" "$SESSION_NAME" "$WORKSPACE" "${state:-unknown}" "${enabled:-unknown}" "$tmux_state"
  done
}

cmd_add() {
  need_root add "$@"
  local name="" ws="" session="" start=1 other name_dns
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace)    ws="${2:-}";      shift 2 ;;
      --session-name) session="${2:-}"; shift 2 ;;
      --no-start)     start=0;          shift ;;
      -*)             die "unknown option for add: $1" ;;
      *)              [ -z "$name" ] || die "add takes one name"; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || die "usage: claude-instance add <name> [--workspace PATH] [--session-name NAME] [--no-start]"
  valid_name "$name" || die "invalid instance name '$name' — use [a-z0-9][a-z0-9_-]{0,30}"
  [ -e "$(regf "$name")" ] && die "instance '$name' already exists"

  [ -n "$ws" ] || ws="${WORKSPACE_ROOT}/${name}"
  check_workspace "$ws"
  ws="${ws%/}"
  for other in $(names); do
    load "$other"
    [ "$WORKSPACE" = "$ws" ] && die "instance '$other' already uses workspace ${ws} — each instance needs its own"
  done
  if [ -z "$session" ]; then
    # A box named after its project would otherwise read
    # "ninja-recorder-dev-container-ninja-recorder" in the picker, so drop the
    # repetition when the hostname already leads with the instance name.
    # Hostnames fold underscores to hyphens, so compare the folded form.
    name_dns="${name//_/-}"
    case "$CT_HOSTNAME" in
      "$name_dns"|"$name_dns"-*) session="$CT_HOSTNAME" ;;
      *)                         session="${CT_HOSTNAME}-${name}" ;;
    esac
  fi

  install -d -m 755 -o "$DEV_USER" -g "$DEV_USER" "$ws"
  ( umask 022
    cat > "$(regf "$name")" <<REG
INSTANCE='${name}'
WORKSPACE='${ws}'
SESSION_NAME='${session}'
REG
  )
  systemctl enable "$(unit "$name")" >/dev/null 2>&1 \
    || die "could not enable $(unit "$name")"
  if [ "$start" -eq 1 ]; then
    systemctl start "$(unit "$name")" || die "could not start $(unit "$name")"
    printf 'added and started %s  (session %s, workspace %s)\n' "$name" "$session" "$ws"
  else
    printf 'added %s  (session %s, workspace %s) — not started\n' "$name" "$session" "$ws"
  fi
}

cmd_remove() {
  need_root remove "$@"
  local name="" purge=0 assume_yes=0 reply
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge)    purge=1; shift ;;
      -y|--yes)   assume_yes=1; shift ;;
      -*)         die "unknown option for remove: $1" ;;
      *)          [ -z "$name" ] || die "remove takes one name"; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || die "usage: claude-instance remove <name> [--purge] [--yes]"
  load "$name"
  local ws="$WORKSPACE"

  # Vet the purge before touching anything, so refusing it cannot leave the
  # instance half-removed.
  if [ "$purge" -eq 1 ]; then
    case "$ws" in
      /|/home|/root|/home/"$DEV_USER"|"$WORKSPACE_ROOT")
        die "refusing to purge ${ws} — drop --purge and delete it by hand if you mean it" ;;
    esac
    if [ "$assume_yes" -eq 0 ]; then
      printf 'delete workspace %s and everything in it? [y/N] ' "$ws"
      read -r reply
      case "$reply" in [yY]|[yY][eE][sS]) ;; *) die "aborted — ${name} left alone" ;; esac
    fi
  fi

  systemctl disable --now "$(unit "$name")" >/dev/null 2>&1 || true
  as_dev tmux kill-session -t "$(tmuxs "$name")" >/dev/null 2>&1 || true
  rm -f "$(regf "$name")"
  printf 'removed instance %s\n' "$name"

  if [ "$purge" -eq 1 ]; then
    rm -rf -- "$ws"
    printf 'purged workspace %s\n' "$ws"
  else
    printf 'workspace left in place: %s\n' "$ws"
  fi
}

# start / stop / restart, over one instance or --all.
cmd_lifecycle() {
  local action="$1"; shift
  need_root "$action" "$@"
  local targets=() n
  if [ $# -eq 0 ]; then
    die "usage: claude-instance ${action} <name>... | --all"
  elif [ "$1" = "--all" ]; then
    mapfile -t targets < <(names)
    [ "${#targets[@]}" -gt 0 ] || die "no instances configured"
  else
    targets=("$@")
  fi
  for n in "${targets[@]}"; do
    [ -e "$(regf "$n")" ] || die "no such instance: $n"
    systemctl "$action" "$(unit "$n")" || die "systemctl ${action} failed for ${n}"
    printf '%s %s\n' "$action" "$n"
  done
}

cmd_attach() {
  local name="${1:-}" count
  if [ -z "$name" ]; then
    count="$(names | wc -l)"
    if [ "$count" -eq 1 ]; then
      name="$(names)"
    elif [ "$count" -eq 0 ]; then
      die "no instances configured — create one with: sudo claude-instance add <name>"
    else
      echo "several instances are configured — name the one you want:" >&2
      cmd_list >&2
      exit 1
    fi
  fi
  [ -e "$(regf "$name")" ] || die "no such instance: $name  (try: claude-instance list)"
  as_dev tmux has-session -t "$(tmuxs "$name")" 2>/dev/null \
    || die "instance '$name' has no live tmux session — start it with: sudo claude-instance start $name"
  # exec needs a real command, so as_dev cannot be used here.
  if [ "$(id -u)" -eq 0 ] && [ "$(id -un)" != "$DEV_USER" ]; then
    exec sudo -u "$DEV_USER" -H tmux attach -t "$(tmuxs "$name")"
  fi
  exec tmux attach -t "$(tmuxs "$name")"
}

cmd_logs() {
  local name="" follow=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--follow) follow=(-f); shift ;;
      *)           name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || die "usage: claude-instance logs <name> [-f]"
  [ -e "$(regf "$name")" ] || die "no such instance: $name"
  exec journalctl "${follow[@]}" -u "$(unit "$name")"
}

usage() {
  cat <<USAGE
claude-instance — manage Claude Code Remote Control instances on this box

  list                                     show every instance and its state
  add <name> [--workspace PATH]            create an instance and start it
             [--session-name NAME]         (default workspace ${WORKSPACE_ROOT}/<name>,
             [--no-start]                   default session name ${CT_HOSTNAME}-<name>,
                                            or just ${CT_HOSTNAME} when it
                                            already starts with <name>)
  remove <name> [--purge] [--yes]          stop, disable and forget an instance
  start|stop|restart <name>... | --all     lifecycle for one, several, or all
  attach [name]                            attach to the instance's tmux session
  logs <name> [-f]                         journal for the instance's unit

All instances share one claude.ai login (~/.claude), so signing in once covers
them all. Each needs its own workspace. Whole fleet at once:

  sudo systemctl restart ${TARGET}
USAGE
}

case "${1:-}" in
  list|ls)            shift; cmd_list "$@" ;;
  add|create)         shift; cmd_add "$@" ;;
  remove|rm|delete)   shift; cmd_remove "$@" ;;
  start|stop|restart) action="$1"; shift; cmd_lifecycle "$action" "$@" ;;
  attach)             shift; cmd_attach "$@" ;;
  logs)               shift; cmd_logs "$@" ;;
  ""|-h|--help|help)  usage ;;
  *)                  printf 'claude-instance: unknown command: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
esac
EOF
chmod 755 /usr/local/bin/claude-instance

# Kept for the `ca` alias and for muscle memory.
cat > /usr/local/bin/claude-attach <<'EOF'
#!/usr/bin/env bash
exec claude-instance attach "$@"
EOF
chmod 755 /usr/local/bin/claude-attach

say "systemd units"
# One template unit covers every instance. WorkingDirectory has to be a literal
# (systemd does not expand variables there), so the per-instance cd lives in
# claude-remote-session instead.
cat > /etc/systemd/system/claude-remote@.service <<EOF
[Unit]
Description=Claude Code Remote Control session (%i)
After=network-online.target
Wants=network-online.target
PartOf=claude-remote.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${DEV_USER}
Group=${DEV_USER}
WorkingDirectory=${DEV_HOME}
Environment=HOME=${DEV_HOME}
Environment=TERM=xterm-256color
ExecStartPre=-/usr/bin/tmux kill-session -t claude-%i
ExecStart=/usr/bin/tmux new-session -d -s claude-%i /usr/local/bin/claude-remote-session %i
ExecStop=-/usr/bin/tmux kill-session -t claude-%i
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target claude-remote.target
EOF

cat > /etc/systemd/system/claude-remote.target <<EOF
[Unit]
Description=All Claude Code Remote Control instances
After=network-online.target
Wants=network-online.target

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable claude-remote.target >/dev/null

say "Shell aliases"
# Kept inside markers so re-running rewrites the block instead of stacking up
# another copy of it.
BASHRC="${DEV_HOME}/.bashrc"
BEGIN_MARK='# >>> claude dev box >>>'
END_MARK='# <<< claude dev box <<<'
touch "$BASHRC"
TMP_BASHRC="$(mktemp)"
# Strip the managed block, and also the unmarked block that earlier versions of
# the provisioner appended, so an update does not leave two of them behind.
awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  $0 == b { skip = 1; next }
  $0 == e { skip = 0; next }
  skip    { next }
  $0 == "# --- claude dev box ---" { legacy = 1; next }
  legacy && $0 == "fi" { legacy = 0; next }
  legacy  { next }
  { print }
' "$BASHRC" > "$TMP_BASHRC"
# Collapse any trailing blank lines the removal left behind.
printf '%s\n' "$(cat "$TMP_BASHRC")" > "$TMP_BASHRC.trimmed"
{
  cat "$TMP_BASHRC.trimmed"
  cat <<EOF

${BEGIN_MARK}
alias ca='claude-attach'
alias ci='claude-instance'
if [ -z "\${TMUX:-}" ] && [ -n "\${SSH_TTY:-}" ]; then
  echo "Claude Remote Control instances:  claude-instance list   (alias: ci)"
  echo "Attach to one:                    ca <instance>"
fi
${END_MARK}
EOF
} > "$BASHRC"
rm -f "$TMP_BASHRC" "$TMP_BASHRC.trimmed"
chown "$DEV_USER:$DEV_USER" "$BASHRC"

if [ "$RESTART" -eq 1 ]; then
  say "Restarting instances"
  # PartOf propagates a try-restart, so instances you deliberately stopped stay
  # stopped and only the running ones pick up the new code.
  systemctl restart claude-remote.target \
    || echo "WARNING: restarting claude-remote.target returned non-zero"
fi

echo
echo "RUNTIME_INSTALL_OK"
