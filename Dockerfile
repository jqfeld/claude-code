# Claude Code sandbox: Julia, Rust, Python (uv), Typst, OpenFOAM (ESI) + language servers
# Build:  podman build -t claude-code .
# Run:    podman run -it --rm \
#           -v "$(pwd)":/workspace \
#           -v "$HOME/.claude":/home/claude/.claude \
#           claude-code
# Container sees only the mounted working directory (/workspace).
# The ~/.claude mount persists authentication between runs (optional).
# Attach "--device nvidia.com/gpu=all" to give claude access to the
# installed GPU (for CUDA development).

ARG UV_VERSION=latest

# uv/uvx static binaries (official image; pin UV_VERSION for reproducible builds)
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# CUDA 13.x needs host NVIDIA driver >= 580
FROM nvidia/cuda:13.4.3-base-ubuntu26.04

ARG JULIA_VERSION=1.13
ARG PYTHON_VERSION=3.13
ARG TYPST_VERSION=0.15.1
ARG TINYMIST_VERSION=0.15.2
ARG OPENFOAM_VERSION=2606

ENV DEBIAN_FRONTEND=noninteractive

# --- System packages + CLI tools that make Claude Code more effective ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git \
    build-essential pkg-config libssl-dev \
    ripgrep jq procps \
    unzip xz-utils zstd \
    shellcheck cmake \
    && rm -rf /var/lib/apt/lists/*

# --- OpenFOAM (ESI/OpenCFD, openfoam.com) ---
# add-debian-repo.sh sets up the dl.openfoam.com apt repo + key (installs gnupg itself).
# openfoamXXXX-default = solvers + dev headers + tutorials (no ParaView).
RUN curl -fsSL https://dl.openfoam.com/add-debian-repo.sh | bash \
    && apt-get update \
    && apt-get install -y --no-install-recommends openfoam${OPENFOAM_VERSION}-default \
    && rm -rf /var/lib/apt/lists/*

# Load OpenFOAM env in interactive shells (bash.bashrc) and
# non-interactive bash (BASH_ENV) — Claude Code's Bash tool is non-interactive.
RUN printf 'source /usr/lib/openfoam/openfoam%s/etc/bashrc\n' "${OPENFOAM_VERSION}" > /etc/profile.d/openfoam.sh \
    && echo 'source /etc/profile.d/openfoam.sh' >> /etc/bash.bashrc
ENV BASH_ENV=/etc/profile.d/openfoam.sh

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

# --- uv (Python package/project manager) ---
COPY --from=uv /uv /uvx /usr/local/bin/

# --- Non-root user ---
# Ubuntu 24.04+ images ship user "ubuntu" (UID 1000); drop it so claude gets UID 1000
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -u 1000 -s /bin/bash claude
USER claude
WORKDIR /home/claude
ENV PATH="/home/claude/.local/bin:/home/claude/.cargo/bin:/home/claude/.juliaup/bin:${PATH}"

# --- Rust toolchain + rust-analyzer (language server) ---
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --profile default \
    && /home/claude/.cargo/bin/rustup component add rust-analyzer clippy rustfmt

# --- Python (uv-managed) + ruff (lint/format) + basedpyright (language server) ---
# Mounted /workspace is a different filesystem than the uv cache: copy, don't hardlink.
ENV UV_LINK_MODE=copy \
    UV_PYTHON_PREFERENCE=only-managed
RUN uv python install --default ${PYTHON_VERSION} \
    && uv tool install ruff \
    && uv tool install basedpyright \
    && uv cache clean

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
