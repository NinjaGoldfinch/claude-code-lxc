#!/usr/bin/env bash
#
# claude-lxc-runtime.sh
#
# Installs or refreshes the Claude Code Remote Control *runtime* inside the
# container: the claude-instance CLI, the claude-update helper, the supervised
# server wrapper and its preflight, the systemd template unit and target, the
# PATH snippet and the shell aliases.
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
#   * ~/.claude.json, beyond the two one-time prompt flags claude-rc-preflight
#     answers when an instance starts
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
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
ENV_CTID="${CTID:-}"
[ -r "$CONF" ] && . "$CONF"
DEV_USER="${ENV_DEV_USER:-${DEV_USER:-}}"
WORKSPACE_ROOT="${ENV_WORKSPACE_ROOT:-${WORKSPACE_ROOT:-}}"
CT_HOSTNAME="${ENV_CT_HOSTNAME:-${CT_HOSTNAME:-}}"
# Only the Proxmox host knows the CTID, so it is passed in at provision and
# update time. Blank on a box not updated since this was added, which costs the
# reset confirmation nothing but its nicest prompt.
CTID="${ENV_CTID:-${CTID:-}}"
case "$CTID" in
  ''|*[!0-9]*) CTID="" ;;
esac

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
CTID='${CTID}'
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

# Two one-time prompts would otherwise block a headless instance forever: the
# workspace-trust dialog, and Remote Control's own "Enable Remote Control?".
# Both are recorded in ~/.claude.json, so answer them there before starting.
# Instances come up together at boot, hence the lock; the edit is skipped
# entirely once the flags are set, which is the case from the second boot on.
cat > /usr/local/bin/claude-rc-preflight <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

WS="${1:-}"
[ -n "$WS" ] || { echo "usage: claude-rc-preflight <workspace>" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "preflight: no python3; skipping" >&2; exit 0; }

CFG="${HOME}/.claude.json"
exec 9>"${HOME}/.claude-rc-preflight.lock" || exit 0
flock -w 30 9 || { echo "preflight: could not take the lock; skipping" >&2; exit 0; }

python3 - "$CFG" "$WS" <<'PY'
import json, os, stat, sys, tempfile

cfg, ws = sys.argv[1], sys.argv[2]
try:
    with open(cfg) as fh:
        data = json.load(fh)
    mode = stat.S_IMODE(os.stat(cfg).st_mode)
except FileNotFoundError:
    data, mode = {}, 0o600
except (OSError, ValueError) as exc:
    # A config we cannot parse is not ours to rewrite.
    sys.exit("preflight: leaving %s alone (%s)" % (cfg, exc))

if not isinstance(data, dict):
    sys.exit(0)
projects = data.get("projects")
if projects is None:
    projects = data["projects"] = {}
if not isinstance(projects, dict):
    sys.exit(0)
entry = projects.get(ws)
if not isinstance(entry, dict):
    entry = {}

changed = []
if data.get("remoteDialogSeen") is not True:
    data["remoteDialogSeen"] = True
    changed.append("accepted Remote Control")
if entry.get("hasTrustDialogAccepted") is not True:
    entry["hasTrustDialogAccepted"] = True
    projects[ws] = entry
    changed.append("trusted %s" % ws)
if not changed:
    sys.exit(0)

# Replace atomically: claude rewrites this file constantly, and a half-written
# one costs the login.
directory = os.path.dirname(cfg) or "."
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".claude.json.")
try:
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=2)
    os.chmod(tmp, mode)
    os.replace(tmp, cfg)
except BaseException:
    os.unlink(tmp)
    raise
print("preflight: " + ", ".join(changed))
PY
EOF
chmod 755 /usr/local/bin/claude-rc-preflight

# The supervised loop, one process per instance. Each instance is a Remote
# Control *server*: claude.ai/code and the Claude apps show it under Remote
# Control as a machine you can open new sessions on, and it serves up to
# CAPACITY of them at once rather than the single fixed session the older
# `claude --remote-control` flag gives you. Remote Control makes outbound HTTPS
# only, so nothing needs to be exposed. It requires a claude.ai login
# (Pro/Max/Team/Enterprise); an API key will not work, and ANTHROPIC_BASE_URL
# must stay unset. Every setting it needs comes from the registry file, so this
# script needs nothing expanded into it at provision time.
cat > /usr/local/bin/claude-remote-session <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

