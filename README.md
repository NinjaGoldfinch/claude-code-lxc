# claude-code-lxc

One script that turns a Proxmox VE host into a Debian 13 (trixie) LXC container
running [Claude Code](https://code.claude.com/docs) in Remote Control server
mode, so you can drive a real dev box from claude.ai/code or the Claude mobile
app.

The box is **instanced**: it runs as many independent Remote Control servers as
you want, each with its own workspace, its own supervised tmux session and its
own entry in the claude.ai/code session picker. They share one claude.ai login
and one git identity, so you sign in once. Add and remove them at runtime with
`claude-instance` — no reprovisioning.

It generates every credential randomly and hands them back in a format you can
paste straight into a password manager and into GitHub.

## The three scripts

| Script | Runs on | Does |
| --- | --- | --- |
| `provision-claude-lxc.sh` | Proxmox host | Builds the container from scratch: credentials, keys, toolchain, instances |
| `update-claude-lxc.sh` | Proxmox host | Refreshes the code on a container that already exists. Touches no credentials |
| `claude-lxc-runtime.sh` | Inside the container | Installs the runtime files. The single source of truth both of the above push |

You run the first two. The third is shared machinery, so provisioning and
updating can never drift apart.

## Quick start

Run this on the **Proxmox host**, as root:

```bash
git clone https://github.com/NinjaGoldfinch/claude-code-lxc
cd claude-code-lxc
GIT_EMAIL=you@example.com INSTANCES="riot-proxy ninja-recorder" ./provision-claude-lxc.sh
```

`provision-claude-lxc.sh` needs `claude-lxc-runtime.sh` beside it. If it is not
there — running straight from a `curl`, say — it is fetched from this repo's
`main`. Set `RUNTIME_SRC=/path/to/claude-lxc-runtime.sh` to pin a local copy.

`INSTANCES` is optional — leave it out and you get a single instance named
`main`.

Read the scripts before you run them. If you would rather not, the one-liner is:

```bash
GIT_EMAIL=you@example.com bash -c "$(curl -fsSL https://raw.githubusercontent.com/NinjaGoldfinch/claude-code-lxc/main/provision-claude-lxc.sh)"
```

If the repo is private, `raw.githubusercontent.com` needs auth. Use
`gh repo clone NinjaGoldfinch/claude-code-lxc` on the host instead, or add
`-H "Authorization: Bearer $GITHUB_TOKEN"` to the curl.

## Updating

Pull the repo and re-run the code onto containers you already have:

```bash
cd claude-code-lxc && git pull
./update-claude-lxc.sh 250            # one container
./update-claude-lxc.sh 250 251 252    # several
./update-claude-lxc.sh 250 --no-restart
```

It refreshes the `claude-instance` CLI, the session wrapper, the systemd unit
and target, the PATH snippet and the shell aliases, then restarts the instances
that were running. Instances you had stopped stay stopped.

It deliberately does **not** touch anything you would have to redo:

- no passwords generated or changed
- no SSH keys created, replaced or re-registered with GitHub
- `~/.claude` untouched, so your claude.ai login survives
- git config, `allowed_signers` and the `gh` auth state left alone
- `/etc/claude-instances/*.env` left alone — instances and workspaces come back
  exactly as they were
- `~/.claude/settings.json` and `~/.tmux.conf` are yours after provisioning and
  are never rewritten

Containers provisioned before `/etc/claude-lxc.conf` existed are handled too:
the update recovers their settings from the installed CLI and writes the config
file on the way through.

## What you get

- An unprivileged LXC on Debian trixie, `onboot=1`, `nesting=1,keyctl=1`. RAM
  and disk default to 4 GB / 32 GB (Claude Code's documented minimum) and scale
  by +2 GB / +16 GB per extra instance.
- N Remote Control instances, each a `claude-remote@<name>.service` under a
  shared `claude-remote.target`, plus a `claude-instance` CLI to add, remove,
  list, attach to and tail them without reprovisioning.
- `/etc/claude-lxc.conf` recording the box's `DEV_USER`, `WORKSPACE_ROOT` and
  `CT_HOSTNAME`, so `update-claude-lxc.sh` needs nothing but the CTID.
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
- A templated `claude-remote@<instance>.service` that runs
  `claude --remote-control <session>` inside a supervised tmux loop, so every
  instance comes back after a reboot or a crash.
- Node.js 22, build-essential, Python 3, ripgrep, fd, jq, tmux, and the rest of
  the usual toolchain.
- A credentials bundle at `/root/claude-lxc-<CTID>/CREDENTIALS.txt` on the host,
  laid out as ready-to-file password manager entries.

## Instances

An instance is a name plus a workspace. Everything else is derived from it:

| Thing | Value |
| --- | --- |
| Registry entry | `/etc/claude-instances/<name>.env` |
| Workspace | `<WORKSPACE_ROOT>/<name>`, overridable |
| Session name in claude.ai/code | `<CT_HOSTNAME>-<name>`, overridable |
| tmux session | `claude-<name>` |
| systemd unit | `claude-remote@<name>.service` |

Names must match `[a-z0-9][a-z0-9_-]{0,30}` so they stay unambiguous as systemd
unit instances, tmux session names and directory names all at once.

```bash
claude-instance list                          # every instance and its state
sudo claude-instance add scratch              # workspace <root>/scratch, started
sudo claude-instance add api --workspace /srv/api --session-name api-box
sudo claude-instance remove scratch           # keeps the workspace
sudo claude-instance remove scratch --purge   # deletes it too, after confirming
sudo claude-instance restart api
claude-instance logs api -f
ca api                                        # attach to its tmux session
```

`ca` and `ci` are aliases for `claude-attach` and `claude-instance`. Whole fleet
at once: `sudo systemctl restart claude-remote.target`.

Two things follow from instances sharing one `~/.claude`:

- **One login covers all of them.** Sign in once and every instance, including
  ones you add months later, is authenticated.
- **Settings, history and MCP servers are shared too**, and each instance needs
  its own workspace — Claude Code keys session state off the working directory,
  so `add` refuses a directory another instance already claims.

Each concurrent instance is a full Claude Code process; budget roughly 2 GB of
RAM apiece beyond the first. `INSTANCES` sizes the container for you at
provision time, but `claude-instance add` on a live box cannot grow it — check
`free -m` before piling more on, and resize with
`pct set <CTID> --memory <MB>`.

## One manual step

Remote Control requires a claude.ai login on a Pro, Max, Team, or Enterprise
plan. An API key will not work. OAuth cannot open a browser inside a headless
container, so it prints a URL and takes a code back. After the script finishes:

Because every instance shares one login, you only do this once no matter how
many you run.

```bash
ssh -i /root/claude-lxc-<CTID>/id_ed25519_claude-dev dev@<container-ip>
cd ~/projects/main && claude     # any instance's workspace; accept trust, then /login
# Ctrl-C once you are signed in
sudo systemctl restart claude-remote.target
ci list                          # every instance and its state
ca main                          # attach to tmux; session URL and QR code are here
```

Then open [claude.ai/code](https://claude.ai/code) or the Claude mobile app —
one session per instance will be waiting, named `<CT_HOSTNAME>-<instance>`.

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
| `INSTANCES` | Instances to create, space/comma separated, each `name` or `name:/abs/path` (`main`) |
| `CORES` / `SWAP` | Resources (`4` / `2048`) |
| `MEMORY` / `DISK_GB` | Resources, scaled by instance count (`4096 + 2048×(n-1)` MB / `32 + 16×(n-1)` GB) |
| `ROOTFS_STORAGE` | Storage for the container disk (`local-lvm`) |
| `BRIDGE` / `CT_IP` / `CT_GW` / `CT_VLAN` | Networking (`vmbr0` / `dhcp`) |
| `NAMESERVER` | Resolvers (`1.1.1.1 9.9.9.9`) |
| `ROOTFS_URL` | linuxcontainers.org rootfs to use |
| `DEV_USER` / `WORKSPACE_ROOT` / `SSH_PORT` | Guest user, parent dir for instance workspaces, sshd port |
| `GIT_NAME` / `GIT_EMAIL` | Git identity and `allowed_signers` entry |
| `GH_TOKEN` | GitHub token for non-interactive `gh auth login` + automatic key registration (blank = do it interactively later) |
| `INSTALL_NODE` | Install Node.js 22 (`1`) |
| `CLAUDE_CHANNEL` | `latest` or `stable` |
| `ALLOW_UNVERIFIED_GITHUB_HOSTKEY` | Continue past a GitHub host key mismatch (`0`) |

Example:

```bash
CTID=250 MEMORY=8192 DISK_GB=64 CT_IP=192.168.1.50/24 CT_GW=192.168.1.1 \
INSTANCES="riot-proxy ninja-recorder scratch:/srv/scratch" \
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
ci list                                   # instances and their state
ca <instance>                             # attach to one session
sudo claude-instance restart <instance>
claude-instance logs <instance> -f
sudo systemctl restart claude-remote.target   # every instance at once
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
  token scoped to `admin:public_key` **and** `admin:ssh_signing_key` (classic
  — the signing-key registration 404s without the second one), or "SSH keys"
  + "SSH signing keys" write access (fine-grained), and revoke it once you've
  confirmed `gh ssh-key list` shows both keys.
- Remote Control makes outbound HTTPS only and never opens an inbound port. The
  session transcript is stored on Anthropic servers while connected; execution
  and filesystem access stay on your machine. See
  [the docs](https://code.claude.com/docs/en/remote-control) for the details.

## Teardown

```bash
pct stop <CTID> && pct destroy <CTID>
rm -rf /root/claude-lxc-<CTID>
```

To drop a single instance without touching the rest of the box, use
`sudo claude-instance remove <name> [--purge]` instead.

## License

MIT.
