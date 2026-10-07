# Appium MCP server

- **Source:** `<workspace>/appium-mcp`; TypeScript entry point `src/index.ts`.
  Read `AGENTS.md`, `package.json`, lockfile and TypeScript configuration.
- **Dependencies:** Node >=22 per current manifest, lockfile-compatible build
  dependencies, and host Appium/platform drivers. Runtime Node and native
  dependencies remain Mac-installed; inspect current host dependency resolution.
- **Checks:** `rtk npm run lint && rtk npm test` in the intended worktree.
- **Build:** `rtk npm run build` there. It removes/regenerates `dist/` and produces
  `dist/index.js` plus companion files. Stage the complete output separately.
- **Runtime/destination:** macOS host Node executes the configured script,
  expected `<workspace>/appium-mcp/dist/index.js`. Verify command, args and mapping.
  Building worktree `dist/` only installs it if that worktree is actually the
  launch location; do not assume it updates the main checkout's `dist/`.
- **Install:** preserve a rollback `dist/` and compatible dependency context.
  Replace the whole staged directory coherently at the authorized destination,
  not just `index.js`. Never copy Linux `node_modules`/native dependencies to Mac.
- **Reload:** reconnect discovered `appium` only after the shared workflow's
  full pending-config/NeedsLogin/owner assessment. Missing host visibility means
  pre-action operator coordination, not a blind named reconnect.
- **No-device probe:** inspect the live metadata/tool catalog; if exposed and
  authorized, inspect and execute read-only session inventory. Do not invent a
  health/version tool. An unchanged catalog or static version does not prove
  this build is running.

Load the existing `appium` skill for any automation/device work. Its device
exclusions and single-owner/shared-session rules remain in force. Disconnect
cleanup may skip session deletion, but that does not guarantee state survives
reconnection. Do not delete another owner's session. Changed automation behavior
may need separately authorized simulator testing; do not create sessions merely
to validate these development instructions.
