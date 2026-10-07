# iOS host tooling MCP

- **Source:** `<workspace>/ios-app-dev-mcp`, root Go entry point `.`.
  Read `AGENTS.md`, `README.md`, `go.mod`, `scripts/build.sh` and the upstream
  example. Use the Go toolchain required by the current manifest.
- **Checks from the intended worktree:** `rtk go vet ./... && rtk go test ./...`.
- **Mac arm64 staging build from Linux:**
  `GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -o <staging-artifact> .`.
  `scripts/build.sh` also produces Linux and Darwin outputs; identify which is
  deployable rather than installing the native Linux result.
- **Configured destination:** expected shared
  `<workspace>/ios-app-dev-mcp/bin/ios-app-dev-mcp`; confirm actual host command
  and mapping before installation. An isolated worktree's `bin/` is not the
  main checkout launch location.
- **Dependencies:** the server is a Mac-host stdio process; native tool calls
  depend on the configured host repo mapping and Xcode/Swift/Node/CocoaPods as
  relevant. Building the Go server does not prepare an iOS application.
- **Reload:** named reconnect for discovered `ios_app_dev_mcp` after authorized
  replacement and the shared workflow's full-impact/ownership assessment.
  Defer if inaccessible host config prevents establishing that impact. Do not
  restart the gateway simply because an unchanged definition skips reload.
- **Cheap read-only probe:** inspect `mac_status`'s schema and call it through
  Ratatoskr. Its selected target-repo HEAD is not the MCP source build identity.
  Inspect changed descriptions/arguments when applicable; unchanged surfaces
  need safe changed-behavior or supported process/artifact identity evidence.

Reconnection may lose process-owned asynchronous sessions and log references.
Coordinate ongoing native builds/tests and ownership first; never cancel another
owner's work to make deployment convenient. Native preparation, simulator and
app testing require separate task authority and applicable host procedures.
