---
name: appium
description: Practical Appium setup, device selection, shared-session ownership and interaction checks.
---
# Appium

For Appium MCP calls, use ratatoskr when available: list configured servers/tools,
inspect each tool schema, then execute with the discovered names. Native files,
processes and project scripts do not need gateway discovery. If Appium or host
access is unavailable, report the limitation; do not open a duplicate authenticated
connection or claim local Linux execution is a Mac simulator check.

Select an explicitly authorized task-relevant platform/device/UDID; ask when the
choice matters or project instructions require it. Do not perform unrelated
discovery/operations or implicitly choose a physical device. Any capable assigned
worker may own Appium. Assign one owner of the shared device/session, including
captures and cleanup; other agents consume reachable captures or request bounded
interactions through that owner. Pass the explicit owned session ID for each
interaction instead of relying on a default/current session. Serialize operations.

Appium already admits its operations through the retained `ios-app-dev-mcp`
executable/shared authority; do not double-wrap its calls. Native project work
uses that same executable, user and state under `xcode-native-checks` and project
policy. Preserve the actual parent session, canonical worktree, assigned UDID,
stable private acquisition context and operation identity across native/Appium
work. Busy/deferred or uncertain results are not passes or permission to retry,
force-unlock, reset, bypass through shell or create a competing session. Follow
supported recovery; operator recovery requires separate authority.

Never use or suggest use of these devices; do not routinely report their non-use:
- maior-faca (`52E77D59-745F-5A6A-84D0-693FB6857B8F`)
- Geoffrey’s Apple Watch (`00008006-0009511A36A2002E`)
- iPhone (10) (`00008140-0016006E22BB001C`)
Do not exercise excluded devices as validation. Other device use still requires
relevant task authority; exclusions do not grant blanket device authority.

For iOS simulators, use Appium's retained `prepare_ios_simulator` for the assigned
UDID and its returned WDA capability hint when creating the session. Inspect the
live schema first. Preserve pending creation intent, returned ownership/readiness
diagnostics and WDA listener/process binding; no reset or WDA-replacement fallback.
Application preparation/build/install and Metro use project-native policy, not
retired iOS MCP build tools. Verify the exact intended artifact/bundle and runtime
identity are installed before judging changed behavior; use `xcode-native-checks`
and project procedures when needed. Inspect page source; prefer stable
accessibility IDs, then observed predicates/class chains, with XPath last.
Exercise relevant flows,
states and recovery; report actual results and build/device context, not imagined
success. Screenshots follow `screenshots` and reviewers open the actual assets.

The assigned owner deletes task-created one-off sessions when finished unless
the operator requests retention. Then use Appium's retained
`cleanup_ios_simulator` within its schema/ownership contract for owned WDA and
boot cleanup, followed by project-native cleanup of owned Metro and verified
effort release. Coordinate Appium and native boot ownership so cleanup happens
once, not through competing teardown paths. Preserve prebooted devices, operator
Metro and somebody else's sessions/WDA. Independently verify owned resource
absence before release; a lost response or unresolved producer/process remains
recovery-required, not permission for force cleanup.

Cleanup is resource hygiene, not a visual-acceptance gate. Report retained or
uncertain resources separately. Simulator screenshots/interactions establish
renderer behavior only, not BLE/GPS/camera/physical-device production behavior.
