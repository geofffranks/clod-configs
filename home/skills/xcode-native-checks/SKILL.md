---
name: xcode-native-checks
description: Use available Apple host build surfaces for proportionate native preparation and checks.
---
# Xcode and native checks

Use native filesystem/process tools and repository-owned scripts from the
intended worktree. Reads, Git, dependencies and direct checks need no gateway
discovery. On macOS, run SwiftPM, Xcode, CocoaPods and Expo with the user's
configured shell/toolchain; do not substitute container launchers or hardcoded
toolchain paths. Establish the actual OS first: a Linux session or mounted Mac
path does not provide Xcode, a Mac simulator or proof of Mac runtime behavior.
Run only available checks and report the remaining native checks explicitly.

Project instructions/scripts own preparation, warnings policy, build/test
selection, destinations and artifact reporting. Read their current documentation
and help; do not translate retired iOS MCP build/test tools into guessed commands.
Use the supported native lifecycle procedure documented by `ios-app-dev-mcp`
with the project's policy entry point. If that replacement contract is missing
or unavailable, report the blocked operation rather than bypassing ownership.
Actual MCP use still follows Ratatoskr list/schema/execute when available; do not
create a duplicate authenticated connection. Keep generic guidance free of
application-specific build recipes.

Never use or suggest use of these devices; do not routinely report their non-use:
- maior-faca (`52E77D59-745F-5A6A-84D0-693FB6857B8F`)
- Geoffrey’s Apple Watch (`00008006-0009511A36A2002E`)
- iPhone (10) (`00008140-0016006E22BB001C`)
Do not exercise excluded devices as validation. Avoid unrelated device discovery
or operations; other device work requires task authority.

Serialize operations sharing generated native projects. Prepare dependencies,
prebuild and install pods only when changed dependencies/registration/config or
current project state requires it. For source-only changes prefer affected
SwiftPM tests, typecheck and a relevant native build. Rerun failed checks after
repair and dependent checks whose inputs/behavior changed; commit IDs alone do
not invalidate checks. Preserve observed failures in reporting.

## Shared native operations

Managed generated-tree, build/test, install, simulator and Metro mutations use
the retained `ios-app-dev-mcp` executable/shared authority, the same executable,
user and state as Appium. Independent JS checks and read-only inspection do not
reserve a simulator. Preserve the canonical worktree, actual parent session
(not a worker's invented session), explicitly authorized simulator UDID where
needed, and stable operation identity. Keep acquisition context stable and
private across calls, in narrowly permissioned runtime input/descriptors; never
put credentials in argv, inherited environment, logs or committed files.

Only fresh admission permits launch. Busy/deferred, prior-started/completed,
lost-response or uncertain-start results are not permission to retry or launch
through a raw shell. Uncertainty remains recovery-required; use documented
recovery and separately authorized operator recovery, never force-unlock or edit
shared state to clear ownership. Do not wrap Appium calls in another admission:
Appium already admits its own operations.

Use the supported lifecycle's durable intent, held launch/registration handshake
and verified completion procedure, binding the stable producer and all owned
process groups to the operation before child execution. A shell PID, trap or
Polytoken job ID is not proof of ownership or child teardown. Cancellation/deadline
must stop, reap and independently verify absence of all owned groups/descendants,
then complete required restoration/log
cleanup before finishing or releasing. Host loss or uncertain cleanup retains
recovery-required state. Keep actual exit status and directly readable logs;
report the exact produced artifact path, product/configuration and runtime
identity from the build result, not a guessed or old `.app` found by globbing.

Use native `simctl` only for the selected authorized simulator through the
project lifecycle procedure; physical `devicectl` work needs separate authority.
Preserve prebooted devices and operator services. Record effort-owned boot and
Metro listener/group/birth identity, and bind Metro to the intended worktree,
endpoint and runtime identity where supplied. Use supported foreground ownership,
not untracked `nohup` services. With the assigned Appium owner, clean up owned
session, WDA, effort-booted simulator, then owned Metro; independently verify
absence before releasing. Do not reset app data, erase devices, replace WDA or
stop another owner's resources as a fallback.

## Results

Use existing relevant checks, not a new framework or universal sequence. Explain
actual commands/results and unavailable/manual work. Build/signing/artifact
results are not physical runtime behavior; simulator results are renderer
observations only. Do not claim installation, BLE, GPS or camera functionality
without actually authorized relevant checks. Keep generated output and host paths
out of portable application configuration and committed validation reports.
