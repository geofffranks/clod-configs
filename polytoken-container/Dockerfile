# syntax=docker/dockerfile:1
#
# polytoken-dev — isolated dev container for running Polytoken.
#   brew   = tools (polytoken, gh, rtk, tk, jq, yq, perl, ripgrep, mise)
#   mise   = language runtimes (python 3.13 + 3.11, node lts, go latest)
# Mounts are applied by run.sh: ~/workspace, ~/.config/polytoken, ~/bin, ~/.gitconfig, ~/.claude
#
FROM ubuntu:24.04 AS base

ARG DEV_UID=1000
ENV DEBIAN_FRONTEND=noninteractive

# ---- base system packages (Homebrew + git need curl/git/procps/file/build tools) ----
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl file git gnupg2 locales procps sudo tmux time \
      unzip zip rsync dnsutils poppler-utils mupdf-tools qpdf libegl1 libdouble-conversion3 libxkbcommon0 libxkbcommon-x11-0 libxcb-xinerama0 libxcb-cursor0 libgl1 libegl1 libopengl0 \
      libdbus-1-3 libxcb-icccm4 libxcb-keysyms1 libxcb-shape0 libsm6 libice6 \
      libcurl4-openssl-dev libpython3-dev libxml2-dev libncurses-dev libz3-dev pkg-config tzdata zlib1g-dev \
    && localedef -i en_US -f UTF-8 en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# ---- non-root user (Homebrew refuses root). uid matches host => clean bind-mount ownership. ----
RUN userdel -r ubuntu 2>/dev/null || true \
 && useradd -m -s /bin/bash -u "${DEV_UID}" -o dev \
 && echo 'dev ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

USER dev
ENV HOME=/home/dev
WORKDIR /home/dev

# ---- Homebrew (Linuxbrew) ----
RUN /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
ENV PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${PATH}"

# Homebrew env: skip the slow/flaky auto-update in a fresh container.
ENV HOMEBREW_NO_AUTO_UPDATE=1 \
    HOMEBREW_NO_ANALYTICS=1

# ---- tools via brew ----
# Homebrew raises a spurious "Error: Broken pipe" (Errno::EPIPE) when its stdout
# is the pipe Docker build streams to — the tap/install actually succeed but the
# non-zero exit breaks the && chain. Redirect to a regular file (never EPIPEs)
# and surface it only on failure.
RUN LOG=/tmp/brew.log; \
    { brew tap wedow/tools \
      && brew trust wedow/tools \
      && brew install gh rtk ticket mise yq perl jq ripgrep \
      && brew cleanup --prune=all; \
    } >> "$LOG" 2>&1 || { echo "=== brew step failed; tail of $LOG: ==="; tail -n 80 "$LOG"; exit 1; }; \
    (command -v tk >/dev/null 2>&1 || ln -s "$(brew --prefix)/bin/ticket" "$(brew --prefix)/bin/tk") \
    && rm -rf "${HOME}/.cache/Homebrew/"*

RUN curl -fsS https://get.polytoken.dev | bash

# ---- language runtimes via mise ----
ENV MISE_DATA_DIR=/home/dev/.local/share/mise
# Same broken-pipe hardening as the brew step above.
RUN LOG=/tmp/mise.log; \
    { mise install python@3.13 python@3.11 node@lts go@1.26.5 rust@1.88.0 \
      && mise use -g python@3.13 node@lts go@1.26.5 rust@1.88.0 \
      && mise reshim; \
    } >> "$LOG" 2>&1 || { echo "=== mise step failed; tail of $LOG: ==="; tail -n 80 "$LOG"; exit 1; }

# PATH for EVERY process, including non-interactive Docker RUN steps and the
# shell_exec processes Polytoken spawns. mise shims resolve the selected runtimes.
ENV PATH="/home/dev/.local/bin:/home/dev/bin:${MISE_DATA_DIR}/shims:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${PATH}"

