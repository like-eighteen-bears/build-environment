# syntax=docker/dockerfile:1

# Build arguments for versions of tools to download.
ARG OS=Linux
ARG OS_LOWER=linux
ARG ARCH=x86_64
ARG GCC_VERSION=14
ARG CLANG_VERSION=17
ARG DOCKER_COMPOSE_VERSION=2.39.3
ARG CMAKE_VERSION=4.1.1
ARG NINJA_VERSION=1.12.1
ARG CCACHE_VERSION=4.11.3
ARG PYENV_VERSION=2.6.7
ARG PYENV_VIRTUALENV_VERSION=1.2.4

#==============================================================================
# This first set of images are for downloading a specific dependency in its own
# self-contained image. The intent is that any dependency can be changed without
# invalidating the others. Most of them share a common base image so we can 
# minimize the number of layers that need to be downloaded.
#==============================================================================

# Make the docker buildx plugin available from the official docker image.
FROM docker AS docker_buildx
COPY --from=docker/buildx-bin /buildx /usr/libexec/docker/cli-plugins/docker-buildx

# Image used for downloading dependencies. We will also base final images on this.
FROM ubuntu:24.04 AS downloader
ENV DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=downloader-apt-cache \
    --mount=type=cache,target=/var/lib/apt,sharing=locked,id=downloader-apt-lib \
    <<EOF
    set -e

    # We manage the apt cache, so undo the cleanup that the base image does.
    rm /etc/apt/apt.conf.d/docker-clean

    apt update
    apt install -y \
        tar \
        curl \
        unzip \
        xz-utils \
        gnupg \
        jq
EOF

# docker compose
FROM downloader AS docker_compose
ARG OS
ARG ARCH
ARG DOCKER_COMPOSE_VERSION
ADD --chmod=755 \
    https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-${OS}-${ARCH} \
    /opt/docker-compose/docker-compose

# git-clang-format
FROM downloader AS git_clang_format
ADD --chmod=755 \
    https://raw.githubusercontent.com/llvm/llvm-project/refs/heads/main/clang/tools/clang-format/git-clang-format \
    /opt/llvm/

# cmake
FROM downloader AS cmake
ARG OS
ARG ARCH
ARG CMAKE_VERSION
WORKDIR /opt/cmake
ADD --chmod=755 \
    https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-${OS}-${ARCH}.tar.gz \
    /tmp/
RUN tar zxf /tmp/cmake-${CMAKE_VERSION}-${OS}-${ARCH}.tar.gz --strip-components=1 && \
    rm /tmp/cmake-${CMAKE_VERSION}-${OS}-${ARCH}.tar.gz

# ninja
FROM downloader AS ninja
ARG OS
ARG ARCH
ARG NINJA_VERSION
ADD --chmod=755 \
    https://github.com/ninja-build/ninja/raw/refs/tags/v${NINJA_VERSION}/misc/bash-completion \
    /opt/ninja/share/bash-completion/ninja
ADD --chmod=755 \
    https://github.com/ninja-build/ninja/releases/download/v${NINJA_VERSION}/ninja-${OS}.zip \
    /tmp/
RUN unzip /tmp/ninja-${OS}.zip -d /opt/ninja/bin && \
    rm /tmp/ninja-${OS}.zip

# ccache
FROM downloader AS ccache
ARG OS
ARG OS_LOWER
ARG ARCH
ARG CCACHE_VERSION
WORKDIR /opt/ccache
ADD --chmod=755 \
    https://github.com/ccache/ccache/releases/download/v${CCACHE_VERSION}/ccache-${CCACHE_VERSION}-${OS}-${ARCH}.tar.xz \
    /tmp/
RUN tar xf /tmp/ccache-${CCACHE_VERSION}-${OS}-${ARCH}.tar.xz --owner=root --group=root --strip-components=1 ccache-${CCACHE_VERSION}-${OS_LOWER}-${ARCH}/ccache && \
    rm /tmp/ccache-${CCACHE_VERSION}-${OS}-${ARCH}.tar.xz

