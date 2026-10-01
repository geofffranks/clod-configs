---
name: appium
description: Practical Appium setup, device selection, shared-session ownership and interaction checks.
---
# Appium

Use ratatoskr: discover the configured Appium surface, inspect each tool schema,
then execute. Select a task-relevant platform/device; ask when the choice matters
or project instructions require it. Do not perform unrelated discovery/operations.
Any capable assigned worker may own Appium. Assign one owner of the shared
device/session for the task; other agents consume captures or request bounded
interactions through that owner. Serialize shared-device operations.

Never use or suggest use of these devices; do not routinely report their non-use:
- maior-faca (`52E77D59-745F-5A6A-84D0-693FB6857B8F`)
- Geoffrey’s Apple Watch (`00008006-0009511A36A2002E`)
- iPhone (10) (`00008140-0016006E22BB001C`)
Do not exercise excluded devices as validation. Other device use still requires
relevant task authority; exclusions do not grant blanket device authority.

For iOS simulators, select the device, prepare it with the available host tool,
and use its returned WDA capability hint when creating the session. Ensure the
intended build is installed before judging changed behavior; use project build
procedures when needed. Inspect page source; prefer stable accessibility IDs,
then observed predicates/class chains, with XPath last. Exercise relevant flows,
states and recovery; report actual results and build/device context, not imagined
success. Screenshots follow `screenshots` and reviewers open the actual assets.

Delete task-created one-off sessions when finished unless the operator requests
retention. Do not delete somebody else's session. Cleanup is good resource
hygiene, not a visual-acceptance gate. Simulator screenshots/interactions establish
renderer behavior only, not BLE/GPS/camera/physical-device production behavior.
