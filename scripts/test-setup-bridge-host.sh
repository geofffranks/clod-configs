#!/usr/bin/env bash
# Scenario harness for discord-bridge/setup-bridge-host.sh. Everything runs
# against a fake $HOME with the bridge repo + toolchain stubbed (podman, curl,
# launchctl record/resolve), so no macOS, no launchd, no podman, no real pip
# install is required. Mirrors ratatoskr/setup-gateway.test.sh conventions.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../discord-bridge/setup-bridge-host.sh"

pass=0 fail=0
ok() { echo "  ok: $1"; pass=$((pass + 1)); }
no() { echo "  FAIL: $1"; fail=$((fail + 1)); }
sc() { echo; echo "=== $1 ==="; }

# make_sandbox — prints the fake home path. No globals.
make_sandbox() {
  local home
  home="$(mktemp -d)"
  mkdir -p "$home/workspace/discord-pt-stream/scripts" \
           "$home/.config" \
           "$home/Library/LaunchAgents" \
           "$home/Library/Logs"
  # Bridge repo stand-in: the wrapper (recording laptop) + pyproject stub.
  cat > "$home/workspace/discord-pt-stream/scripts/bridge-host.sh" <<'B'
#!/usr/bin/env bash
echo "bridge-host-ran" >> "$WRAPPERLOG"
exit 0
B
  chmod +x "$home/workspace/discord-pt-stream/scripts/bridge-host.sh"
  printf '%s\n' '[project]' 'name = "polytoken-discord-bridge"' 'version = "0.1.0"' \
    > "$home/workspace/discord-pt-stream/pyproject.toml"
  # Container env file to seed the relay token from (grep-not-source).
  printf 'ANTHROPIC_API_KEY=stub\nBRIDGE_RELAY_TOKEN="quoted-secret"\n' \
    > "$home/.config/polytoken-container.env"
  # Pre-seed the hosts alias so the real run takes the "already present" branch
  # (no sudo in the harness).
  printf '127.0.0.1 host.docker.internal # polytoken discord bridge: one URL for host + containers\n' \
    > "$home/hosts"
  printf '%s\n' "$home"
}

