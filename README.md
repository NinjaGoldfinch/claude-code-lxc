# claude-code-lxc

One script that turns a Proxmox VE host into a Debian 13 (trixie) LXC container
running [Claude Code](https://code.claude.com/docs) in Remote Control server
mode, so you can drive a real dev box from claude.ai/code or the Claude mobile
app.

It generates every credential randomly and hands them back in a format you can
paste straight into a password manager and into GitHub.

## Quick start

Run this on the **Proxmox host**, as root:

```bash
curl -fsSL -o provision-claude-lxc.sh \
  https://raw.githubusercontent.com/YOURUSER/claude-code-lxc/main/provision-claude-lxc.sh
chmod +x provision-claude-lxc.sh
GIT_EMAIL=you@example.com ./provision-claude-lxc.sh
```

Read it before you run it. If you would rather not, the one-liner is:

```bash
GIT_EMAIL=you@example.com bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOURUSER/claude-code-lxc/main/provision-claude-lxc.sh)"
```

If the repo is private, `raw.githubusercontent.com` needs auth. Use
`gh repo clone YOURUSER/claude-code-lxc` on the host instead, or add
`-H "Authorization: Bearer $GITHUB_TOKEN"` to the curl.

## What you get

- An unprivileged LXC on Debian trixie, `onboot=1`, `nesting=1,keyctl=1`, 4 GB
  RAM by default (Claude Code's documented minimum).
- The rootfs image checksum-verified against the `SHA256SUMS` published next to
  it before `pct create` runs.
- A random root password and a random password for the `dev` user, for console
  and `sudo`.
- Three ed25519 keypairs: SSH login, GitHub authentication, GitHub commit
  signing. Kept separate on purpose.
- sshd locked to public key only, with `ssh.socket` disabled so the `Port`
  directive in `sshd_config` is actually honoured (Debian 13 defaults to socket
  activation, which silently ignores it).
- Git preconfigured for SSH commit signing: `gpg.format=ssh`,
  `commit.gpgsign=true`, `tag.gpgsign=true`, and an `allowed_signers` file so
  `git log --show-signature` verifies locally too.
- The GitHub CLI (`gh`), installed from GitHub's signed apt repo. If you pass
  a `GH_TOKEN`, the script runs `gh auth login --with-token`, `gh auth
  setup-git` (so `https://` git operations also authenticate via `gh`), and
  registers both generated SSH keys with GitHub — the authentication key with
  `gh ssh-key add --type authentication`, the signing key with `--type
  signing`. No token, no problem: `gh` is still installed, and the printed
  instructions cover doing the same three steps interactively after your
  first SSH login.
- GitHub's ed25519 host key fingerprint pinned at provision time rather than
  trusting whatever `ssh-keyscan` returns.
- Claude Code installed via the native installer (auto-updating), falling back
  to the signed apt repository with a fingerprint check.
- `claude-remote.service`: a systemd unit that runs `claude remote-control`
  inside a supervised tmux loop, so it comes back after a reboot or a crash.
- Node.js 22, build-essential, Python 3, ripgrep, fd, jq, tmux, and the rest of
  the usual toolchain.
- A credentials bundle at `/root/claude-lxc-<CTID>/CREDENTIALS.txt` on the host,
  laid out as ready-to-file password manager entries.

## One manual step

Remote Control requires a claude.ai login on a Pro, Max, Team, or Enterprise
plan. An API key will not work. OAuth cannot open a browser inside a headless
container, so it prints a URL and takes a code back. After the script finishes:

```bash
ssh -i /root/claude-lxc-<CTID>/id_ed25519_claude-dev dev@<container-ip>
cd ~/projects && claude          # accept workspace trust, then /login
# Ctrl-C once you are signed in
sudo systemctl restart claude-remote
ca                               # attach to tmux; session URL and QR code are here
```

Then open [claude.ai/code](https://claude.ai/code) or the Claude mobile app and
pick the session by name.

If you did not pass `GH_TOKEN`, there's a second manual step for GitHub itself
— from the same SSH session:

```bash
gh auth login --git-protocol ssh --hostname github.com
gh ssh-key add ~/.ssh/id_ed25519_github_auth.pub --type authentication --title "dev box auth"
gh ssh-key add ~/.ssh/id_ed25519_github_signing.pub --type signing --title "dev box signing"
```

`gh auth login` without `--with-token` walks you through a device-code flow:
it prints a URL and a one-time code to enter on any browser, no token needed.

## Configuration

Everything is an environment variable. Defaults in parentheses.

| Variable | What it does |
| --- | --- |
| `CTID` | Container ID (next free) |
| `CT_HOSTNAME` | Hostname (`claude-dev`) |
| `CORES` / `MEMORY` / `SWAP` / `DISK_GB` | Resources (`4` / `4096` / `2048` / `32`) |
| `ROOTFS_STORAGE` | Storage for the container disk (`local-lvm`) |
| `BRIDGE` / `CT_IP` / `CT_GW` / `CT_VLAN` | Networking (`vmbr0` / `dhcp`) |
| `NAMESERVER` | Resolvers (`1.1.1.1 9.9.9.9`) |
| `ROOTFS_URL` | linuxcontainers.org rootfs to use |
| `DEV_USER` / `WORKSPACE` / `SSH_PORT` | Guest user, project dir, sshd port |
| `GIT_NAME` / `GIT_EMAIL` | Git identity and `allowed_signers` entry |
| `GH_TOKEN` | GitHub token for non-interactive `gh auth login` + automatic key registration (blank = do it interactively later) |
| `INSTALL_NODE` | Install Node.js 22 (`1`) |
| `CLAUDE_CHANNEL` | `latest` or `stable` |
| `ALLOW_UNVERIFIED_GITHUB_HOSTKEY` | Continue past a GitHub host key mismatch (`0`) |

Example:

```bash
CTID=250 MEMORY=8192 DISK_GB=64 CT_IP=192.168.1.50/24 CT_GW=192.168.1.1 \
GIT_EMAIL=you@example.com ./provision-claude-lxc.sh
```

## Gotchas worth knowing

These will break Remote Control quietly rather than loudly:

- Do not set `ANTHROPIC_BASE_URL` or route through an LLM gateway. Remote
  Control only works when talking to `api.anthropic.com` directly.
- Do not set `DISABLE_TELEMETRY`, `DO_NOT_TRACK`, `DISABLE_GROWTHBOOK`, or
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`. Each one disables the feature flag
  evaluation that Remote Control availability depends on.
- Do not set `ANTHROPIC_API_KEY`. API key auth cannot establish a Remote Control
  session.
- Tokens from `claude setup-token` / `CLAUDE_CODE_OAUTH_TOKEN` are model-request
  only and will not work either. Use `claude auth login`.

The wrapper script unsets all of these defensively before starting the session.

## Day to day

```bash
ca                                        # attach to the running session
sudo systemctl status claude-remote
sudo systemctl restart claude-remote
journalctl -u claude-remote
pct console <CTID>                        # console from the Proxmox host
```

## Security notes

- Password authentication over SSH is off. The generated passwords are for the
  Proxmox console and for `sudo`.
- The private keys are copied to the Proxmox host only so you can file them in a
  password manager. Delete `/root/claude-lxc-<CTID>/` once they are stored.
- The container is unprivileged. `nesting=1` is set because Claude Code's
  sandboxing and some container tooling need user namespaces.
- `GH_TOKEN`, like the root/dev passwords, is pushed to the guest only inside
  `/root/provision.env` (mode 0600) and shredded once provisioning finishes.
  It is never passed on argv, so it won't show up in `ps`. Use a short-lived
  token scoped to just `admin:public_key` (classic) or SSH key read/write
  (fine-grained), and revoke it once you've confirmed `gh auth status`.
- Remote Control makes outbound HTTPS only and never opens an inbound port. The
  session transcript is stored on Anthropic servers while connected; execution
  and filesystem access stay on your machine. See
  [the docs](https://code.claude.com/docs/en/remote-control) for the details.

## Teardown

```bash
pct stop <CTID> && pct destroy <CTID>
rm -rf /root/claude-lxc-<CTID>
```

## License

MIT.
