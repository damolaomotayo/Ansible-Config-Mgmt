#!/bin/sh
# Installs the control container's public key for the "ansible" user, then runs sshd in the foreground.
set -e
install -d -m 700 -o ansible -g ansible /home/ansible/.ssh
cp /keys/authorized_keys /home/ansible/.ssh/authorized_keys
chown ansible:ansible /home/ansible/.ssh/authorized_keys
chmod 600 /home/ansible/.ssh/authorized_keys
ssh-keygen -A >/dev/null
exec /usr/sbin/sshd -D -e
