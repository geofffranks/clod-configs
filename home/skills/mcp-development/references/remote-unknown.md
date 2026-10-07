# Remote or unknown MCP services

Discover the server through Ratatoskr, list its actual tools and inspect schemas
before execution. Read its server instructions and authorized source/configuration
when available. Determine transport, source owner, runtime location and deployment
contract rather than inferring a local binary from the tool name.

Atlassian and Home Assistant in this setup are remote HTTP services, not local
stdio build artifacts. No relevant Home Assistant MCP source was identified.
Do not invent local tests, build entry points, architecture, artifacts, install
paths or deployment commands. Use the remote owner's real procedures when source
and deployment authority exist; otherwise report those access/source limits.

For a newly configured or unknown upstream, inspect real source, manifest,
transport and current configuration before adding a development recipe. Remote
behavior changes are not deployed by rebuilding a nearby repo or reconnecting the
gateway client. A cheap schema-inspected read-only call can establish connectivity,
not that an unobserved remote release is active.

Use auth-expiry reconnect only within task authority and the shared workflow's
pre-action full-impact/ownership assessment: even a named reconnect can reconcile
all pending local upstream config changes and other eligible `NeedsLogin` peers.
If inaccessible host config prevents establishing authorized impact, defer for
operator coordination before acting. Do not authenticate duplicate direct MCPs,
change remote resources, or restart unrelated servers to test these instructions.
