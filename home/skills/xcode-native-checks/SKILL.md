---
name: xcode-native-checks
description: Use available Apple host build surfaces for proportionate native preparation and checks.
---
# Xcode and native checks

Inspect ratatoskr's configured host surfaces before calling SwiftPM, Xcode,
CocoaPods or Expo unavailable merely because the container lacks those tools.
Discover servers, inspect tool schemas, then execute. No duplicate authentication.
Use project instructions for local dependency, Podfile and generated-project
requirements; keep generic facets free of native build sequences.

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

Use existing relevant checks, not a new framework or universal sequence. Explain
actual commands/results and unavailable/manual work. Build/signing/artifact
results are not physical runtime behavior; simulator results are renderer
observations only. Do not claim installation, BLE, GPS or camera functionality
without actually authorized relevant checks. Keep generated output and host paths
out of portable application configuration and committed validation reports.
