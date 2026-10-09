#!/usr/bin/env bash
# Native launcher; may later be selected as BRIDGE_SPAWN_LAUNCHER.
set +x
if ! shopt -q login_shell; then
  # Suppress automatic profiles so startup can be observed without tracing.
  exec bash --login --noprofile "$0" "$@"
fi
caller_cwd=$PWD
caller_args=("$@")
bashrc_loaded=0
set -T
trap 'for startup_source in "${BASH_SOURCE[@]}"; do [[ "$startup_source" != "$HOME/.bashrc" ]] || bashrc_loaded=1; done' DEBUG
if [[ -r /etc/profile ]]; then source /etc/profile; fi
for profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
  if [[ -r "$profile" ]]; then source "$profile"; break; fi
done
trap - DEBUG
set +T
# Conventional login files often source .bashrc themselves. If they replace
# the DEBUG trap, they should set bashrc_loaded=1 after sourcing it.
if [[ $bashrc_loaded == 0 && -r "$HOME/.bashrc" ]]; then source "$HOME/.bashrc"; fi
set +x
cd -- "$caller_cwd" || exit
# Bypass+ comes from default_permission_matcher: bypass_plus in user config.
# Project configuration can override it; this launcher never rewrites config.
if [[ ${POLY_SPAWN_HEADLESS:-0} == 1 ]]; then
  exec polytoken new --no-attach "${caller_args[@]}"
fi
exec polytoken "${caller_args[@]}"
