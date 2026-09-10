# Claude Code sandbox: Julia, Rust, Typst + language servers
# Build:  docker build -t claude-sandbox .
# Run:    docker run -it --rm \
#           -v "$(pwd)":/workspace \
#           -v "$HOME/.claude":/home/claude/.claude \
#           claude-sandbox
# Container sees only the mounted working directory (/workspace).
# The ~/.claude mount persists authentication between runs (optional).

FROM nvidia/cuda:11.8.0-base-ubuntu22.04

ARG JULIA_VERSION=1.12.7
ARG TYPST_VERSION=0.15.1
ARG TINYMIST_VERSION=0.15.2

ENV DEBIAN_FRONTEND=noninteractive

# --- System packages + CLI tools that make Claude Code more effective ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget git openssh-client gnupg \
    build-essential pkg-config libssl-dev \
    ripgrep fd-find fzf jq bat tree less procps \
    unzip zip xz-utils zstd \
    shellcheck cmake \
    && rm -rf /var/lib/apt/lists/* \
    # Debian names: fdfind -> fd, batcat -> bat
    && ln -s "$(which fdfind)" /usr/local/bin/fd \
    && ln -s "$(which batcat)" /usr/local/bin/bat

# --- yq (YAML processing) + delta (better git diffs) ---
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" \
       -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq \
    && DELTA_VER=$(curl -fsSL https://api.github.com/repos/dandavison/delta/releases/latest | jq -r .tag_name) \
    && curl -fsSL "https://github.com/dandavison/delta/releases/download/${DELTA_VER}/git-delta_${DELTA_VER}_${ARCH}.deb" \
       -o /tmp/delta.deb && dpkg -i /tmp/delta.deb && rm /tmp/delta.deb

# --- Typst ---
RUN ARCH=$(uname -m) \
    && curl -fsSL "https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-${ARCH}-unknown-linux-musl.tar.xz" \
       | tar -xJ -C /tmp \
    && mv /tmp/typst-${ARCH}-unknown-linux-musl/typst /usr/local/bin/ \
    && rm -rf /tmp/typst-*

# --- Tinymist (Typst language server) ---
RUN ARCH=$(uname -m) \
    && curl -fsSL "https://github.com/Myriad-Dreamin/tinymist/releases/download/v${TINYMIST_VERSION}/tinymist-${ARCH}-unknown-linux-gnu.tar.gz" \
       | tar -xz -C /tmp \
    && find /tmp -name tinymist -type f -exec mv {} /usr/local/bin/tinymist \; \
    && chmod +x /usr/local/bin/tinymist \
    && rm -rf /tmp/tinymist*

# --- Non-root user ---
RUN useradd -m -s /bin/bash claude
USER claude
WORKDIR /home/claude
ENV PATH="/home/claude/.local/bin:/home/claude/.cargo/bin:/home/claude/.juliaup/bin:${PATH}"

# --- Rust toolchain + rust-analyzer (language server) ---
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --profile default \
    && /home/claude/.cargo/bin/rustup component add rust-analyzer clippy rustfmt

# --- Julia (via juliaup) + LanguageServer.jl ---
RUN curl -fsSL https://install.julialang.org | sh -s -- --yes --default-channel ${JULIA_VERSION} \
    && julia -e 'using Pkg; Pkg.add(["LanguageServer", "SymbolServer"]); Pkg.precompile()'

# Julia LS launcher (editors/clients can invoke `julia-lsp`)
RUN mkdir -p /home/claude/.local/bin \
    && printf '#!/bin/bash\nexec julia --startup-file=no --history-file=no \\\n  -e "using LanguageServer; runserver()" "$@"\n' \
       > /home/claude/.local/bin/julia-lsp \
    && chmod +x /home/claude/.local/bin/julia-lsp

# --- Claude Code (native installer, recommended over npm) ---
RUN curl -fsSL https://claude.ai/install.sh | bash

# --- Workspace: the only host directory visible inside the container ---
WORKDIR /workspace

ENTRYPOINT ["claude"]