# ---- language servers with stable package-manager contracts ----
USER root
RUN apt-get update && apt-get install -y --no-install-recommends clangd-18 openjdk-21-jre-headless \
    && ln -sf "$(command -v clangd-18)" /usr/local/bin/clangd \
    && rm -rf /var/lib/apt/lists/*
USER dev

# npm server versions are pinned so rebuilds do not silently change the LSP set.
RUN command -v node && command -v npm
RUN npm install --global \
      typescript@5.8.3 \
      typescript-language-server@5.3.0 \
      pyright@1.1.400 \
      yaml-language-server@1.19.0 \
      bash-language-server@5.4.0 \
      vscode-langservers-extracted@4.10.0 \
      dockerfile-language-server-nodejs@0.15.0 \
      @olrtg/emmet-language-server@2.4.0

# Go and Rust servers use the image's pinned toolchains. rust-src is required by
# rust-analyzer for standard-library navigation.
RUN GOBIN=/home/dev/.local/bin go install golang.org/x/tools/gopls@v0.23.0 \
    && rustup component add rust-src rust-analyzer

# Native/release servers are installed into ~/.local/bin with stable names. The
# architecture gate prevents a build from accidentally installing a host binary.
ARG TARGETARCH
ARG KOTLIN_LSP_VERSION=262.9593.0
ARG SWIFT_VERSION=6.2.2
ENV SWIFTLY_HOME_DIR=/home/dev/.local/share/swiftly \
    SWIFTLY_BIN_DIR=/home/dev/.local/bin
RUN set -eux; \
    case "$TARGETARCH" in amd64) native_arch="x64"; swiftly_arch="x86_64"; kotlin_suffix=""; lua_sha="e9235d2d72ef55bc41cf8c99cda2ed64777682024b4bb81f5dea425060c5cbb8"; marksman_sha="be5098e8213219269c47fc0d916a66fa31ce0602ec967475c722260aabf26087"; kotlin_sha="2d99d8e198fbe4aa8f4481e37799724ce94803b4ea12a60b416040e3fcd7cc5e"; swiftly_sha="21ad3d6376af0b423435f1f7295364add66c7173ea342654f4ae536c20ae88ba" ;; arm64) native_arch="arm64"; swiftly_arch="aarch64"; kotlin_suffix="-aarch64"; lua_sha="abd2572e8fc929dc838a81ffb8473c5bce0bf39bfe8edb4b120b3b623176ce83"; marksman_sha="db8e124527f7f8048e3e6c91821b9c52ef173d92c01e47d221bf1337afd962fb"; kotlin_sha="2317831c6e5607d05b7ebc1da655330125ce0e3d66fbf24517dfce442debc14e"; swiftly_sha="cb53dfea98f23a2bf62e89c2abbbf2f331ba5ad8ebc4a68a37e918b964848627" ;; *) echo "unsupported TARGETARCH for LSP artifacts: $TARGETARCH" >&2; exit 1 ;; esac; \
    mkdir -p "$HOME/.local/bin" "$HOME/.local/opt"; \
    curl -fsSL "https://github.com/LuaLS/lua-language-server/releases/download/3.19.1/lua-language-server-3.19.1-linux-${native_arch}.tar.gz" -o /tmp/lua-language-server.tar.gz; \
    echo "$lua_sha  /tmp/lua-language-server.tar.gz" | sha256sum -c -; \
    mkdir -p "$HOME/.local/opt/lua-language-server"; tar -xzf /tmp/lua-language-server.tar.gz -C "$HOME/.local/opt/lua-language-server"; \
    ln -sf "$HOME/.local/opt/lua-language-server/bin/lua-language-server" "$HOME/.local/bin/lua-language-server"; \
    curl -fsSL "https://github.com/artempyanykh/marksman/releases/download/2026-02-08/marksman-linux-${native_arch}" -o "$HOME/.local/bin/marksman"; \
    echo "$marksman_sha  $HOME/.local/bin/marksman" | sha256sum -c -; chmod +x "$HOME/.local/bin/marksman"; \
    curl -fsSL "https://download-cdn.jetbrains.com/language-server/kotlin-server/${KOTLIN_LSP_VERSION}/kotlin-server-${KOTLIN_LSP_VERSION}${kotlin_suffix}.tar.gz" -o /tmp/kotlin-lsp.tar.gz; \
    echo "$kotlin_sha  /tmp/kotlin-lsp.tar.gz" | sha256sum -c -; \
    mkdir -p "$HOME/.local/opt/kotlin-lsp"; tar -xzf /tmp/kotlin-lsp.tar.gz -C "$HOME/.local/opt/kotlin-lsp"; \
    kotlin_bin="$(find "$HOME/.local/opt/kotlin-lsp" -type f -path '*/bin/intellij-server' -print -quit)"; \
    test -n "$kotlin_bin"; chmod +x "$kotlin_bin"; printf '%s\n' '#!/bin/sh' "exec \"$kotlin_bin\" \"\$@\"" > "$HOME/.local/bin/kotlin-lsp"; chmod +x "$HOME/.local/bin/kotlin-lsp"; sh -n "$HOME/.local/bin/kotlin-lsp"; \
    curl -fsSL "https://download.swift.org/swiftly/linux/swiftly-1.1.2-${swiftly_arch}.tar.gz" -o /tmp/swiftly.tar.gz; \
    echo "$swiftly_sha  /tmp/swiftly.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/swiftly.tar.gz -C /tmp; \
    /tmp/swiftly init --skip-install --no-modify-profile --quiet-shell-followup --assume-yes; \
    "$SWIFTLY_BIN_DIR/swiftly" install "$SWIFT_VERSION" --assume-yes; \
    "$SWIFTLY_BIN_DIR/swiftly" use "$SWIFT_VERSION" --assume-yes; \
    swift_bin="$SWIFTLY_BIN_DIR/sourcekit-lsp"; \
    test -x "$swift_bin"; test "$swift_bin" = /home/dev/.local/bin/sourcekit-lsp; \
    rm -f /tmp/lua-language-server.tar.gz /tmp/kotlin-lsp.tar.gz /tmp/swiftly.tar.gz /tmp/swiftly

