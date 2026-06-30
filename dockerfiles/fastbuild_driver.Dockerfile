# Copyright Advanced Micro Devices, Inc.
# SPDX-License-Identifier: MIT
#
# Slurm/Pyxis driver image: CMake 4.2+, FASTBuild (fbuild + fbuildworker), and
# apt host deps used by build_tools/fastbuild_container_setup.sh — so jobs
# skip per-allocation wget/apt noise when they use this image instead of the
# bare ROCm Ubuntu base + runtime setup script.
#
# Build (from TheRock repo root):
#   docker build -f dockerfiles/fastbuild_driver.Dockerfile \
#     -t your-registry.example/therock-fastbuild:1.0 .
#
# Run-time: still mount $HOME for sources + brokerage + NFS cache; put -B trees
# on $SLURM_TMPDIR (see docs/development/fastbuild_slurm_environment_hardening.md).

ARG BASE_IMAGE=ghcr.io/rocm/no_rocm_image_ubuntu24_04:latest
FROM ${BASE_IMAGE}

# Base image may default to a non-root USER; image build needs root for
# mkdir under /, apt-get in fastbuild_container_setup.sh, and installs
# under /opt.
USER root

ARG CMAKE_VERSION=4.2.3
ARG FASTBUILD_VERSION=1.20

ENV DEBIAN_FRONTEND=noninteractive \
    THEROCK_REPO=/therock \
    THEROCK_SLIM_ENV_ROOT=/opt/therock-fastbuild-env \
    CMAKE_VERSION=${CMAKE_VERSION} \
    FASTBUILD_VERSION=${FASTBUILD_VERSION} \
    FORCE=1

# COPY creates parent directories; explicit RUN mkdir is not required.
COPY build_tools/fastbuild_container_setup.sh /therock/build_tools/fastbuild_container_setup.sh
COPY dockerfiles/install_pinned_patchelf.sh /therock/dockerfiles/install_pinned_patchelf.sh
COPY dockerfiles/install_patchelf.sh /therock/dockerfiles/install_patchelf.sh
COPY dockerfiles/build_manylinux_x86_64.Dockerfile /therock/dockerfiles/build_manylinux_x86_64.Dockerfile

# Normalize CRLF when the Docker build context is checked out on Windows.
# Include build_manylinux_x86_64.Dockerfile so PATCHELF_GIT_REF has no stray \r
# (otherwise curl reports "Malformed input to a URL function").
RUN sed -i 's/\r$//' \
    /therock/build_tools/fastbuild_container_setup.sh \
    /therock/dockerfiles/install_pinned_patchelf.sh \
    /therock/dockerfiles/install_patchelf.sh \
    /therock/dockerfiles/build_manylinux_x86_64.Dockerfile \
  && bash /therock/build_tools/fastbuild_container_setup.sh

ENV PATH="/opt/therock-fastbuild-env/opt/bin:${PATH}"

# Optional: default for interactive smoke; Slurm overrides workdir anyway.
WORKDIR /therock