#!/bin/bash
#
# Starts sshd in the background so the container can be reached over SSH, e.g. by
# IDEs that use remote toolchains. Host keys are generated on first start, so each
# container has its own. Only key authentication works: add your public key to
# ~/.ssh/authorized_keys for the user you log in as.
#
# Note: This script expects to be ran as root.

set -e

ssh-keygen -A
mkdir -p /run/sshd
/usr/sbin/sshd
