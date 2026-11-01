#!/usr/bin/env bash
# Health check of the configured fleet. Ends with "All 13 checks passed."
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ -f "$ROOT/.vault_pass" ] || die "Run ./scripts/up.sh first."

PASS=0
TOTAL=0
check() { # LABEL COMMAND...
  local label="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then ok "$label"; PASS=$((PASS + 1)); else fail "$label"; fi
}

three_running() {
  local out
  out="$($DOCKER inspect -f '{{.State.Running}}' ansible-lab-web1 ansible-lab-web2 ansible-lab-tools1 2>/dev/null | tr -d '\n')"
  [ "$out" = "truetruetrue" ]
}
code_is() { [ "$(http_code "$1")" = "$2" ]; }
ansible_version() { local out; out="$(ctl ansible --version)" || return 1; grep -q 'core 2.18' <<<"$out"; }
three_hosts() { local out; out="$(ctl ansible all --list-hosts)" || return 1; grep -q 'hosts (3)' <<<"$out"; }
vault_encrypted() { local h; h="$(head -c 14 "$VAULT_FILE")"; [ "$h" = '$ANSIBLE_VAULT' ]; }
three_pongs() { local out; out="$(ctl ansible all -m ping -o)" || return 1; [ "$(grep -c '"ping": "pong"' <<<"$out")" = "3" ]; }
page_says_ansible() { local out; out="$(curl -s -m 4 "$1/")"; grep -q "Managed by Ansible" <<<"$out"; }
secret_mode() { [ "$(node_sh web1 'stat -c "%a %U" /etc/site/secret.env')" = "600 root" ]; }
idempotent() {
  local out; out="$(play playbooks/site.yml)" || return 1
  [ "$(total_changed "$out")" = "0" ] && [ "$(total_failed "$out")" = "0" ]
}
verify_passes() { local out; out="$(play playbooks/verify.yml)" || return 1; [ "$(total_failed "$out")" = "0" ]; }
secret_not_on_page() {
  local token page
  token="$(ctl ansible-vault view /ansible/inventory/group_vars/all/vault.yml | sed -n 's/^vault_site_api_token: "\(.*\)"$/\1/p')"
  [ -n "$token" ] || return 1
  page="$(curl -s -m 4 "$WEB1_URL/")"
  ! grep -qF "$token" <<<"$page"
}

log "Smoke test"
check "Docker daemon reachable"                      $DOCKER info
check "web1, web2 and tools1 containers are running" three_running
check "Ansible 2.18 runs in the control container"   ansible_version
check "inventory lists 3 servers"                    three_hosts
check "the vault file is encrypted"                  vault_encrypted
check "Ansible reaches all 3 servers (ping/pong)"    three_pongs
check "web1 answers on port 8081"                    code_is "$WEB1_URL/healthz" 200
check "web2 answers on port 8082"                    code_is "$WEB2_URL/healthz" 200
check "web1's page says 'Managed by Ansible'"        page_says_ansible "$WEB1_URL"
check "the secret file on web1 is mode 600, root"    secret_mode
check "the secret token is not on the web page"      secret_not_on_page
check "a second site.yml run changes nothing"        idempotent
check "verify.yml passes (pages and permissions)"    verify_passes

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  printf '\033[1;32mAll %d checks passed.\033[0m\n' "$TOTAL"
else
  printf '\033[1;31m%d of %d checks passed.\033[0m See "If something goes wrong" in STEPS.md.\n' "$PASS" "$TOTAL" >&2
  exit 1
fi
IP="$(public_ip)"
echo "Open in your browser: http://${IP}:8081/  and  http://${IP}:8082/"
