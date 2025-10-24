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
FROM docker as docker_buildx
COPY --from=docker/buildx-bin /buildx /usr/libexec/docker/cli-plugins/docker_buildx

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
FROM downloader as docker_compose
ARG OS
ARG ARCH
ARG DOCKER_COMPOSE_VERSION
ADD --chmod=755 \
    https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-${OS}-${ARCH} \
    /opt/docker-compose/docker-compose

# git-clang-format
FROM downloader as git_clang_format
ADD --chmod=755 \
    https://raw.githubusercontent.com/llvm/llvm-project/refs/heads/main/clang/tools/clang-format/git-clang-format \
    /opt/llvm/

# cmake
FROM downloader as cmake
ARG OS
ARG ARCH
ARG CMAKE_VERSION
WORKDIR /opt/cmake
ADD --chmod=755 \
    https://github.com/Kitware/CMake/releases/download/v4.1.1/cmake-${CMAKE_VERSION}-${OS}-${ARCH}.tar.gz \
    /tmp/
RUN tar zxf /tmp/cmake-${CMAKE_VERSION}-${OS}-${ARCH}.tar.gz --strip-components=1 && \
    rm /tmp/cmake-${CMAKE_VERSION}-${OS}-${ARCH}.tar.gz

# ninja
FROM downloader as ninja
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
FROM downloader as ccache
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
FROM downloader as pyenv
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
FROM downloader as base

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

COPY ssh/env_setup.sh /usr/local/bin/
COPY ssh/ssh_config_force_command_env.conf /etc/ssh/ssh_config.d/
COPY config/pip/pip.conf /etc/
COPY leb/update_user_group_ids.sh /opt/leb/

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
        openssh-client \
        python3 \
        python3-argcomplete \
        python3-gdbm \
        python3-pip \
        python3-venv \
        sshpass \
        sudo \
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

COPY pyenv/skel /etc/skel/
RUN --mount=type=bind,source=pyenv/.profile,target=/tmp/.profile \
    cat /tmp/.profile >> /etc/skel/.profile

# Create default user
ENV DEFAULT_USER=leb
ARG DEFAULT_PASSWORD=polar

RUN <<EOF
    echo "Creating user $DEFAULT_USER with password $DEFAULT_PASSWORD"
    useradd -u 999 -lmU $DEFAULT_USER -G sudo
    groupmod -g 999 $DEFAULT_USER
    echo "$DEFAULT_USER:$DEFAULT_PASSWORD" | chpasswd
    echo "$DEFAULT_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers
EOF

# Create pyenv environment for default user
RUN groupadd -g 995 pyenv
RUN usermod -aG pyenv $DEFAULT_USER
COPY --link --from=pyenv /opt/pyenv /opt/pyenv

ARG PY_ENV_VERSION=3.11.9
ENV PYENV_ROOT=/opt/pyenv

USER root:pyenv
RUN <<EOF
    set -e
    $PYENV_ROOT/bin/pyenv install $PY_ENV_VERSION
    $PYENV_ROOT/bin/pyenv global system $PY_ENV_VERSION
    chmod g+rwX -R $PYENV_ROOT
EOF

# Change to default user
USER $DEFAULT_USER

RUN <<EOF
    # Create these here so that they are owned by the leb user rather than root when volume mounted
    mkdir ~/.config
    mkdir ~/.cache
    mkdir ~/.ccache
    mkdir ~/.persistent
    mkdir ~/.vscode
    mkdir ~/.vscode-server

    touch ~/.persistent/.persistent_bashrc

    # User wont be set if using 'docker run', so ensure it always will be set 
    echo 'export USER=${whoami}' >> ~/.bashrc

    # We expect ~/.ccache to be a persistent mount, so make sure it is what ccache uses
    echo 'export CCACHE_DIR="$HOME/.ccache' >> ~/.bashrc

    echo 'export LANG=C.UTF-8' >> ~/.bashrc

    # Add anything developers might have added
    echo 'source ~/.persistent/.persistent_bashrc' >> ~/.bashrc
EOF

# Only buffers one python log message before printing. Helps with logs
ENV PYTHONUNBUFFERED=1

# Go back to root so the entrypoint script can setup the user permissions
USER root

# CI Builder image for desktop (x86_64) targets.
# This should only include items needed for desktop builds in CI
FROM base AS ci_desktop
ARG CLANG_VERSION
ARG GCC_VERSION

ADD ./llvm/update-alternatives-clang.sh /usr/local/bin/
COPY --link --from=docker_compose /opt/docker-compose/docker-compose /usr/local/bin/
COPY --link --from=docker_buildx /usr/libexec/docker/cli-plugins/docker_buildx /usr/libexec/docker/cli-plugins/

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=ci-desktop-apt-cache \
    --mount=type=cache,target=/var/lib/apt,sharing=locked,id=ci-desktop-apt-lib \
    <<EOF
    set -e

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
    docker.io

    # Make ${CLANG_VERSION} the default. This will create versionless symlinks for a variety of tools.
    update-alternatives-clang.sh ${CLANG_VERSION} 100
   
    # Enable the defauly user to run docker without sudo
    usermod --append --groups docker $DEFAULT_USER
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

    apt upgrade
EOF
