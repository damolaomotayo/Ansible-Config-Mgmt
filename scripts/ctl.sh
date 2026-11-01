#!/usr/bin/env bash
# Run any Ansible command inside the control container (the playbooks are in /ansible).
# Examples:
#   ./scripts/ctl.sh ansible all -m ping
#   ./scripts/ctl.sh ansible-playbook playbooks/site.yml
#   ./scripts/ctl.sh ansible-playbook playbooks/site.yml --check --diff
#   ./scripts/ctl.sh ansible-vault view inventory/group_vars/all/vault.yml
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ -f "$ROOT/.vault_pass" ] || die "Run ./scripts/up.sh first."
if [ -t 1 ]; then export ANSIBLE_FORCE_COLOR=1; fi
$DC run --rm $([ -t 0 ] || echo -T) -e ANSIBLE_FORCE_COLOR="${ANSIBLE_FORCE_COLOR:-0}" control "$@"
