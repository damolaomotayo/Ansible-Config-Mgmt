#!/usr/bin/env bash
# Removes everything this project created on the instance: containers, images, SSH key, vault password
# and the encrypted vault file.
# Usage: ./scripts/destroy.sh [--keep-env]
set -uo pipefail
. "$(dirname "$0")/lib.sh"

log "Stopping and removing the servers"
$DC --profile tools down -v --remove-orphans

log "Removing the lab images"
$DOCKER rmi -f ansible-lab-node:local ansible-lab-control:local >/dev/null 2>&1 || true
$DOCKER image prune -f >/dev/null 2>&1 || true

log "Removing the SSH key, vault password and encrypted vault file"
rm -rf "$ROOT/.ssh" "$ROOT/.vault_pass" "$VAULT_FILE" "$ROOT/ansible/.ansible"
if [ "${1:-}" != "--keep-env" ]; then rm -f "$ROOT/.env"; fi

echo
echo "Cleanup done."
echo "IMPORTANT: terminate the EC2 instance in the AWS console (EC2 > Instances >"
echo "Instance state > Terminate) so it stops costing money. Then delete the security group."