# pyenv
FROM downloader AS pyenv
ARG OS
ARG ARCH
ARG PYENV_VERSION
ARG PYENV_VIRTUALENV_VERSION
WORKDIR /opt/pyenv
ADD --chmod=755 \
    https://github.com/pyenv/pyenv/archive/refs/tags/v${PYENV_VERSION}.tar.gz \
    /tmp/
RUN tar zxf /tmp/v${PYENV_VERSION}.tar.gz --strip-components=1 && \
    rm /tmp/v${PYENV_VERSION}.tar.gz
WORKDIR /opt/pyenv/plugins/pyenv-virtualenv
ADD --chmod=755 \
    https://github.com/pyenv/pyenv-virtualenv/archive/refs/tags/v${PYENV_VIRTUALENV_VERSION}.tar.gz \
    /tmp/
RUN tar zxf /tmp/v${PYENV_VIRTUALENV_VERSION}.tar.gz --strip-components=1 && \
    rm /tmp/v${PYENV_VIRTUALENV_VERSION}.tar.gz

#==============================================================================
# Main images all derived from a common base image.
#==============================================================================

# All final images will be based on this image
# Use the downloader image as the base as it has the common tools we need.
# Only include things needed for CI in this base image.
FROM downloader AS base

# Tools needed for all toolchains
COPY --link --from=cmake /opt/cmake /opt/cmake
COPY --link --from=ninja /opt/ninja /opt/ninja
# Single files can be dropped in place
COPY --link --from=ccache /opt/ccache/ccache /usr/local/bin

# Setup convenience symlinks and bash completions
RUN <<EOF
    set -e

    cd /usr/local/bin
    ln -s /opt/cmake/bin/cmake
    ln -s /opt/cmake/bin/ccmake
    ln -s /opt/cmake/bin/cmake-gui
    ln -s /opt/cmake/bin/ctest
    ln -s /opt/cmake/bin/cpack
    ln -s /opt/ninja/bin/ninja

    # Setup bash completions
    mkdir -p /etc/bash_completion.d
    cd /etc/bash_completion.d
    ln -s /opt/cmake/share/bash-completion/completions/cmake
    ln -s /opt/cmake/share/bash-completion/completions/ctest
    ln -s /opt/cmake/share/bash-completion/completions/cpack
    ln -s /opt/ninja/share/bash-completion/ninja

    # Verify installations
    cmake --version
    ninja --version
    ccache --version
EOF

COPY config/pip/pip.conf /etc/

# Install core packages
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=base-apt-cache \
    --mount=type=cache,target=/var/lib/apt,sharing=locked,id=base-apt-lib \
    <<EOF
    set -e

    apt update
    apt install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        file \
        git \
        git-lfs \
        gnupg \
        libwayland-dev \
        libxkbcommon-dev \
        openssh-client \
        python3 \
        python3-argcomplete \
        python3-gdbm \
        python3-pip \
        python3-venv \
        sshpass \
        sudo \
        wayland-protocols \
        xwayland \
        zip \
        `# Needed for pyenv install` \
        libbz2-dev \
        libffi-dev \
        liblzma-dev \
        libncursesw5-dev \
        libreadline-dev \
        libsqlite3-dev \
        libssl-dev \
        tk-dev \
        zlib1g-dev
EOF

# Install pyenv's python system-wide. The pyenv group owns it so that users added
# to the group later can install packages and versions without a second copy of
# /opt/pyenv being made in another layer.
RUN groupadd -g 995 pyenv
COPY --link --chown=0:995 --from=pyenv /opt/pyenv /opt/pyenv

ARG PY_ENV_VERSION=3.11.9
ENV PYENV_ROOT=/opt/pyenv

USER root:pyenv
RUN <<EOF
    set -e
    $PYENV_ROOT/bin/pyenv install $PY_ENV_VERSION
    $PYENV_ROOT/bin/pyenv global system $PY_ENV_VERSION
    chmod g+rwX -R $PYENV_ROOT
EOF
USER root

# Configuration set with ENV rather than in shell rc files, because CI runs
# non-interactive shells that never read them.
ENV PATH=$PYENV_ROOT/shims:$PYENV_ROOT/bin:$PATH
ENV LANG=C.UTF-8
# Only buffers one python log message before printing. Helps with logs
ENV PYTHONUNBUFFERED=1
# CI can mount a persistent cache volume here. It is world-writable because CI
# may run the container as any UID.
ENV CCACHE_DIR=/ccache
RUN mkdir -m 0777 $CCACHE_DIR

