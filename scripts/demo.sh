#!/usr/bin/env bash
# Scripted demo. Usage: ./scripts/demo.sh [converge|drift|change|rolling|vault|adhoc|all]
# Every scenario starts from three brand-new servers and checks its own result.
# Keep http://<EC2-PUBLIC-IP>:8081/ and :8082/ open in a browser while it runs and refresh them.
# DEMO_VERBOSE=1 prints Ansible's full output instead of just the summary lines.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ -f "$ROOT/.vault_pass" ] || die "Run ./scripts/up.sh first."

FAILURES=0
assert() { # LABEL COMMAND...
  local label="$1"; shift
  if "$@"; then ok "$label"; else fail "$label"; FAILURES=$((FAILURES + 1)); fi
}
finish() {
  if [ "$FAILURES" -eq 0 ]; then printf '\n\033[1;32mPASS\033[0m  %s\n\n' "$1"; else printf '\n\033[1;31mFAIL\033[0m  %s\n\n' "$1"; exit 1; fi
}
say() { printf '    %s\n' "$*"; }
has() { grep -q -- "$1" <<<"$2"; }                         # has PATTERN TEXT  (text is passed in, never piped)
number_is() { [ "$1" = "$2" ]; }
page() { curl -s -m 4 "$1/"; }

MSG='{"site_message": "Hello from the demo"}'      # extra variables with spaces must be given as JSON
OUT=""
run() { # run PLAYBOOK [options]: stores the full output in $OUT, shows the interesting lines
  local rc=0
  OUT="$(play "$@" 2>&1)" || rc=$?
  if [ -n "${DEMO_VERBOSE:-}" ]; then echo "$OUT"; else
    grep -E '^(PLAY RECAP|(web1|web2|tools1) +: ok=|RUNNING HANDLER)' <<<"$OUT" | sed 's/^/      /'
  fi
  [ "$rc" -eq 0 ] || { echo "$OUT" | tail -25 >&2; fail "ansible-playbook exited with code $rc"; FAILURES=$((FAILURES + 1)); }
}

fresh() { # three brand-new, unconfigured servers
  log "Creating three brand-new servers"
  nodes_reset >/dev/null 2>&1 || { fail "could not recreate the servers"; exit 1; }
  wait_ssh 60 || { fail "Ansible cannot log in to the new servers"; exit 1; }
}
converged() { # brand-new servers, fully configured
  fresh
  log "First run of site.yml on the new servers"
  run playbooks/site.yml
  wait_http "web1" "$WEB1_URL/healthz" 20 >/dev/null
  wait_http "web2" "$WEB2_URL/healthz" 20 >/dev/null
}

scenario_converge() {
  log "SCENARIO converge: from empty servers to a working fleet with one command, and a second run that changes nothing"
  fresh
  assert "a new server has no nginx yet"                  number_is "$(http_code "$WEB1_URL/healthz")" 000
  log "First run: Ansible does the work"
  run playbooks/site.yml
  assert "the run had no failures"                        number_is "$(total_failed "$OUT")" 0
  assert "web1 was changed by the run"                    test "$(recap_field web1 changed "$OUT")" -gt 0
  wait_http "web1" "$WEB1_URL/healthz" 20 >/dev/null
  wait_http "web2" "$WEB2_URL/healthz" 20 >/dev/null
  assert "web1 serves its blue page"                      has "web1" "$(page "$WEB1_URL")"
  assert "web2 serves its own page"                       has "<h1>web2</h1>" "$(page "$WEB2_URL")"
  assert "tools1 got the disk report script"              has "report from tools1" "$(node_sh tools1 /usr/local/bin/disk-report.sh)"
  log "Second run: nothing should change (idempotence)"
  run playbooks/site.yml
  assert "second run: changed=0 on every server"          number_is "$(total_changed "$OUT")" 0
  finish converge
}

scenario_drift() {
  log "SCENARIO drift: someone edits a server by hand; Ansible shows the difference and repairs it"
  converged
  say "Defacing web1's page by hand"
  node_sh web1 'echo "defaced by hand" > /var/www/site/index.html'
  assert "web1 now shows the defaced page"                has "defaced" "$(page "$WEB1_URL")"
  log "Preview only (--check --diff): changes nothing, shows what would change"
  run playbooks/site.yml --check --diff
  assert "preview: web1 would change"                     number_is "$(recap_field web1 changed "$OUT")" 1
  assert "preview: web2 would not change"                 number_is "$(recap_field web2 changed "$OUT")" 0
  assert "the diff mentions the page"                     has "defaced by hand" "$OUT"
  assert "the preview did not touch the page"             has "defaced" "$(page "$WEB1_URL")"
  log "Real run: Ansible repairs it"
  run playbooks/site.yml
  assert "web1 was repaired (changed=1)"                  number_is "$(recap_field web1 changed "$OUT")" 1
  assert "web1's page is back to normal"                  has "Managed by Ansible" "$(page "$WEB1_URL")"
  assert "web2 was left alone (changed=0)"                number_is "$(recap_field web2 changed "$OUT")" 0
  finish drift
}

