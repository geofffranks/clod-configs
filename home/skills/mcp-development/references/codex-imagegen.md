# Codex image generation MCP

- **Source:** `<workspace>/codex-imagegen-mcp`, root Go entry point `.`.
  Read `AGENTS.md`, `README.md`, `go.mod` and `scripts/validate.sh`.
- **Dependencies:** current Go manifest/toolchain; host-installed Codex CLI with
  appropriate login, configured `CODEX_BIN` and host session/image directories.
  Do not relocate Codex or expose credentials.
- **Checks:** `rtk go vet ./... && rtk go test ./...` in the intended worktree.
  Inspect `scripts/validate.sh` for race/protocol smoke coverage and environment
  requirements. Its smoke expects installed/logged-in Codex; real image E2E is
  opt-in. Do not treat credential absence as evidence of a Go source defect.
- **Native Mac staging build (verify architecture first):**
  `go build -o <staging-artifact> .`.
- **Configured destination:** operator-confirmed relocation is
  `<workspace>/codex-imagegen-mcp/bin/codex-imagegen-mcp`. Inspect current host
  launch config/mapping when accessible; older `~/go/bin` instructions do not
  override the relocation. Worktree output is separate from the launch artifact.
- **Reload:** reconnect discovered `codex_imagegen` after authorized installation
  and the shared workflow's full reconciliation/ownership assessment. If host
  config is inaccessible and impact cannot be established, coordinate first.
- **Cheap read-only probe:** inspect and execute `check_codex` through Ratatoskr.
  It reports dependency/version/login status, not image correctness or per-build
  MCP identity. Catalog/schema inspection alone cannot prove an unchanged
  implementation surface is serving the modified build.

Image generation is costly and writes output; it is not the default health check.
Run it only with specific task authority and relevant usage procedures. Report
source tests, installed artifact, reconnect and changed-behavior proof separately.
