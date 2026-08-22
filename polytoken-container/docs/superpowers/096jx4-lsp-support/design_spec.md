# Language-server support for the Polytoken development image

## Status

Approved design. This document is a local working artifact and must not be committed.

## Problem

Polytoken now supports language servers, but the `polytoken-dev` image currently installs language runtimes and general CLI tools without installing or configuring LSP executables. The image mounts a broad set of repositories, so support should be based on actual workspace evidence rather than the entire available server catalog.

## Repository inventory

The requested `ha-rocu-cloud` path does not exist. The workspace contains `ha-roku-cloud`, which is treated as the intended repository.

| Repository | Confirmed language/file families | Evidence and scope |
|---|---|---|
| `track-data-collection` | TypeScript/TSX, JavaScript/MJS, JSON, Kotlin, Swift, XML, Gradle/Groovy, Bash | Root and mobile TypeScript projects; Android Kotlin sources and Gradle files; Swift packages and sources; shell build scripts. |
| `dcs-retribution` | Python, TypeScript/TSX, JavaScript, CSS, HTML, YAML, JSON, Lua, Markdown | Python application/tests; React client; first-party Lua plugins/tests; web assets and extensive data/config files. |
| `ha-configs` | YAML, Python, C/C++, Bash, JSON, Markdown, PlatformIO/Arduino configuration, Dockerfile | PlatformIO ESP32 C++ firmware and tests; Python tests/helpers; Home Assistant YAML; shell/JSON/Docker files. |
| `hassio-config` | YAML, Python, Bash, JSON, Markdown | Home Assistant configuration plus Python tests and shell test runner. |
| `ha-roku-cloud` | Python, JSON, YAML/INI, Markdown | Home Assistant custom integration and tests. |
| `ha-generac` | Python, JSON, YAML, Markdown, INI/config | Home Assistant custom integration, tests, and Python lint/test configuration. |
| `appium-mcp` | TypeScript, JavaScript/MJS, JSON, Bash, YAML, Markdown | TypeScript MCP server, JS configuration/scripts, telemetry compose files, and shell scripts. |

The wider workspace also establishes Go and Rust as supported languages. Perl is a workspace/tooling language, but the supplied candidate catalog contains no Perl language server.

## Selected server scope

### Primary servers

- TypeScript/JavaScript: `typescript-language-server`
- Python: `pyright-langserver`
- Lua: `lua-language-server`
- C/C++: `clangd`
- Go: `gopls`
- Rust: `rust-analyzer`
- Swift: `sourcekit-lsp` from a Swift toolchain
- Kotlin: official standalone Kotlin LSP distribution, exposed as `kotlin-lsp`
- YAML: `yaml-language-server`
- Markdown: `marksman`
- Bash: `bash-language-server`

### Web/config auxiliary servers

- CSS, HTML, JSON, and ESLint servers from `vscode-langservers-extracted`
- Dockerfile server
- `emmet-language-server` for web projects

Tailwind support is omitted unless repository evidence or a Tailwind configuration is found during implementation. `ruff` is also omitted from the first pass because the repositories use mypy/Black-style Python tooling and LSP lint routing is not required for core language intelligence.

### Executable and routing manifest

The implementation must create the machine-readable manifest at `lsp-servers.yaml` in the container repository. This manifest is the single source for Docker smoke checks, Polytoken mappings, and README consistency checks. Each record must contain: server name, installed package/artifact and exact version, executable path, command arguments, language ID, file extensions or filename matchers, root markers, primary versus auxiliary role, and architecture support.

The initial routing records are:

| Server | Primary file routing | Root markers / role |
|---|---|---|
| `typescript-language-server` | `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs` | `package.json`, `tsconfig.json`; primary TypeScript/JavaScript |
| `pyright-langserver` | `.py`, `.pyi` | `pyproject.toml`, `setup.cfg`, `mypy.ini`, `.git`; primary Python |
| `lua-language-server` | `.lua` | `.git`; primary Lua |
| `clangd` | `.c`, `.h`, `.cc`, `.cpp`, `.cxx`, `.hpp` | `compile_commands.json`, `platformio.ini`, `.git`; primary C/C++ |
| `gopls` | `.go` | `go.mod`, `go.work`, `.git`; primary Go |
| `rust-analyzer` | `.rs` | `Cargo.toml`, `rust-project.json`, `.git`; primary Rust |
| `sourcekit-lsp` | `.swift` | `Package.swift`, `Package.resolved`, `.git`; primary Swift, Linux-only caveat |
| `kotlin-lsp` | `.kt`, `.kts` | `settings.gradle`, `settings.gradle.kts`, `build.gradle`, `build.gradle.kts`, `.git`; primary Kotlin, alpha caveat |
| `yaml-language-server` | `.yaml`, `.yml` | `.git`; primary YAML |
| `marksman` | `.md`, `.markdown` | `.git`; primary Markdown |
| `bash-language-server` | `.sh`, `.bash` | `.git`; primary Bash |
| extracted JSON server | `.json`, `.jsonc` | `package.json`, `.git`; primary JSON |
| extracted CSS server | `.css`, `.scss`, `.less` | `package.json`, `.git`; primary CSS-like styles |
| extracted HTML server | `.html`, `.htm`, XML-like web files where appropriate | `package.json`, `.git`; primary HTML, not general Android XML |
| extracted ESLint server | diagnostics for JS/TS files only | `eslintConfig`, `eslint.config.*`, `package.json`; auxiliary/linter-only |
| Dockerfile server | files named `Dockerfile*` | `Dockerfile`, `.git`; primary Dockerfile |
| `emmet-language-server` | HTML/CSS/JSX/TSX contexts only | nearest web project marker; auxiliary completion-only |

Gradle/Groovy, Android XML, and general XML are explicitly syntax/configuration-only in this first pass; Kotlin LSP does not claim Gradle or XML language intelligence. No mapping may route `.json` to both the extracted JSON server and another primary server, and ESLint/Emmet must not become competing primary mappings.

### Explicit exclusions

Do not install Astro, Dart, Deno, Elixir, Erlang, Gleam, GraphQL, Helm, Haskell, Metals/Scala, Nix, OCaml, PHP, Prisma, Ruby, Svelte, Terraform, Vim, Vue, or other catalog entries without evidence in the scanned workspace. Perl remains installed as a general CLI/runtime tool only; there is no configured Perl LSP in the selected catalog.

## Architecture

1. Install the selected servers in the Docker image, grouped by package ecosystem.
2. Pin large or externally downloaded toolchains/artifacts; avoid relying on an editor extension to supply binaries. The implementation must record, in the server manifest, the exact version, source URL/package, checksum where applicable, install destination, launcher name, and supported `TARGETARCH` for every selected server. npm packages must use pinned versions; Rust must include a pinned toolchain plus `rust-src`; Swift must use a pinned Linux toolchain; Kotlin must use a pinned official Linux archive; and native artifacts must select `TARGETARCH` explicitly or fail with a documented message.
3. Expose stable executable names on the image `PATH`.
4. Add one build-time smoke test driven by the manifest that verifies every expected executable and fails the image build if one is missing or not executable.
5. Add explicit shared Polytoken configuration under `daemon.lsp` with one mapping per server. The source of truth is `polytoken/config.recommended.yaml` in the parent `claude-config` repository; `scripts/install-polytoken.sh` overlays it into the live `~/.config/polytoken/config.yaml`. The container repository's `.polytoken/config.yaml` is only the ephemeral Bypass+ project override generated by `run.sh` and must not receive the global LSP mappings. Keep LSP enabled and initially omit an idle timeout so heavyweight servers are not repeatedly restarted.
6. Update the container README with the support matrix, installation caveats, validation commands, and the `ha-roku-cloud` path correction.

Pyright is the selected Python server because it provides project-wide type intelligence for typed Python without introducing a second Python LSP implementation. Swift support is Linux SourceKit-LSP support only: Xcode, Apple SDKs, signing, and iOS simulator workflows remain host-side. Kotlin support is similarly language-server support; Android SDK/device workflows remain separate concerns.

## Installation and configuration constraints

- npm packages should be installed globally using the image's mise-managed Node runtime.
- `gopls` must be installed with the image's Go toolchain.
- `rust-analyzer` must be paired with Rust standard-library sources and the image's Rust toolchain.
- `sourcekit-lsp` must come from a compatible Linux Swift toolchain and use the same toolchain as Swift package builds.
- Kotlin must use a pinned official standalone distribution or a pinned, reproducible release artifact, with a wrapper if its upstream executable name differs from `kotlin-lsp`.
- Homebrew/apt package names must be verified in the target Ubuntu/Linuxbrew environment rather than assumed.
- LSP command paths must remain valid for non-interactive `shell_exec` processes, not only interactive shells.
- The image must declare its supported build architectures through Docker `TARGETARCH`; architecture-specific downloads must map `amd64`/`arm64` to upstream names and fail with an explicit unsupported-architecture message otherwise.
- Swift validation must use a minimal Linux SwiftPM fixture built with the same toolchain as `sourcekit-lsp`; it proves Linux Swift syntax/project support only and does not prove Apple SDK/framework resolution.
- Kotlin validation must use a minimal Kotlin fixture and a pinned standalone server release; the README must label the official Kotlin server as Alpha and separately state that Android SDK/device/build behavior is not validated.