scenario_change() {
  log "SCENARIO change: change one variable, every server follows; a config change reloads nginx"
  converged
  say "Setting site_message with -e (a command-line variable)"
  run playbooks/site.yml -e "$MSG"
  assert "web1 shows the new message"                     has "Hello from the demo" "$(page "$WEB1_URL")"
  assert "web2 shows the new message"                     has "Hello from the demo" "$(page "$WEB2_URL")"
  assert "tools1 was not touched"                         number_is "$(recap_field tools1 changed "$OUT")" 0
  say "Turning on browser caching (changes nginx's own config, so nginx must be reloaded)"
  run playbooks/site.yml -e "$MSG" -e site_cache_seconds=60
  assert "the 'reload nginx' handler ran"                 has "RUNNING HANDLER \[nginx_site : reload nginx\]" "$OUT"
  assert "the server now sends Cache-Control: max-age=60" has "max-age=60" "$(curl -sI -m 4 "$WEB1_URL/")"
  run playbooks/site.yml -e "$MSG" -e site_cache_seconds=60
  assert "same inputs again: changed=0 everywhere"        number_is "$(total_changed "$OUT")" 0
  say "Back to the defaults"
  run playbooks/site.yml
  assert "web1 shows the original message again"          has "Configured by Ansible" "$(page "$WEB1_URL")"
  finish change
}

scenario_rolling() {
  log "SCENARIO rolling: update one server at a time, checking each is healthy before touching the next"
  converged
  assert "both servers start on release 1"                has "Release 1" "$(page "$WEB1_URL")$(page "$WEB2_URL")"
  say "Rolling out release 2 (serial: 1)"
  run playbooks/rolling.yml -e site_version=2
  assert "web1 shows release 2"                           has "Release 2" "$(page "$WEB1_URL")"
  assert "web2 shows release 2"                           has "Release 2" "$(page "$WEB2_URL")"
  local first_web1 first_web2
  first_web1="$(grep -n 'Wait until web1 is healthy' <<<"$OUT" | head -n 1 | cut -d: -f1)"
  first_web2="$(grep -n 'Wait until web2 is healthy' <<<"$OUT" | head -n 1 | cut -d: -f1)"
  say "health check lines in the output: web1 at line ${first_web1:-?}, web2 at line ${first_web2:-?}"
  assert "web1 was checked healthy BEFORE web2 was touched" test -n "$first_web1" -a -n "$first_web2" -a "${first_web1:-0}" -lt "${first_web2:-0}"
  run playbooks/site.yml
  assert "back to release 1 with the normal run"          has "Release 1" "$(page "$WEB1_URL")"
  finish rolling
}

scenario_vault() {
  log "SCENARIO vault: a secret is stored encrypted, delivered to the server, and never shown"
  converged
  local token head
  head="$(head -c 14 "$VAULT_FILE")"
  assert "the vault file on disk is encrypted"            has '$ANSIBLE_VAULT' "$head"
  token="$(ctl ansible-vault view /ansible/inventory/group_vars/all/vault.yml | sed -n 's/^vault_site_api_token: "\(.*\)"$/\1/p')"
  assert "with the password it can be read"               test -n "$token"
  assert "the secret is NOT in any file of the repo"      bash -c '! grep -rqF "$0" ansible docker-compose.yml node control scripts' "$token"
  assert "web1 has the secret in a root-only file"        number_is "$(node_sh web1 'stat -c "%a %U" /etc/site/secret.env')" "600 root"
  assert "the file holds the real value"                  has "API_TOKEN=$token" "$(node_sh web1 'cat /etc/site/secret.env')"
  assert "the web page does not show it"                  bash -c '! grep -qF "$0" <<<"$1"' "$token" "$(page "$WEB1_URL")"
  assert "a wrong password cannot read the vault file"    bash -c '! '"$DC"' run --rm -T control sh -c "echo wrong > /tmp/p; ansible-vault view --vault-password-file /tmp/p /ansible/inventory/group_vars/all/vault.yml" >/dev/null 2>&1'
  finish vault
}

scenario_adhoc() {
  log "SCENARIO adhoc: one-off commands on the whole fleet, no playbook needed"
  converged
  local out
  out="$(ctl ansible all -m ping -o 2>&1)"
  say "ansible all -m ping"
  assert "all 3 servers answer pong"                      number_is "$(grep -c '"ping": "pong"' <<<"$out")" 3
  out="$(ctl ansible web -m setup -a 'filter=ansible_distribution*' 2>&1)"
  say "ansible web -m setup -a 'filter=ansible_distribution*'  (facts Ansible discovers by itself)"
  assert "facts say Ubuntu"                               has '"ansible_distribution": "Ubuntu"' "$out"
  out="$(ctl ansible all -a 'cat /etc/ansible-managed.txt' 2>&1)"
  say "ansible all -a 'cat /etc/ansible-managed.txt'"
  assert "every server has the managed-by note"           number_is "$(grep -c 'configured by Ansible' <<<"$out")" 3
  out="$(ctl ansible web -m service -a 'name=nginx state=started' -o 2>&1)"
  say "ansible web -m service -a 'name=nginx state=started'"
  assert "nginx is already running: changed=false"        number_is "$(grep -c 'SUCCESS.*"changed": false' <<<"$out")" 2
  finish adhoc
}

case "${1:-all}" in
  converge) scenario_converge ;;
  drift)    scenario_drift ;;
  change)   scenario_change ;;
  rolling)  scenario_rolling ;;
  vault)    scenario_vault ;;
  adhoc)    scenario_adhoc ;;
  all)      scenario_converge; scenario_drift; scenario_change; scenario_rolling; scenario_vault; scenario_adhoc
            echo "All scenarios passed." ;;
  *)        die "usage: $0 [converge|drift|change|rolling|vault|adhoc|all]" ;;
esac
