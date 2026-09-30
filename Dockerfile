# syntax=docker/dockerfile:1

# Build arguments for versions of tools to download.
# Each download is verified against a SHA-256, so update the checksum along with the version.
ARG OS=linux
ARG ARCH=x86_64
ARG GCC_VERSION=14
ARG CLANG_VERSION=17
ARG NODE_VERSION=22
ARG CMAKE_VERSION=4.1.1
ARG CMAKE_SHA256=5a6c61cb62b38e153148a2c8d4af7b3d387f0c8c32b6dbceb5eb4af113efd65a
ARG NINJA_VERSION=1.12.1
ARG NINJA_SHA256=6f98805688d19672bd699fbbfa2c2cf0fc054ac3df1f0e6a47664d963d530255
ARG NINJA_COMPLETION_SHA256=536a81b4d5fac9dd74e4842c59f2b5ab0cce27882e3638fd7219d1ad78fa149d
ARG CCACHE_VERSION=4.11.3
ARG CCACHE_SHA256=7766991b91b3a5a177ab33fa043fe09e72c68586d5a86d20a563a05b74f119c0
ARG PYENV_VERSION=2.6.7
ARG PYENV_SHA256=15b4a23711fea1ec8a320fb46ce39c176c80571ca33cd448d8863d9723c48d93
ARG PYENV_VIRTUALENV_VERSION=1.2.4
ARG PYENV_VIRTUALENV_SHA256=6f49a395a17221f87e1e16f0f92c99c3d21d4fc27072d5c80e65ca11b686eedd

# Signing keys for third-party apt repositories. Pinning them means a replaced key fails the build
# rather than being trusted silently.
ARG DOCKER_APT_GPG_SHA256=1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570
ARG NODESOURCE_APT_GPG_SHA256=b42e0321dabdc24e892115da705cf061167eac12a317f23d329862d0aa0a271d

#==============================================================================
# This first set of images are for downloading a specific dependency in its own
# self-contained image. The intent is that any dependency can be changed without
# invalidating the others. Most of them share a common base image so we can 
# minimize the number of layers that need to be downloaded.
#==============================================================================

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

# cmake
FROM downloader AS cmake
ARG OS
ARG ARCH
ARG CMAKE_VERSION
ARG CMAKE_SHA256
WORKDIR /opt/cmake
ADD --checksum=sha256:${CMAKE_SHA256} \
    https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-${OS}-${ARCH}.tar.gz \
    /tmp/
RUN tar zxf /tmp/cmake-${CMAKE_VERSION}-${OS}-${ARCH}.tar.gz --strip-components=1 && \
    rm /tmp/cmake-${CMAKE_VERSION}-${OS}-${ARCH}.tar.gz

# ninja
FROM downloader AS ninja
ARG OS
ARG ARCH
ARG NINJA_VERSION
ARG NINJA_SHA256
ARG NINJA_COMPLETION_SHA256
ADD --checksum=sha256:${NINJA_COMPLETION_SHA256} --chmod=755 \
    https://github.com/ninja-build/ninja/raw/refs/tags/v${NINJA_VERSION}/misc/bash-completion \
    /opt/ninja/share/bash-completion/ninja
ADD --checksum=sha256:${NINJA_SHA256} \
    https://github.com/ninja-build/ninja/releases/download/v${NINJA_VERSION}/ninja-${OS}.zip \
    /tmp/
RUN unzip /tmp/ninja-${OS}.zip -d /opt/ninja/bin && \
    rm /tmp/ninja-${OS}.zip

# ccache
FROM downloader AS ccache
ARG OS
ARG ARCH
ARG CCACHE_VERSION
ARG CCACHE_SHA256
WORKDIR /opt/ccache
ADD --checksum=sha256:${CCACHE_SHA256} \
    https://github.com/ccache/ccache/releases/download/v${CCACHE_VERSION}/ccache-${CCACHE_VERSION}-${OS}-${ARCH}.tar.xz \
    /tmp/
RUN tar xf /tmp/ccache-${CCACHE_VERSION}-${OS}-${ARCH}.tar.xz --owner=root --group=root --strip-components=1 ccache-${CCACHE_VERSION}-${OS}-${ARCH}/ccache && \
    rm /tmp/ccache-${CCACHE_VERSION}-${OS}-${ARCH}.tar.xz

# pyenv
FROM downloader AS pyenv
ARG PYENV_VERSION
ARG PYENV_SHA256
ARG PYENV_VIRTUALENV_VERSION
ARG PYENV_VIRTUALENV_SHA256
WORKDIR /opt/pyenv
ADD --checksum=sha256:${PYENV_SHA256} \
    https://github.com/pyenv/pyenv/archive/refs/tags/v${PYENV_VERSION}.tar.gz \
    /tmp/
RUN tar zxf /tmp/v${PYENV_VERSION}.tar.gz --strip-components=1 && \
    rm /tmp/v${PYENV_VERSION}.tar.gz
WORKDIR /opt/pyenv/plugins/pyenv-virtualenv
ADD --checksum=sha256:${PYENV_VIRTUALENV_SHA256} \
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
# The trailing slash matters: --link copies onto an empty layer, so without it the
# file itself would be created as /usr/local/bin
COPY --link --from=ccache /opt/ccache/ccache /usr/local/bin/

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
        openssh-client \
        python3 \
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
    # pyenv's python comes first so python, python3 and pip all use it. The system python is
    # externally managed (PEP 668), so pip can't install into it.
    $PYENV_ROOT/bin/pyenv global $PY_ENV_VERSION system
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
ARG NODE_VERSION
ARG DOCKER_APT_GPG_SHA256
ARG NODESOURCE_APT_GPG_SHA256

