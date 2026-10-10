#!/usr/bin/env bash
# Local-only authoring/install checks; never touch the user's LaunchAgent or Jira.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/scripts/install-jira-dispatcher.sh"
PLIST="$ROOT/launchd/dev.gf.polytoken-jira-dispatcher.plist"
FACET="$ROOT/polytoken/facets/queued-registration.md"
DESIGN="$ROOT/polytoken/facets/product-design.md"
for dependency in python3 git polytoken plutil; do
  command -v "$dependency" >/dev/null || { echo "missing dependency: $dependency" >&2; exit 1; }
done
bash -n "$INSTALLER" "$ROOT/scripts/test-jira-dispatcher-facets-install.sh"
plutil -lint "$PLIST"
polytoken validate facet "$FACET"
polytoken validate facet "$DESIGN"

# Requested content checklist; behavior/authority still requires human review.
grep -Fq 'before calling `handoff_plan`, explicitly choose' "$DESIGN"
grep -Fq 'queued uses `queued-registration`' "$DESIGN"
grep -Fq 'interactive uses `queued-registration`' "$DESIGN"
grep -Fq 'Call `handoff_plan` by itself with `queued-registration` when Jira is supplied;' "$DESIGN"
grep -Fq 'publish the complete approved plan and move Plannable → Ready, then ends' "$DESIGN"
grep -Fq 'registration without switching to delivery;' "$DESIGN"
grep -Fq 'Plannable → In Progress and switch to the selected' "$DESIGN"
grep -Fq 'handing off immediately without queue enrollment.' "$DESIGN"
grep -Fq 'Queued route: publish the complete approved plan under `## Approved delivery plan`' "$FACET"
grep -Fq 'Delivery mode: queued' "$FACET"
grep -Fq 'move Plannable → Ready' "$FACET"
grep -Fq 'End registration at Ready without switching to delivery;' "$FACET"
grep -Fq 'Interactive route: publish the complete accepted plan' "$FACET"
grep -Fq 'move Plannable → In Progress' "$FACET"
if grep -Eiq '(^|[[:space:]])implement([[:space:].,;:]|$)' "$FACET"; then
  echo "registration facet must not direct implementation" >&2; exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/jira-dispatcher-install.XXXXXX")"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$tmp"' EXIT
# Author test doubles through Python file APIs, not a live service operation.
python3 -c 'import pathlib,sys; b=pathlib.Path(sys.argv[1])/"bin"; b.mkdir(); p=b/"launchctl"; p.write_text("#!/bin/sh\nprintf \"%s\\n\" \"$*\" >> \"$LAUNCHCTL_TEST_LOG\"\n"); p.chmod(0o755)' "$tmp"
export LAUNCHCTL_TEST_LOG="$tmp/launchctl.log"
original_path="$PATH"
export PATH="$tmp/bin:$original_path"
export HOME="$tmp/home & operator"
mkdir -p "$HOME"
DATA="$HOME/.local/share/polytoken/jira-dispatcher"
DST="$HOME/Library/LaunchAgents/dev.gf.polytoken-jira-dispatcher.plist"

bash "$INSTALLER" --print > "$tmp/rendered.plist"
plutil -lint "$tmp/rendered.plist"
[ ! -e "$DATA" ]
[ ! -e "$LAUNCHCTL_TEST_LOG" ]
python3 -c 'import plistlib,sys; p=plistlib.load(open(sys.argv[1],"rb")); assert p["ProgramArguments"]==["/usr/bin/env","python3",sys.argv[2]+"/.local/share/polytoken/jira-dispatcher/lib/dispatcher.py","run"]; assert p["RunAtLoad"] is True and p["KeepAlive"] is False; assert sys.argv[2]+"/.local/bin" in p["EnvironmentVariables"]["PATH"]' "$tmp/rendered.plist" "$HOME"

mkdir -p "$tmp/missing-bin"
ln -s /usr/bin/dirname "$tmp/missing-bin/dirname"
ln -s "$(command -v python3)" "$tmp/missing-bin/python3"
if HOME="$tmp/missing-home" PATH="$tmp/missing-bin" /bin/bash "$INSTALLER" > "$tmp/missing.log" 2>&1; then
  echo "missing git/polytoken must fail closed" >&2; exit 1
fi
grep -q 'missing dependency: git' "$tmp/missing.log"
[ ! -e "$tmp/missing-home/.local/share/polytoken/jira-dispatcher" ]

bash "$INSTALLER"
plutil -lint "$DST"
for source in "$ROOT/jira-dispatcher"/*.py "$ROOT/jira-dispatcher/DESIGN.md" "$ROOT/jira-dispatcher/README.md"; do
  cmp "$source" "$DATA/lib/$(basename "$source")"
done
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["active"] is False' "$DATA/config.json"
python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); c["operator_note"]="preserve existing customization"; open(p,"w").write(json.dumps(c,indent=2)+"\n")' "$DATA/config.json"
cp "$DATA/config.json" "$tmp/config-before.json"
bash "$INSTALLER"
cmp "$tmp/config-before.json" "$DATA/config.json"
grep -q 'bootstrap' "$LAUNCHCTL_TEST_LOG"
bash "$INSTALLER" --uninstall
[ ! -e "$DST" ]
[ -f "$DATA/config.json" ]
[ -f "$DATA/lib/dispatcher.py" ]
if bash "$INSTALLER" --unknown > "$tmp/unknown.log" 2>&1; then
  echo "unknown flags must fail" >&2; exit 1
fi

echo "PASS: shell syntax, plist rendering, facet validation/checklist, runtime copies, inactive default, preserved config and reversible uninstall"
