#!/bin/bash
#
# Runs on the host before the dev container is built. Records the host user's IDs
# and the docker socket's group so the container's user can be made to match them.
# docker compose reads the result from .devcontainer/.env.

set -euo pipefail

docker_socket=/var/run/docker.sock
docker_group_id=""
if [ -S "$docker_socket" ]; then
    docker_group_id=$(stat -c %g "$docker_socket")
fi

cat > "$(dirname "$0")/.env" <<EOF
HOST_USER_ID=$(id -u)
HOST_GROUP_ID=$(id -g)
DOCKER_GROUP_ID=${docker_group_id}
EOF
