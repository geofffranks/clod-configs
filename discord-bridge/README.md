# Discord bridge host (claude-config side)

This directory wires the **Mac host side** of the Polytoken Discord bridge. The
bridge code itself lives in the separate `discord-pt-stream` repo
(`discord_bridge.*`); this directory owns everything *around* the host process:

| File | Purpose |
|---|---|
| `setup-bridge-host.sh` | One-shot deploy: Mac venv + 0600 env file + launchd agent + smoke check |
| `local.polytoken-discord-bridge.plist.example` | LaunchAgent template (KeepAlive, ThrottleInterval 10, PATH incl. podman) |
| `scripts/test-setup-bridge-host.sh` | Offline fake-HOME harness for the setup script (no macOS required) |

## What it gives you

- **Reliable host startup.** `local.polytoken-discord-bridge` launchd agent runs
  `/bin/bash ${BRIDGE_REPO_DIR}/scripts/bridge-host.sh` with KeepAlive +
  ThrottleInterval, so the relay + Discord bot survives crashes without a tight
  crash loop and restarts automatically on a Mac reboot.
- **A dedicated 0600 env file** `~/.config/polytoken-discord.env` — not the
  container `--env-file` — with the host variables the bridge needs
  (`DISCORD_*`, `BRIDGE_RELAY_BIND`, `BRIDGE_RELAY_ADVERTISE`,
  `BRIDGE_RELAY_TOKEN`, `BRIDGE_STATE_DB`, `BRIDGE_HOST_PYTHON`,
  `BRIDGE_REPO_DIR`).
- **Token seeding by grep-not-source.** `BRIDGE_RELAY_TOKEN` is copied from
  `~/.config/polytoken-container.env` by `grep` (the file is data, never
  sourced), so the container and host stay in sync without a manual copy.
- **A Mac venv** at `~/.local/share/polytoken-discord/venv`, installed
  fingerprint-keyed and editable from the bridge repo (`pip install -e
  '…[live]'`), so code changes need no reinstall.

## Install / update

```sh
cd claude-config
bash discord-bridge/setup-bridge-host.sh
```

Then fill the env file (Discord secrets stay 0600):

```sh
nano ~/.config/polytoken-discord.env     # DISCORD_BOT_TOKEN, guild/channel/user ids, …
launchctl kickstart -k gui/$(id -u)/local.polytoken-discord-bridge
```

Other modes:

```sh
bash discord-bridge/setup-bridge-host.sh --dry-run     # print the plan, change nothing
bash discord-bridge/setup-bridge-host.sh --uninstall   # unload + remove the agent/plist
```

## Container side

The connector auto-start inside polytoken-dev containers is a separate
`session_start` hook (`polytoken/hooks/bridge-connector-autostart.sh`),
registered in `polytoken/hooks.json`. It is fail-open and never blocks a
session. See the bridge repo README's connector sections and
`polytoken-container/.env.example` for the container-side variables
(`BRIDGE_RELAY_TOKEN`, `BRIDGE_RELAY_ADDRESS`, optional `BRIDGE_CONNECTOR_*`
overrides).

## Rotation

- **`DISCORD_BOT_TOKEN`**: edit `~/.config/polytoken-discord.env`, then
  `launchctl kickstart -k gui/$(id -u)/local.polytoken-discord-bridge`.
- **`BRIDGE_RELAY_TOKEN`**: edit **both** `~/.config/polytoken-discord.env`
  and `~/.config/polytoken-container.env`, kickstart the agent, and relaunch a
  container session (the container side only reads its env file at launch —
  no hot path). Sync check one-liner:

  ```sh
  grep -c '^BRIDGE_RELAY_TOKEN=' ~/.config/polytoken-discord.env \
    && grep -c '^BRIDGE_RELAY_TOKEN=' ~/.config/polytoken-container.env
  ```

## Toggle / logs

- Stop: `launchctl bootout gui/$(id -u)/local.polytoken-discord-bridge`
- Start: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.polytoken-discord-bridge.plist`
- Logs: `~/Library/Logs/discord-bridge.log`

## Test the setup script offline

```sh
bash scripts/test-setup-bridge-host.sh
```

Runs against a fake HOME with stubbed `podman`/`curl`/`launchctl` + a real
python3 — no macOS, launchd, pip install, or podman required. Asserts plist XML
well-formedness, cmp-idempotency across re-runs, `--dry-run`/`--uninstall`
behavior, env-file 0600 mode, and grep-not-source token seeding.
