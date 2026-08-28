# polytoken-dev container

An isolated Linux dev container for running **Polytoken** in **Bypass+** mode, with
your repos/config mounted in and MCP access via the ratatoskr gateway on the
Mac. Brew provides the tools; `mise` provides the language runtimes.

## What's inside

| Tool | Source | Version |
|---|---|---|
| polytoken | `https://get.polytoken.dev` installer | current installer channel |
| gh, rtk, tk (ticket), jq, yq, ripgrep, perl | brew | latest |
| mise | brew | latest |
| python | mise | 3.13 (default) + 3.11 |
| node | mise | lts |
| go | mise | 1.26.5 |
| polytoken-quota | local sibling checkout (`../polytoken-quota`) | current checkout |
| codex CLI | npm (`@openai/codex`) | latest |
| language servers | image package managers + pinned native artifacts | see the LSP matrix below |

MCP servers are not in the image — they live behind the ratatoskr gateway on
the Mac (see [MCP servers](#mcp-servers)).

## Language-server support

The image installs the LSPs justified by the repositories mounted into the
container. The shared Polytoken mappings live in the parent repository's
`polytoken/config.recommended.yaml` and are installed into the live
`~/.config/polytoken/config.yaml` by `scripts/install-polytoken.sh`. The
container's `.polytoken/config.yaml` remains an ephemeral Bypass+ permission
override and does not own the global LSP configuration.

| Language/file family | Server | Notes |
|---|---|---|
| TypeScript/JavaScript/TSX | `typescript-language-server` | Primary web-language server |
| Python | `pyright-langserver` | Primary typed-Python server |
| Lua | `lua-language-server` | First-party DCS plugin support |
| C/C++ | `clangd` | Includes PlatformIO/ESP32 source |
| Go | `gopls` | General workspace support |
| Rust | `rust-analyzer` | Rust standard-library sources installed |
| Swift | `sourcekit-lsp` | Linux SwiftPM support only; no Apple SDK/Xcode support |
| Kotlin | `kotlin-lsp` | Official Kotlin server; Alpha; Android SDK/device/build support not validated |
| YAML | `yaml-language-server` | Home Assistant/configuration files |
| Markdown | `marksman` | Documentation support |
| Bash | `bash-language-server` | Shell scripts |
| JSON | `vscode-json-language-server` | Extracted VS Code server for JSON/JSONC |
| CSS | `vscode-css-language-server` | Extracted VS Code server for CSS/SCSS/LESS |
| HTML | `vscode-html-language-server` | Extracted VS Code server for HTML |
| ESLint | `vscode-eslint-language-server` | Diagnostics-only auxiliary server |
| Dockerfiles | `docker-langserver` | `Dockerfile*` files |
| Emmet | `emmet-language-server` | Auxiliary HTML/CSS/JSX/TSX completion |
| Perl | none in the selected catalog | Perl remains an installed CLI/runtime tool only |

Gradle/Groovy, Android XML, and general XML are syntax/configuration-only in
this image; Kotlin LSP does not claim Gradle or XML language intelligence. The
requested `ha-rocu-cloud` repository path was not present; the inventory used
`ha-roku-cloud`.

The machine-readable server and routing contract is `lsp-servers.yaml`.
Available local checks are:

```bash
scripts/test-lsp-support.sh manifest
scripts/test-lsp-support.sh artifacts
scripts/test-lsp-support.sh routing
scripts/test-lsp-support.sh config
scripts/test-lsp-support.sh protocol
scripts/test-lsp-support.sh native
scripts/test-lsp-support.sh docs
scripts/test-lsp-support.sh build-contract
```

After building an image, verify its executables with:

```bash
scripts/test-lsp-support.sh executables --image polytoken-dev:latest --engine docker
scripts/test-lsp-support.sh protocol --image polytoken-dev:latest --engine docker
scripts/test-lsp-support.sh native --image polytoken-dev:latest --engine docker
polytoken --config-dir ~/.config/polytoken config validate --user
polytoken lsp check
```

The `protocol` and `native` checks require a built image plus a Docker-compatible
engine; they validate runtime prerequisites inside that image. The full image
build requires a sibling `polytoken-quota` checkout and a Docker-compatible
engine with BuildKit named-context support:

```bash
POLYTOKEN_QUOTA_DIR=../polytoken-quota DOCKER_BIN=podman ./build.sh
# or: POLYTOKEN_QUOTA_DIR=../polytoken-quota DOCKER_BIN=docker ./build.sh
```

Swift and Kotlin executable checks establish Linux language-server support,
not iOS/macOS or Android project build capability. The Swift server must use
the same Linux Swift toolchain as the SwiftPM project; Apple SDK/framework
resolution, signing, and simulators remain host-side concerns. The official
Kotlin server is Alpha and Android SDK/device/build behavior is outside this
image's validation scope.

## 1. Build

The build uses the current local checkout of the sibling `polytoken-quota`
repository at `../polytoken-quota` (relative to this repository). That checkout
must contain `go.mod` and `cmd/polytoken-quota`. Override the source location with
`POLYTOKEN_QUOTA_DIR` when needed:

```bash
cd polytoken-container && ./build.sh
# POLYTOKEN_QUOTA_DIR=/path/to/polytoken-quota ./build.sh
# POLY_CONTAINER_WORKSPACE=/Users/gfranks/workspace ./build.sh  # override the image workspace path
```

The script passes the quota repository as a narrow Docker BuildKit named context,
then the image compiles and installs `polytoken-quota` at
`/home/dev/.local/bin/polytoken-quota`. It is therefore available directly on
`PATH` in container sessions and reflects the local checkout, including
unpublished changes. The image uses Go 1.26.5, matching the quota module's
required toolchain, and requires a Docker installation with BuildKit named-context
support. `build.sh` enables BuildKit for the build.

This change installs the executable only. The quota utility's policy/state under
`~/.polytoken-quota` is not mounted or persisted by the container launcher; add a
host mount and configure `POLYTOKEN_QUOTA_HOME` separately if persistent quota
operation is needed.

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
| `~/workspace` | `/Users/gfranks/workspace` | rw | your repos; matches Git worktree paths |
| `~/.config/polytoken` | `/home/dev/.config/polytoken` | rw | shared polytoken config |
| `~/bin` | `/home/dev/bin` | rw | your scripts |
| `~/.gitconfig` | `~/.gitconfig.host` | ro | git identity (via include) |
| `~/.config/gh` | `/home/dev/.config/gh` | ro | gh auth (writes denied by baseline) |
| `~/.gitignore` | `/home/dev/.gitignore` | ro | global ignore (excludesfile repointed in image) |
| `~/.local/share/polytoken-dev` | `~/.local/share/polytoken` | rw | container logs/sessions (dedicated dir) |
| `~/.codex` | `/home/dev/.codex` | rw | codex auth/config |
| `~/go/pkg/mod` | `/home/dev/go/pkg/mod` | rw | shared Go module cache |

Extra mounts: `POLY_EXTRA_MOUNTS='-v /x:/home/dev/x'`. Override the host-matching workspace path with `POLY_CONTAINER_WORKSPACE` when building and running; the default is `$HOME/workspace` (for example, `/Users/gfranks/workspace`).

The container intentionally keeps `HOME=/home/dev`; only the workspace uses the host absolute path. This lets Git worktrees created in the container resolve on the host without changing Linux tool/config paths. Worktrees created before this change may still contain `/home/dev/...` metadata and should be recreated or repaired once.

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
