---
name: screenshots
description: Capture and hand off reachable screenshots for practical visual review.
---
# Screenshots

On the operator's Mac, save task screenshots under
`/Users/gfranks/workspace/screenshots/<branch-folder>/`; branch slashes may form
nested folders. This is operator runtime storage, never application code or
portable application configuration. Establish the actual capture host and
consumer-visible path; a mounted `/Users/...` directory on Linux is not proof of
Mac capture access. If the path is unavailable, coordinate an accessible location
with the owner rather than pretending the capture occurred. Configure the capture
tool's save directory before capture and verify the consuming agent can open it.
Native file/process capture needs no gateway discovery; actual Appium MCP capture
uses Ratatoskr list/schema/execute when available and the explicit owned session.

Supply absolute image paths and enough screen/state context to review: scenario,
route, visible state and relevant viewport/device. Reviewers must actually open
images using their image-capable file reader; filenames, summaries or raw base64
are not image review. If inaccessible, report the affected review limitation and
ask for an accessible capture, not an application redesign. Keep inline base64
responses disabled where the tool offers that choice.

No shasums, manifests, fixture preflight, clean-SHA prerequisite, forced immediate
deletion or cleanup-as-acceptance gate. Avoid sensitive information. Appearance
review does not establish interaction, device connectivity or production runtime
behavior; report what was actually observed. Coordinate capture with the assigned
shared-session owner rather than opening competing sessions.