# Server mode arrived in 2.1.200. Older builds know only the single-session
# --remote-control flag, so fall back instead of crash-looping on an unknown
# subcommand.
RC_MIN_VERSION=2.1.200

INSTANCE="${1:-}"
[ -n "$INSTANCE" ] || { echo "usage: claude-remote-session <instance>" >&2; exit 2; }
REG="/etc/claude-instances/${INSTANCE}.env"
[ -r "$REG" ] || { echo "no such instance: ${INSTANCE} (expected ${REG})" >&2; exit 2; }
# Defaults first: registry files written before these settings existed set none
# of them, and an update must not break those instances.
SPAWN_MODE=same-dir
CAPACITY=""
PERMISSION_MODE=""
# shellcheck source=/dev/null
. "$REG"

cd "$WORKSPACE" || { echo "workspace ${WORKSPACE} is gone" >&2; exit 1; }

# Each of these silently breaks Remote Control, so clear them defensively:
# an API key cannot establish a session, a gateway base URL cannot reach it,
# and the telemetry opt-outs disable the feature-flag lookup it depends on.
unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL DISABLE_TELEMETRY DO_NOT_TRACK \
      DISABLE_GROWTHBOOK CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

version_at_least() {  # version_at_least <have> <want>
  [ -n "$1" ] || return 1
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

build_args() {
  local ver spawn
  ver="$(claude --version 2>/dev/null | awk '{print $1}')"
  if ! version_at_least "$ver" "$RC_MIN_VERSION"; then
    echo "claude ${ver:-?} predates ${RC_MIN_VERSION} and has no server mode."
    echo "Serving one fixed session instead. Update with:  claude-update"
    ARGS=(--remote-control "$SESSION_NAME")
    return
  fi
  # Worktree spawning needs a git repository. An empty workspace is normal on a
  # fresh box, so serve it from the directory itself until it is a repo, and
  # re-check on every restart of the loop.
  spawn="$SPAWN_MODE"
  if [ "$spawn" = worktree ] \
     && ! git -C "$WORKSPACE" rev-parse --git-dir >/dev/null 2>&1; then
    echo "spawn mode 'worktree' needs a git repo; ${WORKSPACE} is not one yet — using same-dir"
    spawn=same-dir
  fi
  # --spawn is always passed: without it, a server started in a git repo stops
  # to ask which mode to use, and nobody is here to answer.
  ARGS=(remote-control --name "$SESSION_NAME" --spawn "$spawn")
  # --capacity is rejected alongside --spawn=session, which serves exactly one.
  if [ "$spawn" != session ] && [ -n "$CAPACITY" ]; then
    ARGS+=(--capacity "$CAPACITY")
  fi
  if [ -n "$PERMISSION_MODE" ]; then
    ARGS+=(--permission-mode "$PERMISSION_MODE")
  fi
}

while true; do
  if ! command -v claude >/dev/null 2>&1; then
    echo "claude not on PATH; retrying in 30s"; sleep 30; continue
  fi
  claude-rc-preflight "$WORKSPACE" || true
  build_args
  echo "starting: claude ${ARGS[*]}   (workspace ${WORKSPACE})"
  claude "${ARGS[@]}"
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
CTID='${CTID}'
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

# How the server creates the sessions you open from claude.ai/code:
#   same-dir  every session works in the instance workspace (claude's default)
#   worktree  each on-demand session gets its own git worktree — no two
#             sessions editing the same file, needs the workspace to be a repo
#   session   the old behaviour: exactly one session, further ones refused
SPAWN_MODES='same-dir worktree session'
valid_spawn() {
  case " $SPAWN_MODES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Rejected at startup by claude itself, which would leave the instance
# crash-looping, so check it here where the error is readable.
PERMISSION_MODES='acceptEdits auto bypassPermissions default dontAsk manual plan'
valid_permission_mode() {
  case " $PERMISSION_MODES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

valid_capacity() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 999 ]
}

# Registry files are sourced by shell, and the values are single-quoted in
# them, so a quote of their own would break out.
no_quotes() {
  case "$1" in *\'*) return 1 ;; esac
  return 0
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

# Defaults cover registry files written before server mode existed: an updated
# box keeps its instances, they simply gain claude's own defaults.
load() {
  local f; f="$(regf "$1")"
  [ -r "$f" ] || die "no such instance: $1  (try: claude-instance list)"
  INSTANCE=""; WORKSPACE=""; SESSION_NAME=""
  SPAWN_MODE="same-dir"; CAPACITY=""; PERMISSION_MODE=""
  # shellcheck source=/dev/null
  . "$f"
}

# The one place a registry file is written, so add and set cannot drift.
write_reg() {  # write_reg <name> <workspace> <session> <spawn> <capacity> <permission>
  ( umask 022
    cat > "$(regf "$1")" <<REG
INSTANCE='$1'
WORKSPACE='$2'
SESSION_NAME='$3'
SPAWN_MODE='$4'
CAPACITY='$5'
PERMISSION_MODE='$6'
REG
  )
}

# Derived rather than stored, so renaming the box changes it everywhere at once.
default_session_name() {
  # A box named after its project would otherwise read
  # "ninja-recorder-dev-container-ninja-recorder" in the picker, so drop the
  # repetition when the hostname already leads with the instance name.
  # Hostnames fold underscores to hyphens, so compare the folded form.
  local name_dns="${1//_/-}"
  case "$CT_HOSTNAME" in
    "$name_dns"|"$name_dns"-*) printf '%s\n' "$CT_HOSTNAME" ;;
    *)                         printf '%s\n' "${CT_HOSTNAME}-${1}" ;;
  esac
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
  local n state enabled tmux_state fmt
  fmt='%-14s %-24s %-28s %-9s %-4s %-8s %-8s %s\n'
  # shellcheck disable=SC2059
  printf "$fmt" NAME SESSION WORKSPACE SPAWN CAP ACTIVE ENABLED TMUX
  for n in $(names); do
    load "$n"
    state="$(systemctl is-active "$(unit "$n")" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$(unit "$n")" 2>/dev/null || true)"
    if as_dev tmux has-session -t "$(tmuxs "$n")" 2>/dev/null; then
      tmux_state=up
    else
      tmux_state=down
    fi
    # shellcheck disable=SC2059
    printf "$fmt" "$n" "$SESSION_NAME" "$WORKSPACE" "$SPAWN_MODE" \
      "${CAPACITY:-32}" "${state:-unknown}" "${enabled:-unknown}" "$tmux_state"
  done
}

