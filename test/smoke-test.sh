#!/bin/bash
#
# Runs basic checks against a built image to catch broken tooling or configuration
# before it is published.
#
# Usage: smoke-test.sh image target
#   image   The image to test, e.g. build-environment:test
#   target  The Dockerfile target the image was built from: ci_desktop or development

# Check scripts are single-quoted on purpose so they expand inside the container, not here.
# shellcheck disable=SC2016

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "USAGE: $0 image target"
    echo "target must be ci_desktop or development"
    exit 1
fi

IMAGE=$1
TARGET=$2

# Runs a check script in a fresh container. Extra docker run arguments go before '--'.
run_check() {
    local description=$1
    shift
    local docker_args=()
    while [ "$1" != "--" ]; do
        docker_args+=("$1")
        shift
    done
    shift

    echo "--- $description"
    docker run --rm "${docker_args[@]}" "$IMAGE" bash -c "set -euo pipefail; $1"
}

# Checks that apply to every image. These run non-interactively, like CI does,
# so they also prove the configuration does not depend on shell rc files.
check_toolchain() {
    run_check "Toolchain available non-interactively as $1" -u "$1" -- '
        cmake --version
        ctest --version
        ninja --version
        ccache --version
        clang --version | grep -q "clang version 17\."
        git-clang-format -h > /dev/null
        ld.lld --version | grep -q "LLD 17\."
        for tool in gcc g++ cc c++ gcov; do
            "$tool" --version | head -1 | grep -q " 14\."
        done
        docker --version
        docker buildx version
        docker compose version
        docker-compose version
        getent group docker
        node --version | grep -q "^v22\."
        pyenv --version
        for command in python python3; do
            "$command" --version | grep -q "3.11.9"
        done
        for command in pip pip3; do
            "$command" --version | grep -q "^pip .* from /opt/pyenv/"
        done
        [ "$LANG" = "C.UTF-8" ]
    '

    run_check "ccache caches compiles as $1" -u "$1" -- '
        cd "$(mktemp -d)"
        echo "int main() { return 0; }" > main.c
        ccache gcc -c main.c -o main.o
        ccache gcc -c main.c -o main.o
        ccache --print-stats | grep -qE "^direct_cache_hit[[:space:]]+1$"
    '
}

case "$TARGET" in
    ci_desktop)
        # CI may run the container as root or as an arbitrary UID
        check_toolchain root
        check_toolchain 1234:1234

        run_check "CI image has no development user" -- '
            [ "$CCACHE_DIR" = "/ccache" ]
            ! getent passwd leb
            [ ! -e /opt/leb ]
        '

        run_check "CI image has no development-only packages" -- '
            for package in openssh-server sshpass xwayland libwayland-dev python3-pip python3-dev; do
                ! dpkg -s "$package" > /dev/null 2>&1
            done
        '
        ;;
    development)
        check_toolchain leb

        run_check "Development user is configured" -u leb -- '
            [ "$CCACHE_DIR" = "/home/leb/.ccache" ]
            sudo -n true
            touch "$PYENV_ROOT/.smoke-test" "$PYENV_ROOT/versions/.smoke-test"
        '

        run_check "Development user has a locked password" -- '
            passwd -S leb | grep -q " L "
        '

        run_check "Interactive login shell is configured" -u leb -- '
            bash -lic "[ \"\$USER\" = leb ] && [ \"\$(type -t pyenv)\" = function ] && pyenv virtualenvs" 2>&1
        '

        run_check "Development packages are installed" -- '
            dpkg -s openssh-server sshpass xwayland libwayland-dev libxkbcommon-dev wayland-protocols > /dev/null
            getent passwd leb | grep -q ":/bin/bash$"
            ! getent passwd ubuntu
        '

        run_check "SSH has per-container host keys and the container environment" -- '
            ! ls /etc/ssh/ssh_host_* > /dev/null 2>&1
            /opt/leb/start_sshd.sh
            ls /etc/ssh/ssh_host_ed25519_key > /dev/null
            su leb -c "
                ssh-keygen -q -t ed25519 -N \"\" -f ~/.ssh/id_ed25519
                cp ~/.ssh/id_ed25519.pub ~/.ssh/authorized_keys
            "
            ssh_leb() {
                su leb -c "ssh -o BatchMode=yes -o StrictHostKeyChecking=no leb@localhost $*"
            }
            # A command, and an interactive session reading from stdin
            ssh_leb "\"python --version; echo \\\$CCACHE_DIR \\\$LANG\"" | tr "\n" " " \
                | grep -q "^Python 3.11.9 /home/leb/.ccache C.UTF-8 $"
            echo "cmake --version; type -t pyenv" | ssh_leb 2> /dev/null | grep -q "^function$"
        '

        run_check "User and docker group IDs can be remapped" \
            -v /var/run/docker.sock:/var/run/docker.sock -- '
            # 1000 is the most common host user and group ID
            /opt/leb/update_user_group_ids.sh 1000 1000
            [ "$(id -u leb):$(id -g leb)" = 1000:1000 ]
            [ "$(stat -c %u:%g /home/leb)" = 1000:1000 ]
            su leb -c "docker ps -q > /dev/null"
        '

        run_check "The host user's primary group can be the docker group" -- '
            # As on GitHub runners. The docker group is left alone, and leb has access through its own group
            /opt/leb/update_user_group_ids.sh 1001 118 118
            [ "$(id -g leb)" = 118 ]
            [ "$(getent group docker | cut -d: -f3)" = 998 ]
        '

        run_check "The docker group makes way for the user's group ID" -- '
            /opt/leb/update_user_group_ids.sh 1000 998 965
            [ "$(id -g leb)" = 998 ]
            [ "$(getent group docker | cut -d: -f3)" = 965 ]
            id -nG leb | tr " " "\n" | grep -qx docker
        '

        run_check "Docker access comes from another group that already has the docker ID" -- '
            /opt/leb/update_user_group_ids.sh 1000 1000 100
            [ "$(getent group 100 | cut -d: -f1)" = users ]
            id -nG leb | tr " " "\n" | grep -qx users
        '

        run_check "A user group ID that another group has is refused" -- '
            ! /opt/leb/update_user_group_ids.sh 1000 995 965 2> /tmp/error
            grep -q "pyenv" /tmp/error
        '
        ;;
    *)
        echo "Unknown target: $TARGET"
        exit 1
        ;;
esac

echo "All smoke tests passed for $IMAGE ($TARGET)"
