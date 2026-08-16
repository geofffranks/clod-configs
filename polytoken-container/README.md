# polytoken-dev container

An isolated Linux dev container for running **Polytoken** in **Bypass+** mode, with
your repos/config mounted in and MCP access via the ratatoskr gateway on the
Mac. Brew provides the tools; `mise` provides the language runtimes.

## What's inside

| Tool | Source | Version |
|---|---|---|
| polytoken | `brew tap polytoken/tap` | `polytoken-unstable` |
| gh, rtk, tk (ticket), jq, yq, ripgrep, perl | brew | latest |
| mise | brew | latest |
| python | mise | 3.13 (default) + 3.11 |
| node | mise | lts |
| go | mise | latest |
| codex CLI | npm (`@openai/codex`) | latest |

MCP servers are not in the image — they live behind the ratatoskr gateway on
the Mac (see [MCP servers](#mcp-servers)).

## 1. Build

```bash
cd polytoken-container && ./build.sh     # docker build, DEV_UID=$(id -u)
```

MCP servers are **not** in the image: they are fronted by the ratatoskr
gateway running on the Mac (see [MCP servers](#mcp-servers)), so container
sessions get them over HTTP with nothing baked here.

## 2. Configure (host, once)

### API keys
```bash
cp .env.example ~/.config/polytoken-container.env && $EDITOR $_
```
run.sh also forwards provider tokens already exported in your shell
(`ANTHROPIC_API_KEY`, `ZAI_API_KEY`, `FOUNDRY_API_KEY`, … — see `POLY_PASS_ENV`).

### Polytoken config + permissions (via the claude-config installer)
```bash
./install.sh --target polytoken --overwrite
```
Installs into `~/.config/polytoken`:
- the **permissions baseline** (deny `git push` / `rm -rf` / gh write verbs),
- the **ratatoskr gateway** `mcp_servers` entry (see "MCP servers" below),
- the **container-awareness** session_start hook,
- and ensures `~/.local/bin` is on `~/.bashrc`'s PATH (where the `rato` gateway
  binary installs; if your shell is zsh, add it to `~/.zshrc` too).

Then set the host to **Autonomous** in a session (`/permissions`) — the container
forces Bypass+ itself (see below).

If your `~/.config/polytoken/config.yaml` still carries manual-era
`mcp_servers` entries (e.g. an old `localhost_vision` block), delete them —
every MCP arrives through the gateway now, and stray stdio entries would just
fail to spawn.

### Per-repo runtimes (recommended)
```bash
echo "python 3.11" > ~/workspace/dcs-retribution/.tool-versions   # PySide6/numpy stack
echo "python 3.13" > ~/workspace/<home-assistant-repo>/.tool-versions
```

## 3. Run

```bash
cd ~/workspace/<repo> && polytoken-container/run.sh    # interactive polytoken here
```
Run from under `~/workspace` to land in that repo; elsewhere lands at the
workspace root. Args pass through (`run.sh config validate`). Alias:
```bash
alias pt='bash "$HOME/workspace/claude-config/polytoken-container/run.sh"'
```

The container launches in **Bypass+**: run.sh drops an ephemeral
`.polytoken/config.yaml` (`default_permission_matcher: bypass_plus`) that
overrides the host's global Autonomous, and removes it on exit — so the host
keeps Autonomous. If the repo already has a project config, run.sh temporarily
moves it aside and restores it unchanged when the container exits.

## Safety model (layered)

```
┌─ container (filesystem boundary: only the mounts below are visible) ──────────────┐
│  ┌─ Bypass+ (zero prompts; deny rules still enforce) ──────────────────────────┐ │
│  │  deny: git push · rm -rf · gh write verbs        ← from global permissions  │ │
│  │  everything else runs free                                                   │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────────┘
host: Autonomous (classifier-judged) from the global config.
```

## Mounts

| Host | Container | Mode | Purpose |
|---|---|---|---|
| `~/workspace` | `/home/dev/workspace` | rw | your repos |
| `~/.config/polytoken` | `/home/dev/.config/polytoken` | rw | shared polytoken config |
| `~/bin` | `/home/dev/bin` | rw | your scripts |
| `~/.gitconfig` | `~/.gitconfig.host` | ro | git identity (via include) |
| `~/.config/gh` | `/home/dev/.config/gh` | ro | gh auth (writes denied by baseline) |
| `~/.gitignore` | `/home/dev/.gitignore` | ro | global ignore (excludesfile repointed in image) |
| `~/.local/share/polytoken-dev` | `~/.local/share/polytoken` | rw | container logs/sessions (dedicated dir) |
| `~/.codex` | `/home/dev/.codex` | rw | codex auth/config |
| `~/go/pkg/mod` | `/home/dev/go/pkg/mod` | rw | shared Go module cache |

Extra mounts: `POLY_EXTRA_MOUNTS='-v /x:/home/dev/x'`.

> The container's polytoken data is a **dedicated** `~/.local/share/polytoken-dev`,
> not the host's `~/.local/share/polytoken`: macOS Docker stamps dirs a root
> container once wrote with a `user.containers.override_stat` xattr, making them
> unwritable. Read container logs/sessions from `~/.local/share/polytoken-dev/`.

## MCP servers

All MCP servers are fronted by the **ratatoskr gateway**, which runs natively on
the Mac (launchd agent `local.ratatoskr`, loopback `:8910`). Polytoken — host
and container sessions alike — talks to it over HTTP:

```
http://host.docker.internal:8910/mcp
```

`host.docker.internal` resolves to loopback on the Mac via the `/etc/hosts`
alias that `claude-config/ratatoskr/setup-gateway.sh` installs, and to the VM
bridge inside this container — one literal URL for both contexts. The gateway
spawns the Mac-installed MCP binaries directly (`go install`-ed foundry-mcp and
codex-imagegen-mcp; node for minime_vision's lm-studio-mcp-server and for
appium-mcp) and fronts the remote homeassistant MCP. Nothing MCP-related is
baked into the image or spawned per-session anymore.

## Troubleshooting

- **`python`/`node`/`go` not found in a session:** mise shims are on PATH; pin via `.tool-versions`.
- **Bind-mount files root-owned / permission denied:** rebuild with `DEV_UID=$(id -u)` (build.sh does this).
- **`tk` not found:** the `ticket` formula is symlinked to `tk` at build.
- **Container logs:** `~/.local/share/polytoken-dev/logs/` (daemon) and `.../sessions/<id>/log.jsonl`.
- **MCP tools missing / an upstream unhealthy:** the gateway owns them now —
  call its `list-servers` meta-tool for per-upstream health, and check
  `~/Library/Logs/ratatoskr.log` on the Mac.
- **`rato` not found:** ensure `~/.local/bin` is on PATH (installer appends to `~/.bashrc`; if zsh, add to `~/.zshrc`).

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Image (brew + mise + codex/claude CLIs) |
| `build.sh` | `docker build` with matching host uid |
| `run.sh` | Launcher: mounts, cwd resolution, Bypass+ override, arg passthrough, env forwarding |
| `../ratatoskr/` | Gateway setup: `setup-gateway.sh` deploys the Mac-side MCP gateway and wires polytoken to it |
| `.env.example` | API-key template for `--env-file` |
