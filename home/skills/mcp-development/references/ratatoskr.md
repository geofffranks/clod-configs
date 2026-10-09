# Ratatoskr gateway development

- **Source:** `<workspace>/ratatoskr`, Rust workspace with `gateway`, `mcp-client`
  and `lua-runtime`; gateway CLI/server entry point under `crates/gateway`.
  Read `AGENTS.md`, `Cargo.toml`, toolchain/config and `scripts/deploy.sh` first.
- **Dependencies/runtime:** current Rust toolchain (workspace presently requires
  Rust >=1.88), macOS host target and launchd supervisor. Inspect any native/link
  dependencies and run builds directly on this Mac; do not invent a cross-build
  recipe.
- **Development checks from the intended worktree:** `rtk cargo fmt --all --check`,
  `rtk cargo clippy --workspace --all-targets`, `rtk cargo test --workspace`.
  The current deploy script gates `cargo fmt --check`, clippy with all targets
  and all features, and `cargo test --all --quiet -- --include-ignored`.
  Inspect requirements before running host/integration tests.
- **Build/artifact:** host `cargo build --release` produces `target/release/rato`.
  The deploy script builds its own checkout's output; run directly on the Mac
  from the intended source worktree.
- **Configured destination:** leave native `~/.local/bin/rato` unchanged. Verify
  launchd `ProgramArguments` and source-to-runtime paths before installation.
- **Deploy/reload:** `scripts/deploy.sh` validates, builds, installs, bootouts and
  bootstraps `local.ratatoskr`, checks port release and post-restart listening.
  It needs Mac/launchd access and disrupts every connection. Only run with
  authorized full disruption, assessed pending configuration, affected owners,
  a retained usable rollback artifact and known supervisor/recovery route.
  Do not bypass gates or kill port holders without separate authority. If host
  access is missing, stage what is feasible and hand off; generic restart does
  not install or validate changed gateway code.
- **Read-only probe:** Ratatoskr `ping`, server discovery and schema/catalog
  inspection after recovery. Verify relevant changed gateway behavior safely
  or supported artifact/process identity before claiming the new build active;
  listening/ping alone establishes availability, not implementation identity.

## Upstream administration is not gateway deployment

`reload-config` applies the authorized upstream definition diff but skips
unchanged definitions except eligible login recovery. `reconnect-upstream`
forces a named upstream through the same reconciliation path. Both can apply
all pending additions/changes/removals and reconnect eligible `NeedsLogin` peers.
Inspect current config versus running state and assess the whole possible affected
set before either operation. Inaccessible host config requires pre-action
operator coordination. Post-action reporting does not grant prior authority.

Gateway-wide settings require an authorized restart; unchanged-code upstream
reconnects do not. Do not blindly run `setup-gateway.sh`: its generated settings
and upstream set may not match the operator's live configuration.

Source anchors for these semantics: `crates/gateway/src/handler/admin.rs`,
`crates/gateway/src/reconcile.rs`, and `crates/gateway/src/serve.rs` (shared disk
reconciliation and union of the explicit target with `NeedsLogin` peers).
