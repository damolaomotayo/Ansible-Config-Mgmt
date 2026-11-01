#!/bin/sh
# Puts the SSH key where ansible.cfg expects it (with the permissions ssh insists on), then runs the command.
set -e
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
cp /ssh-src/id_ed25519 "$HOME/.ssh/id_ed25519"
chmod 600 "$HOME/.ssh/id_ed25519"
exec "$@"