cmd_add() {
  need_root add "$@"
  local name="" ws="" session="" spawn="same-dir" capacity="" permission="" start=1 other
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace)       ws="${2:-}";         shift 2 ;;
      --session-name)    session="${2:-}";    shift 2 ;;
      --spawn)           spawn="${2:-}";      shift 2 ;;
      --capacity)        capacity="${2:-}";   shift 2 ;;
      --permission-mode) permission="${2:-}"; shift 2 ;;
      --no-start)        start=0;             shift ;;
      -*)                die "unknown option for add: $1" ;;
      *)                 [ -z "$name" ] || die "add takes one name"; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || die "usage: claude-instance add <name> [--workspace PATH] [--session-name NAME] [--spawn MODE] [--capacity N] [--permission-mode MODE] [--no-start]"
  valid_name "$name" || die "invalid instance name '$name' — use [a-z0-9][a-z0-9_-]{0,30}"
  [ -e "$(regf "$name")" ] && die "instance '$name' already exists"

  [ -n "$ws" ] || ws="${WORKSPACE_ROOT}/${name}"
  check_workspace "$ws"
  ws="${ws%/}"
  for other in $(names); do
    load "$other"
    [ "$WORKSPACE" = "$ws" ] && die "instance '$other' already uses workspace ${ws} — each instance needs its own"
  done
  [ -n "$session" ] || session="$(default_session_name "$name")"
  no_quotes "$session" || die "session name must not contain a single quote"
  valid_spawn "$spawn" || die "invalid spawn mode '$spawn' — one of: ${SPAWN_MODES}"
  [ -z "$capacity" ] || valid_capacity "$capacity" || die "capacity must be a whole number from 1 to 999"
  [ -z "$permission" ] || valid_permission_mode "$permission" \
    || die "invalid permission mode '$permission' — one of: ${PERMISSION_MODES}"

  install -d -m 755 -o "$DEV_USER" -g "$DEV_USER" "$ws"
  write_reg "$name" "$ws" "$session" "$spawn" "$capacity" "$permission"
  systemctl enable "$(unit "$name")" >/dev/null 2>&1 \
    || die "could not enable $(unit "$name")"
  if [ "$start" -eq 1 ]; then
    systemctl start "$(unit "$name")" || die "could not start $(unit "$name")"
    printf 'added and started %s  (session %s, workspace %s, spawn %s)\n' "$name" "$session" "$ws" "$spawn"
  else
    printf 'added %s  (session %s, workspace %s, spawn %s) — not started\n' "$name" "$session" "$ws" "$spawn"
  fi
}

