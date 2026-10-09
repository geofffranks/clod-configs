# iOS effort coordination MCP and native lifecycle

- **Source:** `<workspace>/ios-app-dev-mcp`, root Go entry point `.`.
  Read current `AGENTS.md`, `README.md`, `go.mod`, `scripts/build.sh` and the
  upstream example. Use the Go toolchain required by the current manifest.
- **Checks from the intended worktree:** `rtk go vet ./... && rtk go test ./...`.
  Available Linux source checks are not Mac execution or deployment verification.
- **Native Mac staging build (verify architecture first):**
  `go build -o <staging-artifact> .` on the Mac.
  `scripts/build.sh` may produce multiple target outputs; select the verified
  Mac artifact rather than installing an artifact for another OS.
- **Configured destination:** expected shared
  `<workspace>/ios-app-dev-mcp/bin/ios-app-dev-mcp`; confirm actual Mac command,
  arguments, environment and mapping before installation. An isolated worktree's
  `bin/` is not the main checkout launch location.
- **Retained executable:** Appium and native callers must use the compatible
  `ios-app-dev-mcp` executable, versioned shared authority protocol and the same
  user/state. Do not remove it because build tools are retired or create a second
  authority store. Consult the repo's supported native lifecycle procedure and
  application-owned policy for concrete invocation/help, readable logs, results,
  artifact identity, simulator/Metro ownership, cancellation and recovery.
  `xcode-native-checks` describes the shared safety contract, not application recipes.
- **Final MCP surface:** `effort_acquire`, `effort_status`, `effort_release`,
  `effort_recover`, `effort_operator_recover`. Discover the live catalog and inspect
  schemas; source intent is not proof the installed runtime has this surface.
  Operator recovery requires separate authority, not an automatic retry.
- **Retired execution families:** host/Git use native filesystem/process tools;
  build/test and preparation/dependencies/install use project-native policy plus
  supported lifecycle; simulator operations use selected-UDID native `simctl`
  procedures; Metro uses owned native service procedures; logs/process diagnostics
  use readable native files and targeted process inspection. These are not new MCP
  command names. Physical installs require separate device authority. If the
  documented replacement is unavailable, report the gap instead of guessing a
  command, bypassing ownership or treating retired wrappers as permanent fallback.
- **Reload:** reconnect discovered `ios_app_dev_mcp` only after authorized
  replacement and the shared workflow's full pending-config/NeedsLogin/ownership
  assessment. Defer if inaccessible Mac config prevents establishing that impact.
  Do not restart the gateway because an unchanged definition skips reload.
- **Cheap read-only probe:** inspect `effort_status` and use it only if its schema
  permits an authorized read-only query. Do not acquire an effort or touch a device
  merely as a health check. An unchanged catalog or selected application HEAD does
  not prove the MCP build identity; report live activation unverified without a
  safe changed-behavior probe or supported process/artifact identity.

Drain legacy MCP-owned asynchronous work and retain needed logs before a
reconnect into a tool-removal artifact. Old sessions/log references may be lost
and do not describe native runs. Coordinate ongoing work with its owners; never
cancel somebody else's work to deploy. Native producers/resources remain subject
to verified absence and recovery before release, even if the MCP process changes.
Source retirement, installed artifact, reconnect and live catalog verification
are separate facts. Without Mac host access or deployment authority, report the
remaining native/live checks and defer activation.
