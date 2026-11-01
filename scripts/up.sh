#!/usr/bin/env bash
# Builds the lab, starts three brand-new servers and configures all of them with Ansible.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_secrets

build_with_retry() {
  local i
  for i in 1 2 3; do
    $DC build web1 control >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

log "Building the images (server image and Ansible control image)"
build_with_retry || die "Image build failed. Run: $DC build web1 control --progress=plain"
ok "images built"

log "Starting three servers (web1, web2, tools1)"
nodes_up >/dev/null 2>&1 || die "Could not start the servers. Run: $DC up web1 web2 tools1"
ensure_vault_file || die "Could not create the encrypted vault file. Run: ./scripts/ctl.sh ansible-vault --help"
ok "vault file is encrypted"

log "Waiting until Ansible can log in to all three servers over SSH"
wait_ssh 60 || die "Ansible could not reach the servers. Run: ./scripts/ctl.sh ansible all -m ping"
ok "all three servers answer"

log "Configuring everything: ansible-playbook playbooks/site.yml"
play playbooks/site.yml

wait_http "web1" "$WEB1_URL/healthz" 20
wait_http "web2" "$WEB2_URL/healthz" 20

IP="$(public_ip)"
cat <<EOF

Fleet is configured. Open these in your browser (from the laptop allowed by the security group):
  web1 : http://${IP}:8081/      (blue page)
  web2 : http://${IP}:8082/      (orange page)

Run it again to see "changed=0":   ./scripts/ctl.sh ansible-playbook playbooks/site.yml
Next: ./scripts/smoke.sh   then   ./scripts/demo.sh all
EOF