# Change an instance in place. Everything here is a property of the server, so
# a change only reaches claude.ai once the instance restarts — which it does,
# unless you say otherwise.
cmd_set() {
  need_root set "$@"
  local name="" restart=1 other changed=0
  local ws="" session="" spawn="" capacity="" permission=""
  local set_ws=0 set_session=0 set_spawn=0 set_capacity=0 set_permission=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace)       ws="${2:-}";         set_ws=1;         shift 2 ;;
      --session-name)    session="${2:-}";    set_session=1;    shift 2 ;;
      --spawn)           spawn="${2:-}";      set_spawn=1;      shift 2 ;;
      --capacity)        capacity="${2:-}";   set_capacity=1;   shift 2 ;;
      --permission-mode) permission="${2:-}"; set_permission=1; shift 2 ;;
      --no-restart)      restart=0;           shift ;;
      -*)                die "unknown option for set: $1" ;;
      *)                 [ -z "$name" ] || die "set takes one name"; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || die "usage: claude-instance set <name> [--workspace PATH] [--session-name NAME] [--spawn MODE] [--capacity N] [--permission-mode MODE] [--no-restart]"
  load "$name"
  local cur_ws="$WORKSPACE" cur_session="$SESSION_NAME" cur_spawn="$SPAWN_MODE"
  local cur_capacity="$CAPACITY" cur_permission="$PERMISSION_MODE"

  if [ "$set_ws" -eq 1 ]; then
    check_workspace "$ws"
    ws="${ws%/}"
    for other in $(names); do
      [ "$other" = "$name" ] && continue
      load "$other"
      [ "$WORKSPACE" = "$ws" ] && die "instance '$other' already uses workspace ${ws} — each instance needs its own"
    done
    install -d -m 755 -o "$DEV_USER" -g "$DEV_USER" "$ws"
    [ "$ws" = "$cur_ws" ] || changed=1
    cur_ws="$ws"
  fi
  if [ "$set_session" -eq 1 ]; then
    [ -n "$session" ] || session="$(default_session_name "$name")"
    no_quotes "$session" || die "session name must not contain a single quote"
    [ "$session" = "$cur_session" ] || changed=1
    cur_session="$session"
  fi
  if [ "$set_spawn" -eq 1 ]; then
    valid_spawn "$spawn" || die "invalid spawn mode '$spawn' — one of: ${SPAWN_MODES}"
    [ "$spawn" = "$cur_spawn" ] || changed=1
    cur_spawn="$spawn"
  fi
  if [ "$set_capacity" -eq 1 ]; then
    valid_capacity "$capacity" || die "capacity must be a whole number from 1 to 999"
    [ "$capacity" = "$cur_capacity" ] || changed=1
    cur_capacity="$capacity"
  fi
  if [ "$set_permission" -eq 1 ]; then
    valid_permission_mode "$permission" \
      || die "invalid permission mode '$permission' — one of: ${PERMISSION_MODES}"
    [ "$permission" = "$cur_permission" ] || changed=1
    cur_permission="$permission"
  fi

  if [ "$changed" -eq 0 ]; then
    printf '%s is already like that — nothing to do\n' "$name"
    return 0
  fi
  write_reg "$name" "$cur_ws" "$cur_session" "$cur_spawn" "$cur_capacity" "$cur_permission"
  printf 'updated %s  (session %s, workspace %s, spawn %s, capacity %s, permissions %s)\n' \
    "$name" "$cur_session" "$cur_ws" "$cur_spawn" "${cur_capacity:-32}" "${cur_permission:-default}"

  if [ "$restart" -eq 1 ] && [ "$(systemctl is-active "$(unit "$name")" 2>/dev/null)" = active ]; then
    systemctl restart "$(unit "$name")" || die "systemctl restart failed for ${name}"
    printf 'restarted %s\n' "$name"
  elif [ "$restart" -eq 1 ]; then
    printf '%s is not running; the new settings apply when you start it\n' "$name"
  else
    printf 'not restarting; the new settings apply on the next restart of %s\n' "$name"
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

