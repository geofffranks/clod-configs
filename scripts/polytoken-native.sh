#!/usr/bin/env bash
# Native launcher. Headless child sessions bypass profiles; interactive startup is preserved.
set +x
caller_cwd=$PWD
caller_args=("$@")
if [[ ${POLY_SPAWN_HEADLESS:-0} == 1 ]]; then
  binary=${BRIDGE_POLYTOKEN_BIN:-${POLYTOKEN_BINARY:-}}
  roots=${BRIDGE_WORKSPACE_ROOT:-${POLYTOKEN_TRUSTED_ROOTS:-}}
  [[ -n $binary && $binary == /* && -x $binary && -n $roots && $roots == /* ]] || exit 1
  home=${HOME:-}
  [[ -n $home ]] || exit 1
  sessions=${BRIDGE_SESSIONS_DIR:-${POLYTOKEN_SESSIONS_DIR:-}}
  config_dir=${BRIDGE_POLYTOKEN_CONFIG_DIR:-${POLYTOKEN_CONFIG_DIR:-$home/.config/polytoken}}
  [[ -n $sessions && $sessions == /* && $config_dir == /* ]] || exit 1
  config_root=${BRIDGE_XDG_CONFIG_HOME:-${XDG_CONFIG_HOME:-${config_dir%/polytoken}}}
  data_root=${BRIDGE_XDG_DATA_HOME:-${XDG_DATA_HOME:-$home/.local/share}}
  config_allowlist=${BRIDGE_POLYTOKEN_CONFIG_DIRS:-$config_dir}
  [[ -n $config_root && $config_root == /* && -n $data_root && $data_root == /* && -n $config_allowlist ]] || exit 1
  clean_env=(env -i "HOME=$home" "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "XDG_CONFIG_HOME=$config_root" "XDG_DATA_HOME=$data_root" "BRIDGE_POLYTOKEN_BIN=$binary" "BRIDGE_SESSIONS_DIR=$sessions" "BRIDGE_WORKSPACE_ROOT=$roots" "BRIDGE_POLYTOKEN_CONFIG_DIR=$config_dir" "POLYTOKEN_CONFIG_DIRS=$config_allowlist" "POLYTOKEN_BRIDGE_ENABLE=1")
  [[ -n ${BRIDGE_CONNECTOR_CONFIG:-} ]] && clean_env+=("BRIDGE_CONNECTOR_CONFIG=$BRIDGE_CONNECTOR_CONFIG")
  cd -- "$caller_cwd" || exit
  exec "${clean_env[@]}" "$binary" new --sessions-dir "$sessions" --no-attach "${caller_args[@]}"
fi
if ! shopt -q login_shell; then
  exec bash --login --noprofile "$0" "${caller_args[@]}"
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
if [[ $bashrc_loaded == 0 && -r "$HOME/.bashrc" ]]; then source "$HOME/.bashrc"; fi
set +x
cd -- "$caller_cwd" || exit
exec polytoken "${caller_args[@]}"
