# polytoken-dev container

An isolated Linux dev container for running **Polytoken** in **Bypass+** mode, with
native MCP servers and your repos/config mounted in. Brew provides the tools;
`mise` provides the language runtimes; the Go MCP servers run from source via
`go run` (no rebuild when you edit them).

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
| foundry-mcp, codex-imagegen-mcp | `go run` wrappers (source in ~/workspace) | live |
| minime-vision | node wrapper (lm-studio-mcp-server) | live |

## 1. Build

```bash
cd polytoken-container && ./build.sh     # docker build, DEV_UID=$(id -u)
```

MCP servers are **not** compiled into the image — they run from source via
`go run`/node wrappers, so editing their repos takes effect on next launch with
no rebuild.

## 2. Configure (host, once)

### API keys
```bash
cp .env.example ~/.config/polytoken-container.env && $EDITOR $_
```
run.sh also forwards provider tokens already exported in your shell
(`ANTHROPIC_API_KEY`, `ZAI_API_KEY`, `FOUNDRY_API_KEY`, … — see `POLY_PASS_ENV`).

### Polytoken config + permissions + MCP wrappers (via the claude-config installer)
```bash
./install.sh --target polytoken --overwrite
```
Installs into `~/.config/polytoken`:
- the **permissions baseline** (deny `git push` / `rm -rf` / gh write verbs),
- portable **mcp_servers** (bare commands),
- the **container-awareness** session_start hook,
- and the **host MCP wrappers** at `~/.local/bin` (and appends `~/.local/bin` to
  `~/.bashrc`; if your shell is zsh, add it to `~/.zshrc` too).

Then set the host to **Autonomous** in a session (`/permissions`) — the container
forces Bypass+ itself (see below).

> After installing, delete the old `localhost_vision:` block from
> `~/.config/polytoken/config.yaml` (the installer adds `minime_vision` but can't
> remove the old name).

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
keeps Autonomous.

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

Bare commands (PATH-resolved) so the same config works on host (darwin) and
container (linux):
- `foundry-mcp` → `go run` from `~/workspace/foundry-mcp-tools` (relay `192.168.2.247:3010`).
- `codex-imagegen-mcp` → `go run` from `~/workspace/codex-imagegen-mcp` (wraps the `codex` CLI; needs `~/.codex` auth).
- `minime-vision` → `node ~/workspace/lm-studio-mcp-server/server.js` (LM Studio at `192.168.2.247:1234`).

A Go server's first start per session takes a few seconds (compile); the shared
`~/go/pkg/mod` avoids re-fetching deps.

## Troubleshooting

- **`python`/`node`/`go` not found in a session:** mise shims are on PATH; pin via `.tool-versions`.
- **Bind-mount files root-owned / permission denied:** rebuild with `DEV_UID=$(id -u)` (build.sh does this).
- **`tk` not found:** the `ticket` formula is symlinked to `tk` at build.
- **Container logs:** `~/.local/share/polytoken-dev/logs/` (daemon) and `.../sessions/<id>/log.jsonl`.
- **An MCP server won't start:** check `~/.local/share/polytoken-dev/sessions/<id>/__mcp_*.log`.
- **Host MCP commands not found:** ensure `~/.local/bin` is on PATH (installer appends to `~/.bashrc`; if zsh, add to `~/.zshrc`).

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Image (brew + mise + codex + MCP wrapper copy) |
| `build.sh` | `docker build` with matching host uid |
| `run.sh` | Launcher: mounts, cwd resolution, Bypass+ override, arg passthrough, env forwarding |
| `mcp-wrappers/` | Shared MCP launcher scripts (used by the image and installed to the host) |
| `.env.example` | API-key template for `--env-file` |