# The CLI is shared by every instance, so updating it is a box-level job.
cmd_update() {
  exec claude-update "$@"
}

# Put the box back to the state provisioning left it in: the same instances,
# empty workspaces, no claude.ai login. Everything you would otherwise have to
# redo *elsewhere* stays — the container, the users and their passwords, all
# three SSH keys, the GitHub registrations, gh auth and git config — so the only
# step afterwards is /login.
cmd_reset() {
  need_root reset "$@"
  local assume_yes=0 keep_ws=0 n reply dev_home stash label token first_ws=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes)          assume_yes=1; shift ;;
      --keep-workspaces) keep_ws=1;    shift ;;
      -*)                die "unknown option for reset: $1" ;;
      *)                 die "reset takes no instance name — it resets the whole box" ;;
    esac
  done

  dev_home="$(getent passwd "$DEV_USER" | cut -d: -f6)"
  [ -n "$dev_home" ] || die "could not resolve the home directory for ${DEV_USER}"

  local -a all=()
  mapfile -t all < <(names)

  # Vet every purge before touching anything: refusing one halfway through
  # would leave the box neither reset nor intact.
  if [ "$keep_ws" -eq 0 ]; then
    for n in "${all[@]}"; do
      load "$n"
      case "$WORKSPACE" in
        /|/home|/root|/home/"$DEV_USER"|"$WORKSPACE_ROOT")
          die "instance '${n}' works in ${WORKSPACE}, which is too close to the root to delete — rerun with --keep-workspaces" ;;
      esac
    done
  fi

  if [ -n "$CTID" ]; then
    label="CT ${CTID} (${CT_HOSTNAME})"; token="$CTID"
  else
    label="$CT_HOSTNAME"; token="$CT_HOSTNAME"
  fi

  printf '\nAbout to reset %s:\n\n' "$label"
  if [ "${#all[@]}" -eq 0 ]; then
    printf '  no instances are configured\n'
  else
    printf '  %s instance(s), stopped and left defined:\n' "${#all[@]}"
    for n in "${all[@]}"; do
      load "$n"
      [ -n "$first_ws" ] || first_ws="$WORKSPACE"
      if [ "$keep_ws" -eq 0 ]; then
        printf '    %-16s %s   (EMPTIED)\n' "$n" "$WORKSPACE"
      else
        printf '    %-16s %s   (kept)\n' "$n" "$WORKSPACE"
      fi
    done
  fi
  printf '\n  claude.ai login and Claude Code state   DELETED\n'
  printf '    %s/.claude, %s/.claude.json\n' "$dev_home" "$dev_home"
  printf '\n  kept: the container, %s and its password, every SSH key, the\n' "$DEV_USER"
  printf '        GitHub registrations, gh auth, git config, and\n'
  printf '        %s/.claude/settings.json\n\n' "$dev_home"

  if [ "$assume_yes" -eq 0 ]; then
    printf 'Type %s to confirm: ' "$token"
    read -r reply
    [ "$reply" = "$token" ] || die "aborted — nothing was touched"
  fi

  # 1. Stop everything. PartOf propagates the target's stop to the units, but
  # be explicit so a unit that drifted out of the target stops too.
  systemctl stop "$TARGET" >/dev/null 2>&1 || true
  for n in "${all[@]}"; do
    systemctl stop "$(unit "$n")" >/dev/null 2>&1 || true
    as_dev tmux kill-session -t "$(tmuxs "$n")" >/dev/null 2>&1 || true
  done
  printf 'stopped %s instance(s)\n' "${#all[@]}"

  # 2. Workspaces: recreated empty, owned by the dev user, exactly as add does.
  if [ "$keep_ws" -eq 0 ]; then
    for n in "${all[@]}"; do
      load "$n"
      rm -rf -- "$WORKSPACE"
      install -d -m 755 -o "$DEV_USER" -g "$DEV_USER" "$WORKSPACE"
      printf 'emptied %s\n' "$WORKSPACE"
    done
  fi

  # 3. Claude Code state, login included. settings.json is yours: provisioning
  # wrote it once and nothing has rewritten it since, so carry it across rather
  # than make you set your theme again.
  stash=""
  if [ -r "${dev_home}/.claude/settings.json" ]; then
    stash="$(mktemp)"
    cat "${dev_home}/.claude/settings.json" > "$stash"
  fi
  rm -rf -- "${dev_home}/.claude" "${dev_home}/.claude.json" \
            "${dev_home}/.claude.json.backup" "${dev_home}/.claude-rc-preflight.lock"
  install -d -m 700 -o "$DEV_USER" -g "$DEV_USER" "${dev_home}/.claude"
  if [ -n "$stash" ]; then
    install -m 600 -o "$DEV_USER" -g "$DEV_USER" "$stash" "${dev_home}/.claude/settings.json"
    rm -f "$stash"
    printf 'kept %s/.claude/settings.json\n' "$dev_home"
  fi
  printf 'deleted the claude.ai login and Claude Code state\n'

  cat <<DONE

