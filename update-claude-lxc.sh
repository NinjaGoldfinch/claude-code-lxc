#!/usr/bin/env bash
#
# update-claude-lxc.sh
#
# Refreshes the *code* on containers already provisioned by
# provision-claude-lxc.sh: the claude-instance CLI, the claude-update helper,
# the supervised server wrapper and its preflight, the systemd template unit and
# target, the PATH snippet and the shell aliases. It pushes
# claude-lxc-runtime.sh — the same file provisioning uses — and runs it inside
# each container, so the two can never drift apart.
#
# This is how an older box moves to Remote Control *server* mode: the registry
# keeps every instance exactly as it was, and each one gains claude's defaults
# for the settings that did not exist before (same-dir spawning, 32 sessions).
# It refreshes the runtime, not Claude Code itself — for that, run
# `claude-update` on the box.
#
# It does not touch anything you would have to re-do afterwards:
#   * no passwords are generated or changed
#   * no SSH keys are created, replaced or re-registered with GitHub
#   * ~/.claude is untouched, so your claude.ai login survives
#   * git config, allowed_signers and the gh auth state are left alone
#   * /etc/claude-instances/*.env is left alone, so your instances and their
#     workspaces come back exactly as they were
#   * ~/.claude/settings.json and ~/.tmux.conf are yours after provisioning and
#     are never rewritten
#
# To wipe a box back to just-provisioned instead — empty workspaces, no
# claude.ai login, everything else intact — use reset-claude-lxc.sh.
#
# RUN THIS ON THE PROXMOX HOST, AS ROOT.
#
#   ./update-claude-lxc.sh <CTID> [CTID...]
#
# Options:
#   --no-restart   install the new code but leave running instances on the old
#                  code until they are next restarted
#
set -Eeuo pipefail

RUNTIME_SRC="${RUNTIME_SRC:-}"
RUNTIME_URL="${RUNTIME_URL:-https://raw.githubusercontent.com/NinjaGoldfinch/claude-code-lxc/main/claude-lxc-runtime.sh}"

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_OK" "$C_0" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_WARN" "$C_0" "$*" >&2; }
die()  { printf '%s fail%s %s\n' "$C_ERR" "$C_0" "$*" >&2; exit 1; }

trap 'die "aborted at line $LINENO"' ERR

RESTART=1
CTIDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-restart) RESTART=0; shift ;;
    -h|--help)    sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           die "unknown option: $1" ;;
    *)            CTIDS+=("$1"); shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

log "Preflight checks"
[ "$(id -u)" -eq 0 ] || die "run this as root on the Proxmox host"
command -v pct >/dev/null 2>&1 || die "required command not found: pct"
[ "${#CTIDS[@]}" -gt 0 ] || die "usage: $0 <CTID> [CTID...] [--no-restart]"

for ctid in "${CTIDS[@]}"; do
  case "$ctid" in
    ''|*[!0-9]*) die "'${ctid}' is not a container ID" ;;
  esac
  pct status "$ctid" >/dev/null 2>&1 || die "container ${ctid} does not exist"
  [ "$(pct status "$ctid")" = "status: running" ] \
    || die "container ${ctid} is not running — start it with: pct start ${ctid}"
done