# CI Builder image for desktop (x86_64) targets.
# This should only include items needed for desktop builds in CI
FROM base AS ci_desktop
ARG CLANG_VERSION
ARG GCC_VERSION

ADD ./llvm/update-alternatives-clang.sh /usr/local/bin/
COPY --link --from=docker_compose /opt/docker-compose/docker-compose /usr/local/bin/
COPY --link --from=docker_buildx /usr/libexec/docker/cli-plugins/docker-buildx /usr/libexec/docker/cli-plugins/

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=ci-desktop-apt-cache \
    --mount=type=cache,target=/var/lib/apt,sharing=locked,id=ci-desktop-apt-lib \
    <<EOF
    set -e

    curl -fsSL https://deb.nodesource.com/setup_22.x | bash

    apt update
    apt install -y --no-install-recommends \
    gcc-${GCC_VERSION} \
    g++-${GCC_VERSION} \
    clang-${CLANG_VERSION} \
    clang-format-${CLANG_VERSION} \
    clang-tidy-${CLANG_VERSION} \
    lld-${CLANG_VERSION} \
    llvm-${CLANG_VERSION} \
    gpp \
    lcov \
    python3-dev \
    docker.io \
    nodejs

    # Make ${CLANG_VERSION} the default. This will create versionless symlinks for a variety of tools.
    update-alternatives-clang.sh ${CLANG_VERSION} 100
EOF

#==============================================================================
# Full Development Build Image
#==============================================================================
FROM ci_desktop AS development

COPY --link --from=git_clang_format /opt/llvm/git-clang-format /usr/local/bin/

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=development-apt-cache \
    --mount=type=cache,target=/var/lib/apt,sharing=locked,id=development-apt-lib \
    <<EOF
    set -e

    apt update
    apt upgrade -y
EOF

COPY sshd/env_setup.sh /usr/local/bin/
COPY sshd/sshd_config_force_command_env.conf /etc/ssh/sshd_config.d/
COPY leb/update_user_group_ids.sh /opt/leb/

# Must be in /etc/skel before the user is created so useradd copies them into the home directory
COPY pyenv/skel /etc/skel/
RUN --mount=type=bind,source=pyenv/.profile,target=/tmp/.profile \
    cat /tmp/.profile >> /etc/skel/.profile

ENV DEFAULT_USER=leb

# Create default user
RUN <<EOF
    set -e

    echo "Creating user $DEFAULT_USER"
    useradd -u 999 -lmU $DEFAULT_USER -G sudo,pyenv,docker
    groupmod -g 999 $DEFAULT_USER

    # No password: a hash baked into a public image can be cracked offline, and sudo doesn't need one
    passwd -l $DEFAULT_USER

    # Use a drop-in so the distro's /etc/sudoers (root entry, secure_path, includedir) is preserved
    echo "$DEFAULT_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$DEFAULT_USER
    chmod 0440 /etc/sudoers.d/$DEFAULT_USER
EOF

# ~/.ccache is expected to be a persistent volume mount in the development environment
ENV CCACHE_DIR=/home/${DEFAULT_USER}/.ccache

USER $DEFAULT_USER

RUN <<EOF
    set -e

    # Create these here so that they are owned by the leb user rather than root when volume mounted
    mkdir ~/.config
    mkdir ~/.cache
    mkdir ~/.ccache
    mkdir ~/.persistent
    mkdir ~/.vscode
    mkdir ~/.vscode-server

    touch ~/.persistent/.persistent_bashrc

    # User wont be set if using 'docker run', so ensure it always will be set 
    echo 'export USER=$(whoami)' >> ~/.bashrc

    # Add anything developers might have added
    echo 'source ~/.persistent/.persistent_bashrc' >> ~/.bashrc
EOF

# Go back to root so derived images (e.g. DDE) can remap the user's IDs with /opt/leb/update_user_group_ids.sh
USER root