COPY ./llvm/update-alternatives-clang.sh /usr/local/bin/

# Third-party apt repositories, added explicitly rather than by piping a setup script to bash
ADD --checksum=sha256:${DOCKER_APT_GPG_SHA256} \
    https://download.docker.com/linux/ubuntu/gpg /etc/apt/keyrings/docker.asc
ADD --checksum=sha256:${NODESOURCE_APT_GPG_SHA256} \
    https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key /etc/apt/keyrings/nodesource.asc

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=ci-desktop-apt-cache \
    --mount=type=cache,target=/var/lib/apt,sharing=locked,id=ci-desktop-apt-lib \
    <<EOF
    set -e

    chmod 0644 /etc/apt/keyrings/docker.asc /etc/apt/keyrings/nodesource.asc
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/nodesource.asc] https://deb.nodesource.com/node_${NODE_VERSION}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list

    apt update
    apt install -y --no-install-recommends \
    gcc-${GCC_VERSION} \
    g++-${GCC_VERSION} \
    clang-${CLANG_VERSION} \
    clang-format-${CLANG_VERSION} \
    clang-tidy-${CLANG_VERSION} \
    lld-${CLANG_VERSION} \
    llvm-${CLANG_VERSION} \
    lcov \
    `# Only the client: containers use the host's daemon through a mounted socket` \
    docker-ce-cli \
    docker-buildx-plugin \
    docker-compose-plugin \
    nodejs

    # Make ${CLANG_VERSION} the default. This will create versionless symlinks for a variety of tools.
    update-alternatives-clang.sh ${CLANG_VERSION} 100

    # Make ${GCC_VERSION} the default. These go in /usr/local/bin, which is ahead of /usr/bin in PATH,
    # because /usr/bin/gcc etc. belong to the distro's default gcc package and apt may restore them.
    # gcov must match the compiler version or coverage data can't be read.
    for tool in gcc g++ cpp gcov gcov-dump gcov-tool gcc-ar gcc-nm gcc-ranlib; do
        ln -s /usr/bin/${tool}-${GCC_VERSION} /usr/local/bin/${tool}
    done
    ln -s gcc /usr/local/bin/cc
    ln -s g++ /usr/local/bin/c++

    # Keep the standalone command working for scripts that use it
    ln -s /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose

    # docker-ce-cli doesn't create the group, but the development user and
    # update_user_group_ids.sh expect it for access to a mounted docker socket.
    # The GID is fixed because letting groupadd pick one would take 999, which the development user
    # needs. update_user_group_ids.sh changes it at runtime to match the host's socket.
    groupadd --system --gid 998 docker
EOF

#==============================================================================
# Full Development Build Image
#==============================================================================
FROM ci_desktop AS development

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=development-apt-cache \
    --mount=type=cache,target=/var/lib/apt,sharing=locked,id=development-apt-lib \
    <<EOF
    set -e

    apt update
    apt upgrade -y
    apt install -y --no-install-recommends \
        libwayland-dev \
        libxkbcommon-dev \
        openssh-server \
        sshpass \
        wayland-protocols \
        xwayland

    # Installing openssh-server generates host keys. Remove them so every container doesn't share
    # the published keys; start_sshd.sh generates new ones when sshd is started.
    rm /etc/ssh/ssh_host_*
EOF

COPY sshd/env_setup.sh /usr/local/bin/
COPY sshd/sshd_config_force_command_env.conf /etc/ssh/sshd_config.d/
COPY leb/update_user_group_ids.sh leb/start_sshd.sh /opt/leb/

# Must be in /etc/skel before the user is created so useradd copies them into the home directory
COPY pyenv/skel /etc/skel/
RUN --mount=type=bind,source=pyenv/.profile,target=/tmp/.profile \
    cat /tmp/.profile >> /etc/skel/.profile

ENV DEFAULT_USER=leb

# Create default user
RUN <<EOF
    set -e

    # The base image's 'ubuntu' user has UID/GID 1000, the most common host IDs, which would
    # stop update_user_group_ids.sh giving them to the default user
    userdel -r ubuntu

    echo "Creating user $DEFAULT_USER"
    useradd -u 999 -lmU $DEFAULT_USER -G sudo,pyenv,docker -s /bin/bash
    groupmod -g 999 $DEFAULT_USER

    # No password: a hash baked into a public image can be cracked offline, and sudo doesn't need one
    passwd -l $DEFAULT_USER

    # Use a drop-in so the distro's /etc/sudoers (root entry, secure_path, includedir) is preserved
    echo "$DEFAULT_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$DEFAULT_USER
    chmod 0440 /etc/sudoers.d/$DEFAULT_USER
EOF

# ~/.ccache is expected to be a persistent volume mount in the development environment
ENV CCACHE_DIR=/home/${DEFAULT_USER}/.ccache

# SSH sessions don't get the image's ENV settings, so save them for env_setup.sh to load.
# This must come after the last ENV that SSH sessions need.
RUN export -p | grep -E '^export (PATH|LANG|PYENV_ROOT|PYTHONUNBUFFERED|CCACHE_DIR|DEFAULT_USER)=' \
    > /opt/leb/container-env.sh

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