${label} is reset. The instances are still defined and enabled; they are
stopped because nothing can connect until you sign in again:

  cd ${first_ws:-$WORKSPACE_ROOT} && claude    # then /login, Ctrl-C
  sudo systemctl start ${TARGET}
  ci list
DONE
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
claude-instance — manage Claude Code Remote Control servers on this box

  list                                     show every instance and its state
  add <name> [options]                     create an instance and start it
  set <name> [options]                     change one, then restart it
  remove <name> [--purge] [--yes]          stop, disable and forget an instance
  start|stop|restart <name>... | --all     lifecycle for one, several, or all
  update [--no-restart] [--to <target>]    update Claude Code, restart the fleet
  reset [--yes] [--keep-workspaces]        wipe the box back to just-provisioned
  attach [name]                            attach to the instance's tmux session
  logs <name> [-f]                         journal for the instance's unit

Options for add and set:

  --workspace PATH        where the sessions work (default ${WORKSPACE_ROOT}/<name>)
  --session-name NAME     name in the claude.ai/code picker (default
                          ${CT_HOSTNAME}-<name>, or just ${CT_HOSTNAME} when the
                          hostname already starts with <name>)
  --spawn MODE            how new sessions are created: ${SPAWN_MODES}
                          same-dir  all sessions share the workspace (default)
                          worktree  each new session gets its own git worktree
                          session   one session only, the old behaviour
  --capacity N            how many sessions may run at once (default 32)
  --permission-mode MODE  starting permission mode for the sessions it serves:
                          ${PERMISSION_MODES}
  --no-start / --no-restart   leave systemd alone

reset empties every workspace and deletes the claude.ai login, but keeps the
container, the users, the SSH keys, the GitHub registrations and git config, so
the only thing to redo afterwards is /login. It asks you to type the CTID first.

Each instance is a Remote Control *server*: open claude.ai/code or the Claude
app, pick it under Remote Control, and start as many sessions on it as you like.
All instances share one claude.ai login (~/.claude), so signing in once covers
them all. Each needs its own workspace. Whole fleet at once:

  sudo systemctl restart ${TARGET}
USAGE
}

case "${1:-}" in
  list|ls)            shift; cmd_list "$@" ;;
  add|create)         shift; cmd_add "$@" ;;
  set|config)         shift; cmd_set "$@" ;;
  remove|rm|delete)   shift; cmd_remove "$@" ;;
  start|stop|restart) action="$1"; shift; cmd_lifecycle "$action" "$@" ;;
  update|upgrade)     shift; cmd_update "$@" ;;
  reset)              shift; cmd_reset "$@" ;;
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