## Error handling and compatibility

- Image build fails early if a selected executable is absent or not executable.
- Polytoken configuration must not route the same file type to multiple competing primary servers. Auxiliary servers are restricted to their intended file types or diagnostics-only roles.
- If a heavyweight native toolchain cannot be installed reproducibly on the target architecture, preserve the documented limitation and fail clearly rather than silently claiming support.
- Generated/vendor trees are not part of the language inventory and should not drive server selection.

## Validation

Automated validation is fixed at `scripts/test-lsp-support.sh` in the container repository, driven by `lsp-servers.yaml` and fixtures under `scripts/fixtures/lsp/`. The script must accept `--image IMAGE[:TAG]` and `--engine docker|podman`, and exit nonzero on any failed assertion. It must implement these acceptance criteria:

| ID | Observable acceptance criterion | Required executable test/evidence |
|---|---|---|
| AC.1 | Every manifest entry has a pinned version, source, executable, language ID, routing rule, root marker, and supported architecture; no duplicate primary extension routes exist. | `scripts/test-lsp-support.sh manifest` parses `lsp-servers.yaml` with `yq` and exits 0 only when all required fields and uniqueness checks pass. |
| AC.2 | A built image contains every manifest executable and each command is executable on the non-interactive PATH. | `scripts/test-lsp-support.sh executables --image "$IMAGE"` runs the manifest command checks inside the image and exits nonzero for any missing command. |
| AC.3 | The selected artifacts are reproducible for the declared architecture. | `scripts/test-lsp-support.sh artifacts` rejects unpinned npm versions, missing native checksums, missing `TARGETARCH` mappings, or undocumented unsupported architectures. |
| AC.4 | The parent installer produces a valid global Polytoken config containing the LSP mappings without modifying the ephemeral project override contract. | `scripts/test-lsp-support.sh config` creates a temporary `POLYTOKEN_CONFIG_DIR`, runs `POLYTOKEN_CONFIG_DIR="$tmp" bash ../scripts/install-polytoken.sh 0` from the parent repository, runs `polytoken --config-dir "$tmp" config validate --user`, and asserts `.daemon.lsp.enabled == true` plus every manifest mapping under `.daemon.lsp.servers`. |
| AC.5 | Representative file names route to exactly one intended primary server, with ESLint/Emmet auxiliary-only behavior. | `scripts/test-lsp-support.sh routing` evaluates fixed fixture paths in `scripts/fixtures/lsp/routing.txt` and compares each expected server/role against `lsp-servers.yaml`. |
| AC.6 | Lightweight selected servers complete LSP initialization and shutdown; heavyweight/native servers at least start and terminate within a bounded timeout against their minimal fixture. | `scripts/test-lsp-support.sh protocol` sends JSON-RPC `initialize` and `shutdown` to npm/YAML/Bash/JSON/CSS/HTML/Markdown/Python servers and runs timeout-bounded process checks for C++, Lua, Go, Rust, Swift, Kotlin, Dockerfile, and Emmet using fixtures under `scripts/fixtures/lsp/`. |
| AC.7 | Swift and Kotlin claims are limited to Linux language-server support. | `scripts/test-lsp-support.sh native` runs the minimal SwiftPM fixture and Kotlin fixture, and asserts README explicitly excludes Apple SDK/framework/signing/simulator and Android SDK/device/build guarantees. |
| AC.8 | Documentation and build workflow match the implementation. | `scripts/test-lsp-support.sh docs` checks README server names, Perl runtime-only wording, `get.polytoken.dev` provenance, `build.sh` engine/quota instructions, and the `ha-roku-cloud` correction; `scripts/test-lsp-support.sh build-contract` verifies the required sibling quota checkout or explicit `POLYTOKEN_QUOTA_DIR` contract without starting a full build. |

The image build validation must use `./build.sh` from the container repository with `POLYTOKEN_QUOTA_DIR` pointing to the sibling `/home/dev/workspace/polytoken-quota` checkout and `DOCKER_BIN=docker` or `DOCKER_BIN=podman`; the script's existing `--build-context quota=...` contract is part of AC.8. The README must state that both Docker-compatible engines are supported only when they provide BuildKit named-context support, and must document the exact command used for validation.

