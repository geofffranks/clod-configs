# Foundry MCP tools

- **Source:** `<workspace>/foundry-mcp-tools`, Go entry point `./cmd/foundry-mcp`.
  Read `AGENTS.md`, current manifests and relay/module configuration guidance.
- **Dependencies:** Go toolchain from `go.mod`, configured relay connectivity,
  Foundry module/world availability and credentials. Relay/module installation
  is separate from replacing the MCP binary; do not disclose credential values.
- **Checks:** `rtk go build ./... && rtk go test ./...` in the intended worktree.
  Focused tool-catalog smoke:
  `rtk go test ./cmd/foundry-mcp/ -run TestServerListsTools`.
- **Native Mac staging build (verify architecture first):**
  `go build -o <staging-artifact> ./cmd/foundry-mcp`.
- **Configured destination:** operator-confirmed relocation is
  `<workspace>/foundry-mcp-tools/bin/foundry-mcp`. The older `AGENTS.md`
  `~/go/bin` destination is stale; do not restore it over current configuration.
  Confirm host command/mapping before installing. Worktree builds alone do not
  replace the launch artifact in another checkout.
- **Reload:** reconnect discovered `foundry` after authorized artifact replacement
  and the shared workflow's full pending-diff/NeedsLogin/owner assessment.
  Defer for operator coordination if inaccessible host state prevents it.
- **Cheap read-only probe:** discover and inspect a world-listing tool, then
  execute it only within task authority to check relay connectivity. Use its
  actual schema/name rather than guessing. Do not change a world/document to
  smoke-test deployment. World listing and tool catalog alone do not prove a
  changed implementation with unchanged surface is active.

Preserve a rollback artifact and coordinate any active Foundry work before
reconnection. Report missing relay/world access or safe changed-behavior evidence
as a limit, not as a successful live deployment.