# --- claude-update: one CLI, one command -----------------------------------
# A running instance holds its binary open for as long as it lives, so updating
# Claude Code without restarting changes nothing until something else does.
# Doing both in one command is the whole point of this script.
cat > /usr/local/bin/claude-update <<EOF
#!/usr/bin/env bash
# Update Claude Code and restart the instances. Generated by claude-lxc-runtime.sh.
DEV_USER='${DEV_USER}'
EOF
cat >> /usr/local/bin/claude-update <<'EOF'
set -uo pipefail

TARGET=claude-remote.target
RESTART=1
INSTALL_TARGET=""

die() { printf 'claude-update: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-restart) RESTART=0; shift ;;
    --to)         INSTALL_TARGET="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<USAGE
claude-update — update Claude Code on this box and restart the instances

  claude-update                update to the newest build, then restart every
                               running Remote Control instance so it picks it up
  claude-update --no-restart   update only; each instance keeps the build it
                               started with until it next restarts
  claude-update --to <target>  install a named build instead: stable, latest,
                               or an exact version such as 2.1.280

Every instance runs the same binary under the same login, so this covers all of
them at once. Restarting is what makes a running instance switch over — it
drops the sessions it is serving, so do it when nothing is mid-turn.

Just the restart, no update:  sudo systemctl restart claude-remote.target
USAGE
      exit 0 ;;
    *) die "unknown argument: $1  (try --help)" ;;
  esac
done
[ "$INSTALL_TARGET" = "" ] || case "$INSTALL_TARGET" in
  stable|latest|[0-9]*) ;;
  *) die "--to takes stable, latest, or a version like 2.1.280" ;;
esac

# The CLI belongs to the dev user; systemd does not. Reach for each as needed
# rather than making the whole script root-only.
as_dev() {
  if [ "$(id -un)" = "$DEV_USER" ]; then "$@"; else sudo -u "$DEV_USER" -H -- "$@"; fi
}
as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -- "$@"; fi
}
# -l so the profile PATH snippet is what finds claude, wherever it is installed.
dev_claude() { as_dev bash -lc "$1"; }

version() { dev_claude 'command -v claude >/dev/null 2>&1 && claude --version' 2>/dev/null | awk '{print $1}'; }

before="$(version)"
[ -n "$before" ] || die "claude is not installed for ${DEV_USER} — sign in on the box first"
printf 'installed: %s\n' "$before"

if [ -n "$INSTALL_TARGET" ]; then
  dev_claude "claude install ${INSTALL_TARGET}" || die "claude install ${INSTALL_TARGET} failed"
else
  dev_claude 'claude update' || die "claude update failed"
fi

after="$(version)"
[ -n "$after" ] || die "claude is no longer runnable after the update — check ~/.local/share/claude"
if [ "$before" = "$after" ]; then
  printf 'still on %s\n' "$after"
else
  printf 'updated: %s -> %s\n' "$before" "$after"
fi

if [ "$RESTART" -eq 0 ]; then
  echo "not restarting; instances switch over on their next restart"
  exit 0
fi
as_root systemctl restart "$TARGET" || die "restarting ${TARGET} failed"
printf 'restarted %s — every running instance is on %s\n' "$TARGET" "$after"
EOF
chmod 755 /usr/local/bin/claude-update

say "systemd units"
# One template unit covers every instance. WorkingDirectory has to be a literal
# (systemd does not expand variables there), so the per-instance cd lives in
# claude-remote-session instead.
cat > /etc/systemd/system/claude-remote@.service <<EOF
[Unit]
Description=Claude Code Remote Control server (%i)
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
alias cu='claude-update'
alias cr='sudo systemctl restart claude-remote.target'
if [ -z "\${TMUX:-}" ] && [ -n "\${SSH_TTY:-}" ]; then
  echo "Claude Remote Control instances:  claude-instance list   (alias: ci)"
  echo "Attach to one:                    ca <instance>"
  echo "Update Claude Code + restart:     claude-update          (alias: cu)"
  echo "Restart the fleet:                cr"
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