# Same resolution order as the provisioner: local copy, then the published one.
if [ -z "$RUNTIME_SRC" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [ -n "$SELF_DIR" ] && [ -r "${SELF_DIR}/claude-lxc-runtime.sh" ]; then
    RUNTIME_SRC="${SELF_DIR}/claude-lxc-runtime.sh"
    ok "runtime installer: ${RUNTIME_SRC}"
  else
    command -v curl >/dev/null 2>&1 || die "required command not found: curl"
    RUNTIME_SRC="$(mktemp)"
    curl -fL --retry 3 -o "$RUNTIME_SRC" "$RUNTIME_URL" \
      || die "could not fetch the runtime installer from ${RUNTIME_URL} — clone the repo or set RUNTIME_SRC"
    ok "runtime installer: fetched from ${RUNTIME_URL}"
  fi
else
  [ -r "$RUNTIME_SRC" ] || die "RUNTIME_SRC is not readable: ${RUNTIME_SRC}"
fi
bash -n "$RUNTIME_SRC" || die "the runtime installer at ${RUNTIME_SRC} is not valid bash"

# ---------------------------------------------------------------------------
# Update each container
# ---------------------------------------------------------------------------

FAILED=()
for ctid in "${CTIDS[@]}"; do
  log "Updating container ${ctid}"

  # Refuse anything that is not one of ours rather than scattering files into it.
  pct exec "$ctid" -- test -x /usr/local/bin/claude-instance >/dev/null 2>&1 \
    || die "container ${ctid} has no /usr/local/bin/claude-instance — it was not provisioned by provision-claude-lxc.sh"

  # Boxes built before /etc/claude-lxc.conf existed still carry their settings
  # in the generated CLI's prelude, so recover them from there.
  ENV_ARGS=""
  if ! pct exec "$ctid" -- test -r /etc/claude-lxc.conf >/dev/null 2>&1; then
    warn "no /etc/claude-lxc.conf — recovering settings from the installed claude-instance"
    for var in DEV_USER WORKSPACE_ROOT CT_HOSTNAME; do
      val="$(pct exec "$ctid" -- bash -c \
        "sed -n \"s/^${var}='\\(.*\\)'\$/\\1/p\" /usr/local/bin/claude-instance | head -1" 2>/dev/null || true)"
      [ -n "$val" ] || die "could not recover ${var} from container ${ctid} — set it in the environment and retry"
      ENV_ARGS="${ENV_ARGS}${var}='${val}' "
      ok "recovered ${var}=${val}"
    done
  fi
  # An explicit override in the environment wins over both sources.
  for var in DEV_USER WORKSPACE_ROOT CT_HOSTNAME; do
    if [ -n "${!var:-}" ]; then ENV_ARGS="${ENV_ARGS}${var}='${!var}' "; fi
  done
  # Only the host knows the CTID, and here it is the argument we were given.
  # Boxes provisioned before it was recorded pick it up on their first update.
  ENV_ARGS="${ENV_ARGS}CTID='${ctid}' "

  BEFORE="$(pct exec "$ctid" -- /usr/local/bin/claude-instance list 2>/dev/null || true)"

  pct push "$ctid" "$RUNTIME_SRC" /root/claude-lxc-runtime.sh --perms 0700
  RESTART_FLAG=""
  [ "$RESTART" -eq 1 ] && RESTART_FLAG="--restart"
  if pct exec "$ctid" -- bash -c "${ENV_ARGS}/root/claude-lxc-runtime.sh ${RESTART_FLAG}"; then
    ok "runtime refreshed on ${ctid}"
  else
    warn "runtime install failed on ${ctid}"
    FAILED+=("$ctid")
  fi
  pct exec "$ctid" -- rm -f /root/claude-lxc-runtime.sh >/dev/null 2>&1 || true

  AFTER="$(pct exec "$ctid" -- /usr/local/bin/claude-instance list 2>/dev/null || true)"
  if [ "$BEFORE" = "$AFTER" ]; then
    ok "instances unchanged"
  else
    warn "instance state changed during the update:"
    printf 'before:\n%s\n\nafter:\n%s\n' "$BEFORE" "$AFTER" >&2
  fi
  printf '%s\n' "$AFTER"
done

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

if [ "${#FAILED[@]}" -gt 0 ]; then
  die "failed on: ${FAILED[*]}"
fi

cat <<EOF

${C_OK}${C_B}Updated ${#CTIDS[@]} container(s): ${CTIDS[*]}${C_0}

Code only. Passwords, SSH keys, the claude.ai login, git config, gh auth and
the instance registry were not touched — nothing to re-do.
EOF
if [ "$RESTART" -eq 1 ]; then
  cat <<'EOF'
Running instances were restarted onto the new code; ones you had stopped stayed
stopped. Attach with:  ca <instance>
EOF
else
  cat <<'EOF'
--no-restart was given, so running instances are still on the old code. Apply it
with:  sudo systemctl restart claude-remote.target
EOF
fi