Manual validation should open representative files from `track-data-collection`, `dcs-retribution`, `ha-configs`, `hassio-config`, `ha-roku-cloud`, `ha-generac`, and `appium-mcp` in a Polytoken session and exercise definition lookup, references, diagnostics, or rename where the language/server supports it. Manual validation must record native SDK limitations rather than treating Linux LSP success as proof of iOS/Android build capability.

## Implementation Tasks

### Setup: Prepare the implementation branch

**Files:**
- None expected in the product image.

**Focused behavior:** Start the work item and create the implementation branch from the repository default branch, recording `lifecycle: in-development` where the repository's ticket workflow requires it.

**Test intent:** Confirm the implementation begins from the clean approved baseline.

**Done when:** The branch and work item are established without changing the design artifact.

**Review intent:** Preserve the approved design as the source of truth.

### Task 1: Add reproducible LSP installation to the image

**Files:**
- Modify: `Dockerfile`
- Modify: `build.sh` only if required to preserve the explicit `POLYTOKEN_QUOTA_DIR`/`DOCKER_BIN` build contract
- Add: `lsp-servers.yaml`
- Add: `scripts/test-lsp-support.sh`
- Add: `scripts/fixtures/lsp/` fixtures

**Focused behavior:** Build an image containing every selected server with stable commands on the non-interactive `PATH`.

**Test intent:** Verify the image installs the selected npm, system, Go, Rust, Swift, and Kotlin components and fails when an expected executable is missing.

**Inherited interfaces:** Existing Ubuntu base, Homebrew, mise runtimes, non-root `dev` user, and quota build stages.

**Out of scope:** Unjustified catalog servers and host-only Xcode/Android SDK workflows.

**Done when:** A built image exposes the complete selected executable set and documents/pins fragile toolchains.

**Review intent:** Check package provenance, architecture handling, layer size, non-root permissions, and PATH behavior.

**Cohesion override:** Keep installation and its smoke validation together because the executable contract is the single behavior being added to the image.

### Task 2: Add shared Polytoken LSP mappings

**Files:**
- Modify: `../polytoken/config.recommended.yaml` in the parent `claude-config` repository
- Test: `scripts/test-lsp-support.sh config` and `polytoken lsp check` against the generated temporary config

**Focused behavior:** Route supported file types to the selected servers with explicit language IDs and root markers.

**Test intent:** Verify configuration parses and representative file types select the intended server without conflicting primary mappings.

**Inherited interfaces:** `daemon.lsp` schema and the image commands from Task 1.

**Out of scope:** Project-specific Home Assistant schemas and editor-only formatting preferences.

**Done when:** A container session can discover all selected servers through explicit `daemon.lsp.servers` entries.

**Review intent:** Check exact command names, file-type routing, JSON/YAML ambiguity, linter-only behavior, and native server settings.

### Task 3: Document support and limitations

**Files:**
- Modify: `README.md`
- Test: `scripts/test-lsp-support.sh docs`

**Focused behavior:** Tell users what the image supports, how it was determined, how to validate it, and what native/Perl limitations remain.

**Test intent:** Verify every documented selected server is installed and every excluded category is clearly not claimed as supported.

**Inherited interfaces:** Docker image commands and Polytoken configuration from Tasks 1–2.

**Out of scope:** Documentation for unrelated MCP servers or host-side IDE integrations.

**Done when:** README accurately describes the language matrix, `ha-roku-cloud` correction, and Swift/Kotlin caveats.

**Review intent:** Check that documentation does not overclaim SDK/build support.

### Code Review: Final integration review

**Files:**
- Full branch diff.

**Focused behavior:** Review the complete implementation against this design and the user’s repo inventory.

**Test intent:** Identify and fix all valid Critical/Important integration findings before final validation.

**Done when:** A fresh branch-wide review passes, or all valid findings are addressed and rereviewed.

**Review intent:** Use the requesting-code-review workflow for a fresh final integration review.

### Finalize: Validate and prepare handoff

**Files:**
- Update: validation plan/documentation as needed.

**Focused behavior:** Run automated validation, record evidence, squash implementation commits, and provide manual validation steps.

**Test intent:** Automated checks pass; manual steps are concrete and reflect native SDK limitations.

**Done when:** Automated validation is green, commits are squashed per repository workflow, and manual validation is handed to the human without being marked complete by the agent.

**Review intent:** Do not claim completion without fresh verification evidence.