# make_stubbin — stub podman/curl/launchctl + a working python3; prints the bin path.
make_stubbin() {
  local bin="$1/stubbin"
  mkdir -p "$bin"
  # Poison the mise shim: the harness sets a fake HOME, which breaks mise's
  # python3 version resolution. Resolve a real absolute interpreter that still
  # works under a fake HOME and wrap it as local "python3".
  local realpy="" probe_home=""
  probe_home="$(mktemp -d)"
  for cand in /home/*/.local/share/mise/installs/python/*/bin/python3 \
              /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [ -x "$cand" ] && HOME="$probe_home" "$cand" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
      realpy="$cand"; break
    fi
  done
  if [ -z "$realpy" ] && command -v python3 >/dev/null 2>&1; then
    realpy="$(command -v python3)"
  fi
  [ -n "$realpy" ] || { echo "make_stubbin: no python3 found" >&2; return 1; }
  cat > "$bin/python3" <<PY
#!/usr/bin/env bash
exec "$(cd "$(dirname "$realpy")" && pwd)/$(basename "$realpy")" "\$@"
PY
  cat > "$bin/podman" <<'S'
#!/usr/bin/env bash
echo "podman $*" >> "$PODMANLOG"
exit 0
S
  cat > "$bin/curl" <<'S'
#!/usr/bin/env bash
echo "curl $*" >> "$CURLLOG"
echo "${CURLCODE:-200}"
exit "${CURLEXIT:-0}"
S
  cat > "$bin/launchctl" <<'S'
#!/usr/bin/env bash
if [ "$1" = "list" ]; then
  echo "local.polytoken-discord-bridge somepid"
else
  echo "launchctl $*" >> "$LCTLLOG"
fi
exit 0
S
  chmod +x "$bin"/*
  printf '%s\n' "$bin"
}

# run_setup SANDBOX STUBBIN ARGS...
run_setup() {
  local home="$1" bin="$2"; shift 2
  HOME="$home" PATH="$bin:$PATH" \
    BRIDGE_REPO_DIR="$home/workspace/discord-pt-stream" \
    BRIDGE_SETUP_HOSTS_FILE="$home/hosts" \
    BRIDGE_SETUP_SKIP_VENV=1 \
    BRIDGE_SETUP_SKIP_LAUNCHCTL=1 \
    WRAPPERLOG="$home/wrapper.log" PODMANLOG="$home/podman.log" \
    CURLLOG="$home/curl.log" LCTLLOG="$home/lctllog" \
    bash "$SCRIPT" "$@"
}

# --- B1: dry-run prints the plan, writes nothing ------------------------------
sc "B1 dry-run -> plan printed, nothing written, nothing run"
SBX="$(make_sandbox)"; STUB="$(make_stubbin "$SBX")"
out="$(run_setup "$SBX" "$STUB" --dry-run 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "dry-run exits 0" || no "dry-run exits 0 (got $rc)"
case "$out" in *"(dry-run)"*) ok "plan lines present" ;; *) no "plan lines present" ;; esac
[ ! -e "$SBX/.config/polytoken-discord.env" ] && ok "env file not written" || no "env file not written"
[ ! -e "$SBX/Library/LaunchAgents/local.polytoken-discord-bridge.plist" ] && ok "plist not installed" || no "plist not installed"
[ ! -e "$SBX/wrapper.log" ] && ok "wrapper not run" || no "wrapper not run"
case "$out" in *"quoted-secret"*) no "dry-run prints the seeded secret" ;; *) ok "dry-run does not print the token" ;; esac
rm -rf "$SBX"

# --- B2: missing podman fails loudly ------------------------------------------
sc "B2 missing podman -> nonzero exit, actionable message"
SBX="$(make_sandbox)"; STUB="$(make_stubbin "$SBX")"; rm "$STUB/podman"
out="$(run_setup "$SBX" "$STUB" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "missing podman exits nonzero" || no "missing podman exits nonzero"
case "$out" in *"podman not found"*) ok "message names podman and the fix" ;; *) no "message names podman and the fix" ;; esac
[ ! -e "$SBX/Library/LaunchAgents/local.polytoken-discord-bridge.plist" ] && ok "nothing installed" || no "nothing installed"
rm -rf "$SBX"

# --- B3: full run installs plist + env; token seeded by grep-not-source -------
sc "B3 full run -> env 0600, token seeded from container env, plist installed+linted"
SBX="$(make_sandbox)"; STUB="$(make_stubbin "$SBX")"
out="$(run_setup "$SBX" "$STUB" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "full run exits 0" || no "full run exits 0 (got $rc)"
ENV="$SBX/.config/polytoken-discord.env"
[ -f "$ENV" ] && ok "env file written" || no "env file written"
[ "$(stat -c %a "$ENV" 2>/dev/null)" = "600" ] && ok "env file is 0600" || no "env file is 0600"
grep -q 'BRIDGE_RELAY_TOKEN=quoted-secret' "$ENV" \
  && ok "relay token seeded from container env, quotes stripped" \
  || no "relay token seeded from container env"
grep -q '^BRIDGE_RELAY_BIND=127.0.0.1:8765$' "$ENV" \
  && ok "BRIDGE_RELAY_BIND defaults to 127.0.0.1:8765 (non-empty)" \
  || no "BRIDGE_RELAY_BIND defaults to 127.0.0.1:8765 (non-empty)"
grep -q '^BRIDGE_RELAY_ADVERTISE=ws://host.docker.internal:8765$' "$ENV" \
  && ok "BRIDGE_RELAY_ADVERTISE defaults to the one-literal URL (non-empty)" \
  || no "BRIDGE_RELAY_ADVERTISE defaults to the one-literal URL (non-empty)"
grep -q '^BRIDGE_REPO_DIR=' "$ENV" && ok "env carries BRIDGE_REPO_DIR" || no "env carries BRIDGE_REPO_DIR"
PLIST="$SBX/Library/LaunchAgents/local.polytoken-discord-bridge.plist"
[ -f "$PLIST" ] && ok "plist installed" || no "plist installed"
python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$PLIST" \
  && ok "plist is well-formed XML (python3 lint)" || no "plist is well-formed XML (python3 lint)"
grep -q "/Users/YOU" "$PLIST" && no "plist @HOME@ substituted" || ok "plist @HOME@ substituted"
grep -q "$SBX/workspace/discord-pt-stream/scripts/bridge-host.sh" "$PLIST" \
  && ok "plist points at the bridge wrapper" || no "plist points at the bridge wrapper"
grep -A1 "<key>PATH</key>" "$PLIST" | grep -q "$STUB" \
  && ok "plist PATH captured (podman reachable via it)" || no "plist PATH captured"
grep -q 'KeepAlive' "$PLIST" && ok "plist KeepAlive present" || no "plist KeepAlive present"
grep -A1 '<key>ThrottleInterval</key>' "$PLIST" | grep -q '10' \
  && ok "ThrottleInterval >= 10" || no "ThrottleInterval >= 10"
grep -q 'host.docker.internal' "$SBX/hosts" && ok "hosts alias in place" || no "hosts alias in place"
rm -rf "$SBX"

# --- B4: idempotent re-run; no duplicate hosts alias --------------------------
sc "B4 re-run -> plist byte-identical, hosts alias not duplicated"
SBX="$(make_sandbox)"; STUB="$(make_stubbin "$SBX")"
run_setup "$SBX" "$STUB" >/dev/null 2>&1
PLIST="$SBX/Library/LaunchAgents/local.polytoken-discord-bridge.plist"
before="$(sha256sum "$PLIST" | awk '{print $1}')"
h_before="$(grep -c 'host.docker.internal' "$SBX/hosts")"
out="$(run_setup "$SBX" "$STUB" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "re-run exits 0" || no "re-run exits 0 (got $rc)"
case "$out" in *"unchanged"*) ok "re-run reports unchanged" ;; *) no "re-run reports unchanged" ;; esac
after="$(sha256sum "$PLIST" | awk '{print $1}')"
[ "$before" = "$after" ] && ok "plist byte-identical across re-runs" || no "plist byte-identical across re-runs"
h_after="$(grep -c 'host.docker.internal' "$SBX/hosts")"
[ "$h_after" = "$h_before" ] && ok "hosts alias not duplicated ($h_before -> $h_after)" || no "hosts alias not duplicated"
rm -rf "$SBX"

# --- B5: --uninstall removes the plist only ------------------------------------
sc "B5 --uninstall -> plist removed, env/venv/logs left"
SBX="$(make_sandbox)"; STUB="$(make_stubbin "$SBX")"
run_setup "$SBX" "$STUB" >/dev/null 2>&1
PLIST="$SBX/Library/LaunchAgents/local.polytoken-discord-bridge.plist"
[ -f "$PLIST" ] && ok "plist present before uninstall" || no "plist present before uninstall"
out="$(run_setup "$SBX" "$STUB" --uninstall 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "uninstall exits 0" || no "uninstall exits 0 (got $rc)"
[ ! -f "$PLIST" ] && ok "plist removed" || no "plist removed"
[ -f "$SBX/.config/polytoken-discord.env" ] && ok "env file left in place" || no "env file left in place"
rm -rf "$SBX"

# --- B6: env file generation is additive/idempotent with existing values --------
sc "B6 existing env values preserved; token not overwritten from a stale container env"
SBX="$(make_sandbox)"; STUB="$(make_stubbin "$SBX")"
run_setup "$SBX" "$STUB" >/dev/null 2>&1
printf 'DISCORD_BOT_TOKEN=manual-bot-token\n' >> "$SBX/.config/polytoken-discord.env"
printf 'BRIDGE_RELAY_BIND=0.0.0.0:9999\n' >> "$SBX/.config/polytoken-discord.env"
printf 'BRIDGE_RELAY_ADVERTISE=ws://10.1.2.3:9000\n' >> "$SBX/.config/polytoken-discord.env"
# container env now has a different token; a re-run must keep the manual one.
printf 'BRIDGE_RELAY_TOKEN="other-token"\n' >> "$SBX/.config/polytoken-container.env"
run_setup "$SBX" "$STUB" >/dev/null 2>&1
grep -q 'DISCORD_BOT_TOKEN=manual-bot-token' "$SBX/.config/polytoken-discord.env" \
  && ok "existing manual value preserved across re-run" || no "existing manual value preserved across re-run"
grep -q 'BRIDGE_RELAY_TOKEN=quoted-secret' "$SBX/.config/polytoken-discord.env" \
  && ok "existing relay token preserved (not overwritten)" || no "existing relay token preserved"
grep -q '^BRIDGE_RELAY_BIND=0.0.0.0:9999$' "$SBX/.config/polytoken-discord.env" \
  && ok "explicit BRIDGE_RELAY_BIND preserved across re-run" || no "explicit BRIDGE_RELAY_BIND preserved across re-run"
grep -q '^BRIDGE_RELAY_ADVERTISE=ws://10.1.2.3:9000$' "$SBX/.config/polytoken-discord.env" \
  && ok "explicit BRIDGE_RELAY_ADVERTISE preserved across re-run" || no "explicit BRIDGE_RELAY_ADVERTISE preserved across re-run"
# Set-but-empty optional lines: a fresh explicit blank must be backfilled to the
# documented default (host.py would reject an empty BIND as "must be HOST:PORT").
run_setup "$SBX" "$STUB" >/dev/null 2>&1
sed -i.bak 's/^BRIDGE_RELAY_BIND=.*/BRIDGE_RELAY_BIND=/' "$SBX/.config/polytoken-discord.env"
run_setup "$SBX" "$STUB" >/dev/null 2>&1
rm -f "$SBX/.config/polytoken-discord.env.bak"
grep -q '^BRIDGE_RELAY_BIND=127.0.0.1:8765$' "$SBX/.config/polytoken-discord.env" \
  && ok "set-but-empty BRIDGE_RELAY_BIND backfilled to default" || no "set-but-empty BRIDGE_RELAY_BIND backfilled to default"
rm -rf "$SBX"

# --- B7: BRIDGE_REPO_DIR override is reflected in the installed plist (BRD-6) ---
sc "B7 non-default BRIDGE_REPO_DIR -> plist wrapper path honors the override"
SBX="$(make_sandbox)"; STUB="$(make_stubbin "$SBX")"
# A non-default repo location: the plist must point at it, not at the default.
ALT="$SBX/alt/bridge-repo"
mkdir -p "$ALT/scripts"
cp "$SBX/workspace/discord-pt-stream/scripts/bridge-host.sh" "$ALT/scripts/bridge-host.sh"
cp "$SBX/workspace/discord-pt-stream/pyproject.toml" "$ALT/pyproject.toml"
HOME="$SBX" PATH="$STUB:$PATH" \
  BRIDGE_REPO_DIR="$ALT" \
  BRIDGE_SETUP_HOSTS_FILE="$SBX/hosts" \
  BRIDGE_SETUP_SKIP_VENV=1 BRIDGE_SETUP_SKIP_LAUNCHCTL=1 \
  WRAPPERLOG="$SBX/wrapper.log" PODMANLOG="$SBX/podman.log" \
  CURLLOG="$SBX/curl.log" LCTLLOG="$SBX/lctllog" \
  bash "$SCRIPT" >/dev/null 2>&1
PLIST="$SBX/Library/LaunchAgents/local.polytoken-discord-bridge.plist"
grep -q "$ALT/scripts/bridge-host.sh" "$PLIST" \
  && ok "plist wrapper path honors BRIDGE_REPO_DIR override" \
  || no "plist wrapper path honors BRIDGE_REPO_DIR override"
rm -rf "$SBX"

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