# PATH for EVERY process, including the non-interactive bash shells polytoken's
# shell_exec spawns. mise *shims* read .tool-versions / mise.toml per directory,
# so the right python/node/go resolves without shell activation.
ENV PATH="/home/dev/.local/bin:/home/dev/bin:${MISE_DATA_DIR}/shims:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${PATH}"

# Build from the local sibling checkout supplied by build.sh, then copy only the
# executable into the final image so the source is not retained in final layers.
FROM base AS quota-builder
COPY --from=quota . /tmp/polytoken-quota
RUN cd /tmp/polytoken-quota \
    && go build -buildvcs=false -trimpath -o /home/dev/.local/bin/polytoken-quota ./cmd/polytoken-quota \
    && chmod 0755 /home/dev/.local/bin/polytoken-quota

FROM base
COPY --from=quota-builder /home/dev/.local/bin/polytoken-quota /home/dev/.local/bin/polytoken-quota

# interactive shells: keep ~/bin + brew + shims on PATH (ENV PATH is inherited,
# but make it explicit in case a profile resets PATH)
RUN printf '\nexport PATH="$HOME/bin:%s/shims:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"\n' "$MISE_DATA_DIR" >> ~/.bashrc

# ---- LSP executable smoke check ----
USER root
COPY lsp-servers.yaml /tmp/lsp-servers.yaml
RUN set -eux; \
    command -v yq >/dev/null; \
    yq -r '.servers[].executable' /tmp/lsp-servers.yaml | while IFS= read -r command_name; do \
      test -n "$command_name"; command -v "$command_name" >/dev/null || { echo "missing LSP executable: $command_name" >&2; exit 1; }; \
      command -v "$command_name" | xargs test -x; \
    done; \
    test -s /tmp/lsp-servers.yaml; rm -f /tmp/lsp-servers.yaml
USER dev

# ---- CLI tools ----
# MCP servers are no longer baked or wrapped here: all MCP traffic goes through
# the ratatoskr gateway running on the macOS host (see ../ratatoskr/), reached
# from containers over HTTP at http://host.docker.internal:8910/mcp. The CLIs
# below stay because the harness itself uses them: codex CLI is @openai/codex
# (npm, provider auth); claude CLI is @anthropic-ai/claude-code (npm — Homebrew
# only ships it as a macOS cask, which Linuxbrew can't install). ~/.claude is
# bind-mounted at runtime by run.sh so the container's claude reuses the host's
# auth/config.
RUN npm install -g @openai/codex @anthropic-ai/claude-code

# Codex creates PATH aliases below this directory at startup. Keep the image
# default writable; run.sh also repairs this path after the host ~/.codex
# bind-mount is applied, since the mount can contain stale root-owned state.
ENV CODEX_HOME=/home/dev/.codex
RUN mkdir -p /home/dev/.codex/tmp/arg0 \
    && chmod 700 /home/dev/.codex/tmp/arg0 \
    && chown -R dev:dev /home/dev/.codex

# ---- git: include the host ~/.gitconfig (mounted read-only at ~/.gitconfig.host) ----
# Repoint core.excludesfile to the container's ~/.gitignore (mounted) so the
# global ignore resolves here instead of the host's absolute /Users/... path.
# Rewrite SSH GitHub URLs to HTTPS and authenticate with $GH_TOKEN (set at
# runtime via the env file / POLY_PASS_ENV). The macOS Keychain can't cross the
# container boundary, and virtiofs can't forward the SSH agent socket, so HTTPS
# + token is the reliable path for git fetch/pull/clone.
RUN printf '[include]\n    path = %s/.gitconfig.host\n[core]\n    excludesfile = ~/.gitignore\n' "$HOME" > ~/.gitconfig && \
    git config --global url."https://github.com/".insteadOf "git@github.com:" && \
    git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/" && \
    git config --global credential."https://github.com".helper '!f() { test "$1" = get && echo username=x-access-token && echo "password=$GH_TOKEN"; }; f'

RUN mkdir -p /home/dev/workspace
WORKDIR /home/dev/workspace

CMD ["bash"]
