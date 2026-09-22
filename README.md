# claude-code-lxc

One script that turns a Proxmox VE host into a Debian 13 (trixie) LXC container
running [Claude Code](https://code.claude.com/docs) in Remote Control server
mode, so you can drive a real dev box from claude.ai/code or the Claude mobile
app.

The box is **instanced**: it runs as many independent Remote Control servers as
you want, each with its own workspace and its own supervised tmux session. Each
one shows up under **Remote Control** at claude.ai/code and in the Claude app as
a machine you can open sessions on — new ones, as many as you like, not a single
fixed session. They share one claude.ai login and one git identity, so you sign
in once. Add and remove them at runtime with `claude-instance` — no
reprovisioning.

It generates every credential randomly and hands them back in a format you can
paste straight into a password manager and into GitHub.

## The four scripts

| Script | Runs on | Does |
| --- | --- | --- |
| `provision-claude-lxc.sh` | Proxmox host | Builds the container from scratch: credentials, keys, toolchain, instances |
| `update-claude-lxc.sh` | Proxmox host | Refreshes the code on a container that already exists. Touches no credentials |
| `reset-claude-lxc.sh` | Proxmox host | Wipes a container back to just-provisioned: empty workspaces, no claude.ai login. Keeps the box, its users and its keys |
| `claude-lxc-runtime.sh` | Inside the container | Installs the runtime files. The single source of truth the other three push or call |

You run the first three. The last is shared machinery, so provisioning and
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

It refreshes the `claude-instance` CLI, `claude-update`, the server wrapper and
its preflight, the systemd unit and target, the PATH snippet and the shell
aliases, then restarts the instances that were running. Instances you had
stopped stay stopped. This is also how a box built before server mode moves to
it: the registry is untouched, and each instance picks up the defaults for the
settings that did not exist before. It also repairs a root-owned `~/.config`
left by older provisioning runs, which made `gh auth login` fail with
`mkdir /home/dev/.config/gh: permission denied`.

It updates this repo's runtime, not Claude Code — for that, run
[`claude-update`](#updating-claude-code) on the box.

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

- A container named after the project it is built for —
  `ninja-recorder-dev-container`, numbered `-2`, `-3` for later boxes on the
  same node.
- An unprivileged LXC on Debian trixie, `onboot=1`, `nesting=1,keyctl=1`. RAM
  and disk default to 4 GB / 32 GB (Claude Code's documented minimum) and scale
  by +2 GB / +16 GB per extra instance.
- N Remote Control servers, each a `claude-remote@<name>.service` under a
  shared `claude-remote.target`, plus a `claude-instance` CLI to add, remove,
  reconfigure, list, attach to and tail them without reprovisioning.
- A `claude-update` command that updates the shared Claude Code CLI and
  restarts every running instance onto it.
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
- An optional GitHub sign-in *before* the container is created, when run from
  a terminal without `GH_TOKEN`: sign in through the browser with a one-time
  code (needs `gh` on the Proxmox host), paste a token (a creation link with
  the right scopes pre-selected is printed), or skip. The token is checked
  against GitHub, you're shown who it belongs to and any missing scopes, and
  asked before it's passed into the container.
- GitHub's ed25519 host key fingerprint pinned at provision time rather than
  trusting whatever `ssh-keyscan` returns.
- Claude Code installed via the native installer (auto-updating), falling back
  to the signed apt repository with a fingerprint check.
- A templated `claude-remote@<instance>.service` that runs
  `claude remote-control` inside a supervised tmux loop, so every instance comes
  back after a reboot or a crash — and answers Remote Control's two one-time
  prompts (workspace trust, and Remote Control itself) up front, since nothing
  in a headless container can answer them.
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
| Name in claude.ai/code | `<CT_HOSTNAME>-<name>`, collapsing to `<CT_HOSTNAME>` when the hostname already starts with the instance name. Overridable |
| Spawn mode / capacity | `same-dir` / 32 sessions, both overridable — see [Sessions](#sessions) |
| tmux session | `claude-<name>` |
| systemd unit | `claude-remote@<name>.service` |

Names must match `[a-z0-9][a-z0-9_-]{0,30}` so they stay unambiguous as systemd
unit instances, tmux session names and directory names all at once.

```bash
claude-instance list                          # every instance and its state
sudo claude-instance add scratch              # workspace <root>/scratch, started
sudo claude-instance add api --workspace /srv/api --session-name api-box
sudo claude-instance add web --spawn worktree --capacity 4
sudo claude-instance set api --spawn worktree # change one, restarting it
sudo claude-instance remove scratch           # keeps the workspace
sudo claude-instance remove scratch --purge   # deletes it too, after confirming
sudo claude-instance restart api
claude-instance logs api -f
ca api                                        # attach to its tmux session
sudo claude-instance reset                    # whole box back to just-provisioned
```

`ca`, `ci` and `cu` are aliases for `claude-attach`, `claude-instance` and
`claude-update`. Whole fleet at once: `cr`, which is
`sudo systemctl restart claude-remote.target`.

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

## Sessions

Every instance runs `claude remote-control` — the **server**, not a single
session. Pick it under Remote Control at claude.ai/code or in the Claude app and
start a session on it; start another and the first keeps running. One session is
pre-created when the server starts so there is somewhere to type immediately.

How those sessions get a working directory is the instance's spawn mode:

| Mode | Each new session | Use it when |
| --- | --- | --- |
| `same-dir` (default) | works directly in the instance workspace | you mostly want one session at a time, and the occasional second one to look at something |
| `worktree` | gets its own [git worktree](https://code.claude.com/docs/en/worktrees) off the workspace | you run several at once on one repo and don't want them editing the same files |
| `session` | nothing — the server keeps one session and refuses further connections | you want the pre-server-mode behaviour back |

```bash
sudo claude-instance set api --spawn worktree      # a worktree per session
sudo claude-instance set api --capacity 4          # at most 4 at once (default 32)
sudo claude-instance set api --permission-mode acceptEdits
```

`set` restarts the instance so the change takes effect, which drops the sessions
it was serving; pass `--no-restart` to wait for a quieter moment. `worktree`
needs the workspace to be a git repository — until it is one, the instance says
so in its log and serves from the directory itself.

Capacity is a ceiling, not a reservation, and the real limit is RAM: every live
session is another Claude Code process in the same container.

## Updating Claude Code

Claude Code auto-updates, but a running instance holds the binary it started
with until it restarts. One command does both:

```bash
claude-update                # update, then restart every running instance
cu                           # the alias
claude-update --no-restart   # update only; instances switch over on their own
claude-update --to 2.1.280   # or stable / latest — pin, or roll back
cr                           # just restart the fleet, no update
```

Restarting drops the sessions the instances are serving, so do it when nothing
is mid-turn.

This is separate from [`update-claude-lxc.sh`](#updating), which refreshes *this
repo's* runtime scripts from the Proxmox host. `claude-update` updates Claude
Code itself, from inside the box.

## Resetting a box

Start over without rebuilding the container. From the Proxmox host:

```bash
./reset-claude-lxc.sh 250              # asks you to type 250 back first
./reset-claude-lxc.sh 250 251          # one confirmation per container
./reset-claude-lxc.sh 250 --keep-workspaces
./reset-claude-lxc.sh 250 --yes        # for scripts; no prompt
```

Or on the box itself: `sudo claude-instance reset`.

It stops every instance, empties every workspace, and deletes `~/.claude` and
`~/.claude.json` — the claude.ai login with them. The instances stay **defined**,
so the box comes back with the same names, workspaces, session names and spawn
settings; they are left stopped, because nothing can connect until you sign in
again.

| Gone | Kept |
| --- | --- |
| Everything in every workspace | The container, its ID, hostname, network and resources |
| The claude.ai login | The root and dev passwords |
| Claude Code's history, projects and MCP state | All three SSH keys — so the GitHub registrations still work |
| | `gh` auth, git config and `allowed_signers` |
| | `~/.claude/settings.json` |

So the only thing to redo afterwards is `/login`:

```bash
cd ~/projects/<instance> && claude   # /login, then Ctrl-C
sudo systemctl start claude-remote.target
```

`--keep-workspaces` resets Claude Code's state but leaves your files alone —
useful when the login or the session state is what's wrong, not the code. Reset
refuses outright if an instance's workspace is `/`, `/home`, the dev user's home
or the workspace root itself; pass `--keep-workspaces` to reset such a box.

To go further and destroy the container, see [Teardown](#teardown).

## One manual step

Remote Control requires a claude.ai login on a Pro, Max, Team, or Enterprise
plan. An API key will not work. OAuth cannot open a browser inside a headless
container, so it prints a URL and takes a code back. After the script finishes:

Because every instance shares one login, you only do this once no matter how
many you run.

```bash
ssh -i /root/claude-lxc-<CTID>/id_ed25519_<CT_HOSTNAME> dev@<container-ip>
cd ~/projects/main && claude     # any instance's workspace; accept trust, then /login
# Ctrl-C once you are signed in
sudo systemctl restart claude-remote.target
ci list                          # every instance and its state
ca main                          # attach to tmux; session URL and QR code are here
```

Then open [claude.ai/code](https://claude.ai/code) or the Claude mobile app and
look under **Remote Control** — one server per instance will be waiting, ready
for you to start sessions on. The exact names are printed at the end of
provisioning and listed in the credentials bundle.

If you skipped the GitHub sign-in and did not pass `GH_TOKEN`, there's a second manual step for GitHub itself
— from the same SSH session:

```bash
gh auth login --git-protocol ssh --hostname github.com
gh ssh-key add ~/.ssh/id_ed25519_github_auth.pub --type authentication --title "dev box auth"
gh ssh-key add ~/.ssh/id_ed25519_github_signing.pub --type signing --title "dev box signing"
```

`gh auth login` without `--with-token` walks you through a device-code flow:
it prints a URL and a one-time code to enter on any browser, no token needed.

## Hostnames

A container built for a single project is named after it, so it is recognisable
in the Proxmox node list:

```bash
INSTANCES="ninja-recorder" ./provision-claude-lxc.sh   # -> ninja-recorder-dev-container
```

Build a second box for the same project and the name is numbered rather than
duplicated. The script reads the hostnames already on the node and takes the
next free one:

```
ninja-recorder-dev-container      # first
ninja-recorder-dev-container-2    # second
ninja-recorder-dev-container-3    # third
```

With several instances there is no single project to name it after, so it falls
back to `claude-dev` (and `claude-dev-2`, and so on). Underscores in an instance
name are folded to hyphens, since hostnames cannot contain them. Setting
`CT_HOSTNAME` explicitly overrides all of this — the name is then used as given,
with a warning if it clashes, and rejected outright if it is not a valid DNS
label.

The hostname also drives the names in the claude.ai/code picker. Rather
than `ninja-recorder-dev-container-ninja-recorder`, a session whose instance
name already leads the hostname just uses the hostname:

| Hostname | Instance | Name in the picker |
| --- | --- | --- |
| `ninja-recorder-dev-container` | `ninja-recorder` | `ninja-recorder-dev-container` |
| `ninja-recorder-dev-container-2` | `ninja-recorder` | `ninja-recorder-dev-container-2` |
| `ninja-recorder-dev-container` | `scratch` | `ninja-recorder-dev-container-scratch` |
| `claude-dev` | `riot-proxy` | `claude-dev-riot-proxy` |

`claude-instance add --session-name` overrides it per instance.

## Configuration

Everything is an environment variable. Defaults in parentheses.

| Variable | What it does |
| --- | --- |
| `CTID` | Container ID (next free) |
| `CT_HOSTNAME` | Hostname. Derived from the project when unset — see [Hostnames](#hostnames) |
| `INSTANCES` | Instances to create, space/comma separated, each `name` or `name:/abs/path` (`main`) |
| `SPAWN_MODE` | How each instance creates sessions: `same-dir`, `worktree` or `session` (`same-dir`) |
| `CAPACITY` | Concurrent sessions per instance (blank — claude's own default of 32) |
| `CORES` / `SWAP` | Resources (`4` / `2048`) |
| `MEMORY` / `DISK_GB` | Resources, scaled by instance count (`4096 + 2048×(n-1)` MB / `32 + 16×(n-1)` GB) |
| `ROOTFS_STORAGE` | Storage for the container disk (`local-lvm`) |
| `BRIDGE` / `CT_IP` / `CT_GW` / `CT_VLAN` | Networking (`vmbr0` / `dhcp`) |
| `NAMESERVER` | Resolvers (`1.1.1.1 9.9.9.9`) |
| `ROOTFS_URL` | linuxcontainers.org rootfs to use |
| `DEV_USER` / `WORKSPACE_ROOT` / `SSH_PORT` | Guest user, parent dir for instance workspaces, sshd port |
| `GIT_NAME` / `GIT_EMAIL` | Git identity and `allowed_signers` entry |
| `GH_TOKEN` | GitHub token for non-interactive `gh auth login` + automatic key registration (blank = see `GH_AUTH`) |
| `GH_AUTH` | With no `GH_TOKEN`: `ask` offers browser sign-in / paste / skip before the container is created, `web` or `paste` go straight to that, `skip` asks nothing (`ask`; no terminal = `skip`) |
| `GH_AUTH_YES` | `1` passes the token in without the "continue as &lt;login&gt;?" confirmation (`0`) |
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
ca <instance>                             # attach to one server's tmux session
sudo ci set <instance> --spawn worktree   # change one, restarting it
sudo claude-instance restart <instance>
claude-instance logs <instance> -f
cu                                        # update Claude Code + restart the fleet
cr                                        # restart the fleet, nothing else
sudo ci reset                             # wipe the box back to just-provisioned
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
  confirmed `gh ssh-key list` shows both keys. Browser sign-in (`GH_AUTH=web`)
  runs the host's `gh` against a throwaway config directory, so it never
  touches a `gh` login the Proxmox host already has.
- Each instance pre-accepts the workspace-trust dialog for its own workspace
  and Remote Control's one-time confirmation, by setting
  `hasTrustDialogAccepted` and `remoteDialogSeen` in `~/.claude.json`. A prompt
  nobody can answer is a service that never starts; nothing else in that file is
  touched. Treat the workspaces as trusted — because they are.
- Remote Control makes outbound HTTPS only and never opens an inbound port. The
  session transcript is stored on Anthropic servers while connected; execution
  and filesystem access stay on your machine. See
  [the docs](https://code.claude.com/docs/en/remote-control) for the details.

## Teardown

```bash
pct stop <CTID> && pct destroy <CTID>
rm -rf /root/claude-lxc-<CTID>
```

That is the irreversible one: the container, its keys and its passwords go with
it, and the GitHub keys it registered are left dangling. Two smaller hammers:

- `./reset-claude-lxc.sh <CTID>` — [wipe the box](#resetting-a-box) back to
  just-provisioned but keep the container, its users and its keys.
- `sudo claude-instance remove <name> [--purge]` — drop a single instance
  without touching the rest of the box.

## License

MIT.
