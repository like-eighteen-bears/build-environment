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
        clang --version
        gcc-14 --version
        docker --version
        docker buildx version
        docker-compose version
        node --version
        pyenv --version
        python --version | grep -q "3.11.9"
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

        run_check "User and docker group IDs can be remapped" \
            -v /var/run/docker.sock:/var/run/docker.sock -- '
            /opt/leb/update_user_group_ids.sh 1500 1500
            [ "$(id -u leb)" = 1500 ]
            [ "$(stat -c %u:%g /home/leb)" = 1500:1500 ]
            su leb -c "docker ps -q > /dev/null"
        '
        ;;
    *)
        echo "Unknown target: $TARGET"
        exit 1
        ;;
esac

echo "All smoke tests passed for $IMAGE ($TARGET)"
