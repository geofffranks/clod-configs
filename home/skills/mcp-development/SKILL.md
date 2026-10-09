---
name: mcp-development
description: Use when modifying, building, testing or deploying MCP server code, including isolated worktree builds and Ratatoskr development reloads.
---
# MCP development

Use this workflow for MCP server development, not ordinary tool use. Read only
the relevant companion with `file_read`, resolving links relative to this skill:
- [iOS host tooling](references/ios.md)
- [Appium server](references/appium.md)
- [Codex image generation](references/codex-imagegen.md)
- [Foundry tools](references/foundry.md)
- [Ratatoskr gateway](references/ratatoskr.md)
- [Remote or unknown services](references/remote-unknown.md)

## Establish source, runtime and authority

1. Read the selected repo's current instructions, manifests and build scripts.
   Confirm the intended source worktree, change and focused checks. These guides
   are starting recipes; resolve drift against current source and configuration.
2. Native reads, Git, development commands and project scripts need no gateway
   discovery. For actual MCP work, discover Ratatoskr servers, list tools, inspect
   schemas, then execute with configured Lua names when available. Do not guess
   names or authenticate duplicate connections. Tool access and this skill do not
   grant installation, restart, device or host-access authority. Read-only
   reviewers/designers remain read-only.
3. Identify separately: source root, staging output, configured launch artifact,
   source-to-runtime paths, actual execution OS/architecture, runtime host and
   dependencies. On macOS run directly with the user's configured environment.
   Linux checks of mounted source are not Mac runtime verification; do not claim
   Xcode/device access or stage Linux native dependencies as Mac deployment.
   `<workspace>` means the discovered workspace, not a literal path. `~` in Mac
   host instructions means that user's home, not a Linux session's HOME.
4. Current Ratatoskr launch command/args/env are authoritative. The Mac config is
   normally `~/Library/Preferences/ratatoskr/config.json` (`mcpClients`). It is
   native user configuration; inspect it directly. Operator-confirmed relocation puts
   iOS, codex-imagegen and Foundry artifacts in their sibling repos' `bin/`
   directories; older `~/go/bin` instructions are stale, not permission to revert
   that relocation. Binary presence or discovery alone does not verify active
   host config or the running process's artifact identity. If you cannot inspect
   required host state, obtain operator coordination before a runtime action.

## Test and stage from the intended worktree

Run the selected repo's focused checks there, with RTK wrapping where supported.
Build directly on the Mac into a separate staging location for the verified
runtime target. Inspect format and architecture (for example
`file <staging-artifact>`) before installation; an artifact for another OS or
architecture is not a deployable Mac build.

A worktree build does not update the launch artifact in the main checkout.
Never switch checkout or merge source merely to deploy. For Appium, stage the
complete `dist/` output, not just `index.js`; keep runtime dependencies compatible
with the native Mac build. Keep native Node/Codex installations
and dependency resolution intact.

## Install only with explicit deployment authority

Coordinate ownership of the shared runtime and affected sessions before replacing
artifacts. Determine whether active work permits disruption; if it does not,
defer. Do not stop/delete another owner's sessions or use excluded devices. No
global deployment lock is assumed. iOS process-owned sessions/log references may
be lost; Appium's disconnect cleanup skip does not guarantee state survival.

If deployment is authorized and the destination is accessible, retain a usable
rollback artifact and dependency context, verify staged output, then replace the
explicit configured artifact coherently. Use a complete staged directory for
Appium and avoid leaving mixed old/new files. Record the installed destination
and artifact evidence. If access, mapping or authority is missing, report the
staged artifact and hand off the install instead of inventing host tooling.

## Assess the full impact BEFORE reconnect or reload

A named Ratatoskr `reconnect-upstream` is not necessarily single-server-only.
Current code reconciles **all** pending on-disk upstream additions, changes and
removals, and can also reconnect other eligible `NeedsLogin` upstreams. Before
any reconnect/reload, establish pending unrelated config edits, the possible
full affected set, active work/session owners, authority and a recovery route.
Coordinate with affected owners; do not apply somebody else's pending edits
merely because your own artifact is ready. If that impact cannot be established
(including inaccessible host config), **defer for operator coordination before
acting**. A post-action report of side effects is not pre-action authorization.

Once that assessment is complete and the operation is authorized:
- **Changed stdio artifact, unchanged definition:** after installation, use named
  `reconnect-upstream` to re-exec it. `reload-config` skips unchanged definitions
  except eligible login recovery; it does not deploy rebuilt code by itself.
- **Upstream definition changes:** use `reload-config` for the authorized diff,
  still assessing all pending changes and eligible `NeedsLogin` peers first.
- **Gateway code or gateway-wide settings:** restart only with authorized full
  disruption, installed code when relevant, and a known supervisor/recovery route.
  A gateway restart is not a substitute for upstream deployment.
- **Auth/token expiry:** named reconnect remains a recovery option within task
  authority and the same full-impact safeguards; do not authenticate a duplicate.

Inspect the actual returned reconciliation report and failures. Do not call an
operation successful when it failed or silently retry with a broader restart.
Do not run the old `setup-gateway.sh` against an existing installation: its
server set/settings may differ from the operator's current configuration.

## Verify and report distinct facts

Use Ratatoskr discovery, `list-server-tools`, `tool-details`, then schema-inspected
execution of a cheap read-only probe within authority. Inspect every upstream
tool before invoking it in an `execute` script. Prefer relevant changed-behavior
evidence; a tool list proves the surface only when implementation changed but
schema did not. Static version strings are not per-build identity. Do not invent
a version tool or run image generation/device sessions merely as health checks.
If no safe changed-behavior probe or supported artifact/process identity exists,
report that the modified build's activation remains unverified.

Report separately: **source updated**, **tests passed**, **artifact staged**,
**artifact installed**, **process reloaded**, **live changed behavior verified**.
Name actual checks and limits. Successful local tests, copied files, reload
responses and live catalog listings are different evidence.

For guidance changes themselves, validate skills/definitions with `polytoken
validate`; review instructions with scenarios rather than phrase tests. Source
edits, targeted skill installation and Polytoken activation are separate too.
Before any authorized guidance installation, inspect the real target Mac's
active config/discovery roots and compare installed instructions/skills with
canonical source. Do not infer the target from Linux HOME or install there as a
substitute. Preserve custom instructions/definitions, providers/models/quota,
permissions, hooks and MCP settings. Refresh only assigned files and companions,
with backups; migrate retired installed copies reversibly only with explicit
authority. The installer already copies companions recursively, but a broad live
installer/config merge is not a scoped guidance refresh. If host configuration
is inaccessible, report installation/activation pending for operator coordination.
Activate approved installed guidance through startup or authorized
`/daemon-reload`, not a Ratatoskr restart. Check affected session owners before
a daemon reload; it is separate from an upstream reconnect.
