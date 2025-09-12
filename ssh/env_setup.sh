#!/bin/bash
#
# This script sets up the environment for ssh commands and ssh sessions.

if [ -n "$SSH_ORIGINAL_COMMAND" ]; then
    # If a command is provided, eval it
    . ~/.pyenv_init && eval "$SSH_ORIGINAL_COMMAND"
else
    $SHELL
fi