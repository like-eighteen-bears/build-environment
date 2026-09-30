#!/bin/bash
# This script sets up the environment for ssh commands and ssh sessions.
# sshd runs it for every connection (ForceCommand), because SSH sessions don't
# inherit the container's environment.

# The image's ENV settings, saved at build time
# shellcheck source=/dev/null
. /opt/leb/container-env.sh

if [ -n "$SSH_ORIGINAL_COMMAND" ]; then
    # If a command is provided, eval it
    # shellcheck source=/dev/null
    . ~/.pyenv_init && eval "$SSH_ORIGINAL_COMMAND"
else
    # A login shell, so the user's .profile and .bashrc are loaded
    exec "$SHELL" -l
fi
