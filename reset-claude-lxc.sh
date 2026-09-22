#!/usr/bin/env bash
#
# reset-claude-lxc.sh
#
# Wipes a container provisioned by provision-claude-lxc.sh back to the state
# provisioning left it in — without destroying it. Every instance is stopped and
# its workspace emptied, and the claude.ai login and the rest of Claude Code's
# state are deleted. The instances stay defined, so the box comes back with the
# same names, workspaces and spawn settings.
#
# It keeps everything you would otherwise have to redo somewhere else:
#   * the container itself, its ID, hostname, network and resources
#   * the root and dev passwords
#   * all three SSH keys — so the GitHub registrations keep working
#   * gh auth, git config and allowed_signers
#   * ~/.claude/settings.json
#
# The only step afterwards is signing in again with /login.
#
# The work is done by `claude-instance reset` inside the container; this script
# finds the box, shows you what it is about to destroy and asks you to type the
# CTID back. Containers whose runtime predates `reset` are told to update first.
#
# RUN THIS ON THE PROXMOX HOST, AS ROOT.
#
#   ./reset-claude-lxc.sh <CTID> [CTID...]
#
# Options:
#   --keep-workspaces  wipe Claude Code's state but leave the files in the
#                      workspaces alone
#   --yes              skip the typed confirmation, which is otherwise asked
#                      once per container
#
set -Eeuo pipefail

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_OK" "$C_0" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_WARN" "$C_0" "$*" >&2; }
die()  { printf '%s fail%s %s\n' "$C_ERR" "$C_0" "$*" >&2; exit 1; }

trap 'die "aborted at line $LINENO"' ERR

ASSUME_YES=0
KEEP_WS=0
CTIDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-workspaces) KEEP_WS=1; shift ;;
    -y|--yes)          ASSUME_YES=1; shift ;;
    -h|--help)         sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)                die "unknown option: $1" ;;
    *)                 CTIDS+=("$1"); shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

log "Preflight checks"
[ "$(id -u)" -eq 0 ] || die "run this as root on the Proxmox host"
command -v pct >/dev/null 2>&1 || die "required command not found: pct"
[ "${#CTIDS[@]}" -gt 0 ] || die "usage: $0 <CTID> [CTID...] [--keep-workspaces] [--yes]"

for ctid in "${CTIDS[@]}"; do
  case "$ctid" in
    ''|*[!0-9]*) die "'${ctid}' is not a container ID" ;;
  esac
  pct status "$ctid" >/dev/null 2>&1 || die "container ${ctid} does not exist"
  [ "$(pct status "$ctid")" = "status: running" ] \
    || die "container ${ctid} is not running — start it with: pct start ${ctid}"

  # Refuse anything that is not one of ours rather than running commands in it.
  pct exec "$ctid" -- test -x /usr/local/bin/claude-instance >/dev/null 2>&1 \
    || die "container ${ctid} has no /usr/local/bin/claude-instance — it was not provisioned by provision-claude-lxc.sh"
  pct exec "$ctid" -- grep -q '^cmd_reset()' /usr/local/bin/claude-instance >/dev/null 2>&1 \
    || die "container ${ctid} has an older runtime with no reset — refresh it first with: ./update-claude-lxc.sh ${ctid}"
done
ok "${#CTIDS[@]} container(s) ready"

# ---------------------------------------------------------------------------
# Reset each container
# ---------------------------------------------------------------------------

# Read one single-quoted value out of the box's config, e.g. conf_value 250 DEV_USER
conf_value() {
  pct exec "$1" -- bash -c \
    "sed -n \"s/^${2}='\\(.*\\)'\$/\\1/p\" /etc/claude-lxc.conf 2>/dev/null | head -1" 2>/dev/null || true
}

RESET=()
SKIPPED=()
FAILED=()
for ctid in "${CTIDS[@]}"; do
  hostname="$(pct config "$ctid" 2>/dev/null | sed -n 's/^hostname: //p')"
  [ -n "$hostname" ] || hostname="<unknown>"
  instances="$(pct exec "$ctid" -- /usr/local/bin/claude-instance list 2>/dev/null || true)"

  log "Resetting container ${ctid} (${hostname})"
  printf '%s\n' "$instances"
  if [ "$KEEP_WS" -eq 1 ]; then
    printf '\n%sThe workspaces above keep their files. Everything else Claude Code\n' "$C_B"
    printf 'holds on this box — the claude.ai login included — is deleted.%s\n\n' "$C_0"
  else
    printf '\n%sEvery workspace above is emptied, and the claude.ai login and the\n' "$C_B"
    printf 'rest of Claude Code'"'"'s state are deleted. The container, its users,\n'
    printf 'passwords, SSH keys, gh auth and git config are kept.%s\n\n' "$C_0"
  fi

  if [ "$ASSUME_YES" -eq 0 ]; then
    printf 'Type %s to reset it, anything else to skip: ' "$ctid"
    read -r reply
    if [ "$reply" != "$ctid" ]; then
      warn "skipped ${ctid} — nothing was touched"
      SKIPPED+=("$ctid")
      continue
    fi
  fi

  GUEST_ARGS=(--yes)
  [ "$KEEP_WS" -eq 1 ] && GUEST_ARGS+=(--keep-workspaces)
  if pct exec "$ctid" -- /usr/local/bin/claude-instance reset "${GUEST_ARGS[@]}"; then
    ok "reset ${ctid}"
    RESET+=("$ctid")
  else
    warn "reset failed on ${ctid}"
    FAILED+=("$ctid")
  fi
done

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

[ "${#FAILED[@]}" -eq 0 ] || die "failed on: ${FAILED[*]}"

if [ "${#RESET[@]}" -eq 0 ]; then
  cat <<EOF

${C_WARN}${C_B}Nothing was reset.${C_0} Skipped: ${SKIPPED[*]:-none}
EOF
  exit 0
fi

# Everything below is per-box, so print the sign-in steps for each one.
cat <<EOF

${C_OK}${C_B}Reset ${#RESET[@]} container(s): ${RESET[*]}${C_0}

The claude.ai login is gone; the containers, their users, passwords, SSH keys,
GitHub registrations, gh auth and git config are not. Sign in again on each box
and start the fleet:
EOF
for ctid in "${RESET[@]}"; do
  dev_user="$(conf_value "$ctid" DEV_USER)"; dev_user="${dev_user:-dev}"
  ws_root="$(conf_value "$ctid" WORKSPACE_ROOT)"; ws_root="${ws_root:-/home/${dev_user}/projects}"
  first_ws="$(pct exec "$ctid" -- bash -c \
    'for f in /etc/claude-instances/*.env; do ( . "$f"; printf "%s\n" "$WORKSPACE" ); done | head -1' 2>/dev/null || true)"
  [ -n "$first_ws" ] || first_ws="${ws_root}/<instance>"
  addr="$(pct exec "$ctid" -- bash -c "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null || true)"
  [ -n "$addr" ] || addr="<container-ip>"
  cat <<EOF

  ${C_B}CT ${ctid}${C_0}
    ssh ${dev_user}@${addr}          # or: pct console ${ctid}
    cd ${first_ws} && claude      # run /login, then Ctrl-C
    sudo systemctl start claude-remote.target
    ci list
EOF
done
