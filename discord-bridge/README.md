# Discord bridge host (configuration repo)

This directory installs the native macOS bridge host and its connector configuration. Runtime code lives in the separate `discord-pt-stream` repository.

## Install and update

Update both `claude-config` and `discord-pt-stream`, then run `bash discord-bridge/setup-bridge-host.sh` from this checkout. Restart the existing LaunchAgent and start/restart native sessions afterward; already running connectors need relaunch to load changed code/settings. The installer creates one shared environment at `~/.local/share/polytoken-discord/connector-venv` with the bridge host and connector extras; this is install-time provisioning, not startup pip. It installs the persistent headless launcher under `~/.config/polytoken/discord-bridge/`, writes the existing `local.polytoken-discord-bridge` LaunchAgent, and keeps checkout paths out of the installed plist except the explicitly configured runtime checkout.

Set `BRIDGE_REPO_DIR`, `BRIDGE_POLYTOKEN_BIN`, `BRIDGE_SESSIONS_DIR`, and (if needed) `BRIDGE_SETUP_PYTHON` when the defaults are not right. The host env file `~/.config/polytoken-discord.env` remains owner-only and keeps Discord secrets, guild/channel/operator IDs, and `BRIDGE_STATE_DB`. Installer reruns update obsolete relay advertisement and Python values to native absolute paths; they do not discard those identity or state values. The relay listener stays on loopback (default `127.0.0.1:8765`); a configured loopback port is preserved. Use lasting delivery checkouts for `BRIDGE_REPO_DIR`, not disposable effort worktrees. `BRIDGE_POLYTOKEN_CONFIG_DIR` / `BRIDGE_XDG_CONFIG_HOME` and `BRIDGE_XDG_DATA_HOME` select explicit native config/data roots.

Connector settings are separate in owner-only `~/.config/polytoken/discord-bridge/connector.json`, with `relay_address`, `relay_token`, `sessions_dir`, and `connector_python`. Existing relay token is reused from that JSON or the host env file. Do not copy Discord credentials to connector config. The installer writes an adjacent owner-only `connector.json.python` interpreter path so detached startup never discovers Python from PATH. Enable terminal-session attachment with `POLYTOKEN_BRIDGE_ENABLE=1` in the launching environment; `/spawn` enables its own hook. The session-start hook always immediately allows, starts detached only with opt-in and exact `POLYTOKEN_SESSION_ID`, and never scans for another session.

The host uses `scripts/polytoken-native.sh` for headless `/spawn`. Headless mode skips shell profiles, requires explicit trusted absolute binary/workspace/session roots, sanitizes ambient environment, and preserves exact CLI output. Interactive launcher behavior remains unchanged.

## Runtime operation

- Restart: `launchctl kickstart -k gui/$(id -u)/local.polytoken-discord-bridge`
- Stop/start: `launchctl bootout gui/$(id -u)/local.polytoken-discord-bridge` / `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.polytoken-discord-bridge.plist`
- Logs: `~/Library/Logs/discord-bridge.log` and `<sessions-root>/discord-bridge/<session-id>.log`
- Rotate Discord token in `~/.config/polytoken-discord.env`; rotate relay token in both the host env and connector JSON, then restart the host and affected sessions.

Native session termination is unavailable: the installed `polytoken reap` accepts a session ID but has no daemon-epoch fence and could terminate a replacement generation. `/kill` must report unavailable; use Polytoken's local session controls to stop a session. `/stop` only cancels the active turn.

## Short manual smoke check

Start a terminal session, run `/spawn` in an allowlisted project, send a prompt and answer a question, then test `/stop` during a turn. On a disposable session only, run `/kill` then `/kill confirm` and verify explicit unavailability; end it with local controls. This Linux delivery does not qualify actual Mac launchd or Discord behavior.

## Offline checks

`bash scripts/test-setup-bridge-host.sh` and `bash scripts/test-bridge-connector-autostart.sh` run without launchd or a live relay. `python3 scripts/test-polytoken-native.py` covers headless and interactive startup behavior.
