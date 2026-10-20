# Claude Code sandbox: Julia, Rust, Python (uv), Typst + language servers,
# plus the build dependencies of OpenMolcas and UKRmol+ (GBTOlib/UKRmol-in/UKRmol-out).
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
# ILP64 numerical stack (8-byte integers), required by OpenMolcas (LINALG=OpenBLAS, GA)
# and by UKRmol+ when built with -fdefault-integer-8 (the upstream configuration).
ARG OPENBLAS_VERSION=0.3.34
ARG SCALAPACK_VERSION=2.2.3
ARG ARPACK_NG_VERSION=3.9.1
ARG GA_VERSION=5.9.2
ARG PETSC_VERSION=3.26.0
ARG SLEPC_VERSION=3.26.0

ENV DEBIAN_FRONTEND=noninteractive

# --- System packages + CLI tools that make Claude Code more effective ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git \
    build-essential pkg-config libssl-dev \
    ripgrep jq procps \
    unzip xz-utils zstd \
    shellcheck cmake \
    && rm -rf /var/lib/apt/lists/*

# --- OpenMolcas + UKRmol+ build dependencies (distro packages) ---
# gfortran:        Fortran 2008 compiler (libquadmath included: GBTOlib quad precision)
# python3:         needed by the PETSc/SLEPc configure scripts below
# OpenMPI:         OpenMolcas -DMPI=ON / GA, UKRmol+ -DWITH_MPI=ON (mpi-scatci, PARPACK)
# HDF5:            OpenMolcas -DHDF5=ON (default)
# numdiff:         UKRmol+ test suite (-DWITH_NUMDIFF=ON)
# CLBlast/OpenCL:  GBTOlib GPU-accelerated BLAS (optional)
# Boost + GSL:     OpenMolcas QCMaquis DMRG interface (-DDMRG=ON, optional)
# Perl modules:    OpenMolcas TaskFarm
# doxygen:         UKRmol+ API documentation (-DBUILD_DOC=ON, optional)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gfortran python3 \
    libopenmpi-dev openmpi-bin \
    libhdf5-dev \
    numdiff \
    libclblast-dev ocl-icd-opencl-dev \
    libboost-dev libboost-program-options-dev libboost-serialization-dev \
    libboost-filesystem-dev libboost-thread-dev libgsl-dev \
    perl libipc-shareable-perl libparallel-forkmanager-perl \
    doxygen \
    && rm -rf /var/lib/apt/lists/*

# --- ILP64 numerical stack (built from source, installed to /opt/ilp64) ---
# Ubuntu's BLAS/LAPACK/ScaLAPACK/ARPACK packages use 4-byte integers (or a "64_"
# symbol suffix), which neither OpenMolcas nor UKRmol+ can link against. Everything
# below is built with 8-byte integers and plain (unsuffixed) symbol names.
ENV ILP64_PREFIX=/opt/ilp64

# OpenBLAS with LAPACK (OpenMolcas: -DLINALG=OpenBLAS, OPENBLASROOT; UKRmol+: BLAS_LIBRARIES)
RUN curl -fsSL "https://github.com/OpenMathLib/OpenBLAS/releases/download/v${OPENBLAS_VERSION}/OpenBLAS-${OPENBLAS_VERSION}.tar.gz" \
       | tar -xz -C /tmp \
    && cd /tmp/OpenBLAS-${OPENBLAS_VERSION} \
    && make -j"$(nproc)" INTERFACE64=1 NO_LAPACK=0 BINARY=64 DYNAMIC_ARCH=1 USE_OPENMP=1 NUM_THREADS=128 \
         libs netlib shared \
    && make INTERFACE64=1 NO_LAPACK=0 BINARY=64 DYNAMIC_ARCH=1 USE_OPENMP=1 NUM_THREADS=128 \
         PREFIX=${ILP64_PREFIX} install \
    && rm -rf /tmp/OpenBLAS-*

# ScaLAPACK (UKRmol+: SCALAPACK_LIBRARIES; PETSc below)
RUN git clone --depth 1 --branch "v${SCALAPACK_VERSION}" https://github.com/Reference-ScaLAPACK/scalapack.git /tmp/scalapack \
    && cmake -S /tmp/scalapack -B /tmp/scalapack/build \
         -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${ILP64_PREFIX} -DCMAKE_INSTALL_LIBDIR=lib \
         -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF \
         -DBLAS_LIBRARIES=${ILP64_PREFIX}/lib/libopenblas.so -DLAPACK_LIBRARIES=${ILP64_PREFIX}/lib/libopenblas.so \
         -DCMAKE_C_FLAGS="-DInt=long" -DCMAKE_Fortran_FLAGS="-fdefault-integer-8 -fallow-argument-mismatch" \
    && cmake --build /tmp/scalapack/build -j"$(nproc)" \
    && cmake --install /tmp/scalapack/build \
    && rm -rf /tmp/scalapack

# ARPACK-NG + PARPACK (UKRmol+ eigensolvers)
RUN git clone --depth 1 --branch "${ARPACK_NG_VERSION}" https://github.com/opencollab/arpack-ng.git /tmp/arpack-ng \
    && cmake -S /tmp/arpack-ng -B /tmp/arpack-ng/build \
         -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${ILP64_PREFIX} -DCMAKE_INSTALL_LIBDIR=lib \
         -DBUILD_SHARED_LIBS=ON -DINTERFACE64=ON -DMPI=ON -DTESTS=OFF -DEXAMPLES=OFF \
         -DBLAS_LIBRARIES=${ILP64_PREFIX}/lib/libopenblas.so -DLAPACK_LIBRARIES=${ILP64_PREFIX}/lib/libopenblas.so \
    && cmake --build /tmp/arpack-ng/build -j"$(nproc)" \
    && cmake --install /tmp/arpack-ng/build \
    && rm -rf /tmp/arpack-ng

# Global Arrays (OpenMolcas: -DMPI=ON -DGA=ON with GAROOT; same options OpenMolcas uses for -DGA_BUILD=ON)
RUN curl -fsSL "https://github.com/GlobalArrays/ga/releases/download/v${GA_VERSION}/ga-${GA_VERSION}.tar.gz" \
       | tar -xz -C /tmp \
    && cmake -S /tmp/ga-${GA_VERSION} -B /tmp/ga-${GA_VERSION}/build \
         -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${ILP64_PREFIX} -DCMAKE_INSTALL_LIBDIR=lib \
         -DCMAKE_C_COMPILER=mpicc -DCMAKE_Fortran_COMPILER=mpifort \
         -DBUILD_SHARED_LIBS=ON -DENABLE_FORTRAN=ON -DENABLE_CXX=OFF -DENABLE_TESTS=OFF \
         -DENABLE_BLAS=ON -DENABLE_I8=ON -DLINALG_VENDOR=OpenBLAS -DLINALG_PREFIX=${ILP64_PREFIX} \
         -DLINALG_REQUIRED_COMPONENTS=ilp64 -DGA_RUNTIME=MPI_2SIDED \
    && cmake --build /tmp/ga-${GA_VERSION}/build -j"$(nproc)" \
    && cmake --install /tmp/ga-${GA_VERSION}/build \
    && rm -rf /tmp/ga-*

# PETSc + SLEPc with 64-bit indices on top of the ILP64 stack (UKRmol+ SLEPc eigensolvers)
RUN curl -fsSL "https://gitlab.com/petsc/petsc/-/archive/v${PETSC_VERSION}/petsc-v${PETSC_VERSION}.tar.gz" \
       | tar -xz -C /tmp \
    && cd /tmp/petsc-v${PETSC_VERSION} \
    && ./configure --prefix=/opt/petsc --with-debugging=0 \
         --with-cc=mpicc --with-cxx=mpicxx --with-fc=mpifort --with-fortran-bindings=1 \
         --with-shared-libraries=1 --with-64-bit-indices=1 --with-64-bit-blas-indices=1 \
         --with-blaslapack-lib=${ILP64_PREFIX}/lib/libopenblas.so \
         --with-scalapack-lib=${ILP64_PREFIX}/lib/libscalapack.so \
         COPTFLAGS=-O2 CXXOPTFLAGS=-O2 FOPTFLAGS=-O2 \
    && make -j"$(nproc)" PETSC_DIR=/tmp/petsc-v${PETSC_VERSION} PETSC_ARCH=arch-linux-c-opt all \
    && make PETSC_DIR=/tmp/petsc-v${PETSC_VERSION} PETSC_ARCH=arch-linux-c-opt install \
    && rm -rf /tmp/petsc-* \
    && curl -fsSL "https://gitlab.com/slepc/slepc/-/archive/v${SLEPC_VERSION}/slepc-v${SLEPC_VERSION}.tar.gz" \
       | tar -xz -C /tmp \
    && cd /tmp/slepc-v${SLEPC_VERSION} \
    && PETSC_DIR=/opt/petsc ./configure --prefix=/opt/slepc \
    && make -j"$(nproc)" SLEPC_DIR=/tmp/slepc-v${SLEPC_VERSION} PETSC_DIR=/opt/petsc \
    && make SLEPC_DIR=/tmp/slepc-v${SLEPC_VERSION} PETSC_DIR=/opt/petsc install \
    && rm -rf /tmp/slepc-*

# Make the stack discoverable at build and run time.
# (No distro OpenBLAS/ScaLAPACK is installed, so the ILP64 sonames do not shadow anything.)
RUN printf '%s\n' "${ILP64_PREFIX}/lib" /opt/petsc/lib /opt/slepc/lib > /etc/ld.so.conf.d/ilp64.conf \
    && ldconfig
ENV OPENBLASROOT=${ILP64_PREFIX} \
    GAROOT=${ILP64_PREFIX} \
    PETSC_DIR=/opt/petsc \
    SLEPC_DIR=/opt/slepc \
    CMAKE_PREFIX_PATH=${ILP64_PREFIX}:/opt/petsc:/opt/slepc
# Typical configure lines (libxc and libwignernj are fetched by OpenMolcas' CMake via git):
#   OpenMolcas: CC=mpicc FC=mpifort cmake -DMPI=ON -DGA=ON -DLINALG=OpenBLAS -DHDF5=ON <src>
#   UKRmol-in:  cmake -DCMAKE_Fortran_COMPILER=mpifort -DCMAKE_Fortran_FLAGS=-fdefault-integer-8 \
#                 -DBLAS_LIBRARIES=/opt/ilp64/lib/libopenblas.so -DLAPACK_LIBRARIES=/opt/ilp64/lib/libopenblas.so \
#                 -DSCALAPACK_LIBRARIES=/opt/ilp64/lib/libscalapack.so -DWITH_MPI=ON \
#                 -DUKRMOL_OUT_DIR=<ukrmol-out src> <ukrmol-in src>

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
# pyparsing: required by OpenMolcas' pymolcas driver (installed into the managed interpreter,
# which is what `python3` resolves to in this image; uv marks it externally managed).
RUN uv python install --default ${PYTHON_VERSION} \
    && uv pip install --python "$(uv python find ${PYTHON_VERSION})" --break-system-packages pyparsing \
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
