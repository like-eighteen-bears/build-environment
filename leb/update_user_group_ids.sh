#!/bin/bash
#
# This script ensures that the files created with the 'leb' user and group IDs
# have correct ownership. If docker is installed, it also ensures the user can
# use the host's docker socket: the docker group ID is changed to the value
# provided, or to the group of a mounted docker socket, if present.
#
# When another group in the image already has the docker ID, including the
# user's own group (e.g. when the host user's primary group is docker), the
# user is given that group's access instead.
#
# Note: This script expects to be ran as root.

set -e

if [ "$#" -lt 2 ]; then
    echo "USAGE: $0 userId userGroupId [dockerGroupId]"
    echo "All three IDs should match the user and docker details on your host"
    echo "machine. If the dockerGroupId is omitted, the script will use the"
    echo "group ID of the /var/run/docker.sock socket, if present. If that does"
    echo "not exist either, the docker group ID is left unchanged"
    exit 1
fi

USER_UID=$1
USER_GID=$2
HOST_DOCKER_GID=${3:-}

DEFAULT_USER=${DEFAULT_USER:-leb}

# Prints the name of the group with the given ID, or nothing if there is none
group_with_id() {
    getent group "$1" | cut -d: -f1
}

# We can't assume docker is installed, some images might not have it
has_docker_group=no
if getent group docker > /dev/null; then
    has_docker_group=yes
    docker_sock=/var/run/docker.sock
    if [ -z "$HOST_DOCKER_GID" ] && [ -S "$docker_sock" ]; then
        HOST_DOCKER_GID=$(stat -c %g "$docker_sock")
    fi
fi

# Gives the docker group the host's docker ID, if no other group has it
renumber_docker_group() {
    if [ "$has_docker_group" = "yes" ] && [ -n "$HOST_DOCKER_GID" ] \
        && [ "$HOST_DOCKER_GID" != "$USER_GID" ] && [ -z "$(group_with_id "$HOST_DOCKER_GID")" ]; then
        groupmod -g "$HOST_DOCKER_GID" docker
    fi
}

# Before the user's group changes, as the docker group may have the ID the user's group needs
renumber_docker_group

current_uid=$(id -u "$DEFAULT_USER")
current_gid=$(id -g "$DEFAULT_USER")
changed_ids=no

if [ -n "$USER_UID" ] && [ "$USER_UID" != "$current_uid" ]; then
    conflicting_user=$(getent passwd "$USER_UID" | cut -d: -f1)
    if [ -n "$conflicting_user" ]; then
        echo "Error: Can't give $DEFAULT_USER the user ID $USER_UID, the image's '$conflicting_user' user already has it" >&2
        exit 1
    fi
    usermod -u "$USER_UID" "$DEFAULT_USER"
    changed_ids=yes
fi

if [ -n "$USER_GID" ] && [ "$USER_GID" != "$current_gid" ]; then
    conflicting_group=$(group_with_id "$USER_GID")
    if [ -n "$conflicting_group" ]; then
        echo "Error: Can't give $DEFAULT_USER's group the ID $USER_GID, the image's '$conflicting_group' group already has it" >&2
        exit 1
    fi
    groupmod -g "$USER_GID" "$DEFAULT_USER"
    changed_ids=yes
fi

if [ "$changed_ids" = "yes" ]; then
    # Look the IDs up again, as either argument may have been empty
    home_dir=$(getent passwd "$DEFAULT_USER" | cut -d: -f6)
    chown -R "$(id -u "$DEFAULT_USER"):$(id -g "$DEFAULT_USER")" "$home_dir"
fi

# Again, as the user's group may have just given up the docker ID
renumber_docker_group

# Whichever group now has the docker ID gives access to the socket: docker itself, the user's own
# group, or another group in the image that already had the ID
if [ "$has_docker_group" = "yes" ] && [ -n "$HOST_DOCKER_GID" ]; then
    docker_access_group=$(group_with_id "$HOST_DOCKER_GID")
    if [ -n "$docker_access_group" ] && ! id -nG "$DEFAULT_USER" | tr ' ' '\n' | grep -qx "$docker_access_group"; then
        usermod -aG "$docker_access_group" "$DEFAULT_USER"
    fi
fi
