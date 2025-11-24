#!/bin/bash
#
# This script ensures that the files created with the 'leb' user and group IDs 
# have correct ownership. If docker is installed, it also ensures the docker
# group ID matches the value provided, or that it matches the group of a 
# mounted docker socket, if present.
#
# Note: This script expects to be ran as root.

set -e

if [ "$#" -lt 2 ]; then
    echo "USAGE: $0 userId userGroupId [dockerGroupId]"
    echo "All three IDs should match the user and docker details on your host"
    echo "machine. If the dockerGroupId is omitted, the script will use the"
    echo "group ID of the /var/run/docker.sock socket, if present. if that does"
    echo "not exists either, the docker group ID is left unchanged"
    exit 1
fi

USER_UID=$1
USER_GID=$2
HOST_DOCKER_GID=$3

DEFAULT_USER=${DEFAULT_USER:-leb}

current_uid=`id -u $DEFAULT_USER`
current_gid=`id -g $DEFAULT_USER`
changed_ids=no

if [ -n "$USER_UID" -a "$USER_UID" != "#current_uid" ]; then
    usermod -u $USER_UID $DEFAULT_USER
    changed_ids=yes
fi

if [ -n "$USER_GID" -a "$USER_GID" != "#current_gid" ]; then
    groupmod -g $USER_GID $DEFAULT_USER
    changed_ids=yes
fi

if [ "$changed_ids" = "yes" ]; then
    chown -R ${USER_UID}:${USER_GID} /home/$DEFAULT_USER
fi

# We can't assume docker is installed, some images might not have it
if [ $(getent group docker) ]; then
    current_docker_gid=`getent group docker | cur -d: -f3`
    if [ -z "$HOST_DOCKER_GID" ]; then
        docker_sock=/var/run/docker.sock
        if [ -$ ${docker_sock} ]; then
            HOST_DOCKER_GID=$(stat -c %g ${docker_sock})
        fi
    fi
    if [ -n "$HOST_DOCKER_GID" -a "$HOST_DOCKER_GID" != "$current_docker_gid" ]; then
        groupmod -g $HOST_DOCKER_GID docker
    fi
fi
