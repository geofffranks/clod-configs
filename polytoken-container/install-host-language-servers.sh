#!/usr/bin/env bash
set -euo pipefail

# Install the language servers included in the Polytoken Docker image onto macOS.
# Servers are started by Polytoken on demand; this script only installs them.

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is for macOS." >&2
  exit 1
fi

for tool in brew npm node; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing prerequisite: $tool" >&2
    exit 1
  fi
done

# Match the npm package versions in polytoken-container/Dockerfile.
npm install --global \
  typescript@5.8.3 \
  typescript-language-server@5.3.0 \
  pyright@1.1.400 \
  yaml-language-server@1.19.0 \
  bash-language-server@5.4.0 \
  vscode-langservers-extracted@4.10.0 \
  dockerfile-language-server-nodejs@0.15.0 \
  @olrtg/emmet-language-server@2.4.0

# Native macOS packages.
brew install lua-language-server marksman rust-analyzer

# The Homebrew Kotlin LSP cask currently uses a CDN URL that returns 404 on
# Apple Silicon. Install the same signed release archive via JetBrains' working
# download host, checking it against Homebrew's published SHA-256.
kotlin_lsp_version='263.6379.0'
kotlin_lsp_sha256='ebef2e13cd4adc4ec9e04084b848000a3ec7a9d2917c64f269574ce2efe9ecad'
kotlin_lsp_url="https://download.jetbrains.com/language-server/kotlin-server/${kotlin_lsp_version}/kotlin-server-${kotlin_lsp_version}-aarch64.sit"
kotlin_lsp_prefix="$(brew --prefix)"
kotlin_lsp_root="${kotlin_lsp_prefix}/opt/kotlin-lsp-${kotlin_lsp_version}"
kotlin_lsp_tmp="$(mktemp)"
trap 'rm -f "$kotlin_lsp_tmp"' EXIT

curl -fsSL "$kotlin_lsp_url" -o "$kotlin_lsp_tmp"
actual_sha256="$(shasum -a 256 "$kotlin_lsp_tmp" | awk '{print $1}')"
if [[ "$actual_sha256" != "$kotlin_lsp_sha256" ]]; then
  echo "Kotlin LSP archive checksum mismatch; refusing to install." >&2
  exit 1
fi

mkdir -p "$kotlin_lsp_root"
unzip -oq "$kotlin_lsp_tmp" -d "$kotlin_lsp_root"
ln -sfn "$kotlin_lsp_root/kotlin-server-${kotlin_lsp_version}/kotlin-lsp.sh" "$kotlin_lsp_prefix/bin/kotlin-lsp"

printf '\nChecking configured language-server commands on PATH:\n'
missing=0
for server in \
  typescript-language-server pyright-langserver lua-language-server \
  clangd gopls rust-analyzer sourcekit-lsp kotlin-lsp \
  yaml-language-server marksman bash-language-server \
  vscode-json-language-server vscode-css-language-server \
  vscode-html-language-server vscode-eslint-language-server \
  docker-langserver emmet-language-server
do
  if command -v "$server" >/dev/null 2>&1; then
    printf 'OK       %-36s %s\n' "$server" "$(command -v "$server")"
  else
    printf 'MISSING  %s\n' "$server"
    missing=$((missing + 1))
  fi
done

if (( missing > 0 )); then
  echo "$missing server command(s) are not on PATH." >&2
  exit 1
fi

echo 'All configured server commands are on PATH.'
echo 'Polytoken starts language servers on demand; they do not need to run as background services.'
echo 'Check Polytoken LSP status, then open a matching source file to test server startup.'
