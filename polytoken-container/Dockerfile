# syntax=docker/dockerfile:1
#
# polytoken-dev — isolated dev container for running Polytoken.
#   brew   = tools (polytoken, gh, rtk, tk, jq, yq, perl, ripgrep, mise)
#   mise   = language runtimes (python 3.13 + 3.11, node lts, go latest)
# Mounts are applied by run.sh: ~/workspace, ~/.config/polytoken, ~/bin, ~/.gitconfig
#
FROM ubuntu:24.04

ARG DEV_UID=1000
ENV DEBIAN_FRONTEND=noninteractive

# ---- base system packages (Homebrew + git need curl/git/procps/file/build tools) ----
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl file git locales procps sudo tmux \
      unzip zip rsync dnsutils \
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
    { brew tap polytoken/tap \
      && brew tap wedow/tools \
      && brew trust polytoken/tap \
      && brew trust wedow/tools \
      && brew install polytoken-unstable gh rtk ticket mise yq perl jq ripgrep \
      && brew cleanup --prune=all; \
    } >> "$LOG" 2>&1 || { echo "=== brew step failed; tail of $LOG: ==="; tail -n 80 "$LOG"; exit 1; }; \
    (command -v tk >/dev/null 2>&1 || ln -s "$(brew --prefix)/bin/ticket" "$(brew --prefix)/bin/tk") \
    && rm -rf "${HOME}/.cache/Homebrew/"*

# ---- language runtimes via mise ----
ENV MISE_DATA_DIR=/home/dev/.local/share/mise
# Same broken-pipe hardening as the brew step above.
RUN LOG=/tmp/mise.log; \
    { mise install python@3.13 python@3.11 node@lts go@latest \
      && mise use -g python@3.13 node@lts go@latest \
      && mise reshim; \
    } >> "$LOG" 2>&1 || { echo "=== mise step failed; tail of $LOG: ==="; tail -n 80 "$LOG"; exit 1; }

# PATH for EVERY process, including the non-interactive bash shells polytoken's
# shell_exec spawns. mise *shims* read .tool-versions / mise.toml per directory,
# so the right python/node/go resolves without shell activation.
ENV PATH="/home/dev/.local/bin:/home/dev/bin:${MISE_DATA_DIR}/shims:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${PATH}"

# interactive shells: keep ~/bin + brew + shims on PATH (ENV PATH is inherited,
# but make it explicit in case a profile resets PATH)
RUN printf '\nexport PATH="$HOME/bin:%s/shims:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"\n' "$MISE_DATA_DIR" >> ~/.bashrc

# ---- MCP servers ----
# Wrappers (go run / node) are shared source files: copied into the image here
# AND onto the host's ~/.local/bin by the installer (scripts/install-polytoken.sh)
# — one source of truth. codex CLI is @openai/codex (npm).
COPY --chmod=0755 mcp-wrappers/foundry-mcp mcp-wrappers/codex-imagegen-mcp mcp-wrappers/minime-vision /home/dev/.local/bin/
RUN npm install -g @openai/codex

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
