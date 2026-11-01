#!/usr/bin/env bash
# Run this BEFORE the demo. It pulls the base images, builds both images (downloads packages from Ubuntu and
# PyPI), checks Ansible can read every playbook and the inventory, and runs the tests, so any failure shows up
# now and not in front of an audience.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ensure_secrets

FAILS=0
check() { # LABEL COMMAND...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else fail "$label"; FAILS=$((FAILS + 1)); fi
}

retry3() { # COMMAND...
  local i
  for i in 1 2 3; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}
pull_image() { $DOCKER pull "$1"; }

# Docker Hub's /v2/ endpoint answers HTTP 401 (login required) when it is reachable.
# So 200 and 401 both mean "reachable". Do not add curl -f here.
hub_reachable() {
  local code
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' https://registry-1.docker.io/v2/ || true)"
  [ "$code" = "200" ] || [ "$code" = "401" ]
}
pypi_reachable()   { [ "$(curl -s -o /dev/null -m 10 -w '%{http_code}' https://pypi.org/simple/ansible-core/ || true)" = "200" ]; }
ubuntu_reachable() { [ "$(curl -s -o /dev/null -m 10 -w '%{http_code}' http://archive.ubuntu.com/ubuntu/dists/noble/Release || true)" = "200" ]; }
disk_ok()   { [ "$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')" -ge 5 ]; }
mem_ok()    { [ "$(free -m | awk '/^Mem:/{print $2}')" -ge 1500 ]; }
port_free() { ! python3 -c 'import socket, sys; s = socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)' "$1"; }
build_images()   { $DC build web1 control; }
ansible_runs()   { ctl ansible --version; }
syntax_ok()      { local f; for f in site rolling verify; do ctl ansible-playbook "playbooks/$f.yml" --syntax-check >/dev/null || return 1; done; }
inventory_ok()   { local out; out="$(ctl ansible all --list-hosts)" || return 1; grep -q 'hosts (3)' <<<"$out"; }
all_tests()      { PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests; }

log "System checks"
check "Docker daemon reachable"                  $DOCKER info
check "Docker Compose v2 installed"              $DC version
check "At least 5 GB free disk"                  disk_ok
check "At least 1.5 GB RAM"                      mem_ok
if [ -n "$($DC ps -q 2>/dev/null)" ]; then
  ok "Lab already running (port check skipped)"
else
  for p in 8081 8082; do check "Port $p is free" port_free "$p"; done
fi
check "Docker Hub reachable (HTTP 200 or 401)"   hub_reachable
check "PyPI reachable (Ansible is installed from it)" pypi_reachable
check "Ubuntu package archive reachable"         ubuntu_reachable

log "Pulling and building (up to 3 tries each)"
check "Pull ${UBUNTU_IMAGE:-ubuntu:24.04}"       retry3 pull_image "${UBUNTU_IMAGE:-ubuntu:24.04}"
check "Pull ${PYTHON_IMAGE:-python:3.12-slim}"   retry3 pull_image "${PYTHON_IMAGE:-python:3.12-slim}"
check "Build the server and control images"      retry3 build_images

log "Ansible"
check "Ansible runs in the control container"    ansible_runs
check "Create the encrypted vault file"          ensure_vault_file
check "All playbooks pass the syntax check"      syntax_ok
check "Inventory lists the 3 servers"            inventory_ok

log "Tests"
check "Unit tests and repo tests"                all_tests

echo
if [ "$FAILS" -eq 0 ]; then
  echo "Preflight passed. Safe to run ./scripts/up.sh"
  exit 0
fi
echo "Preflight found $FAILS problem(s). See the troubleshooting table in STEPS.md." >&2
echo "Pull failed? Run 'sudo docker login' with a free Docker Hub account. Build failed? Run: $DC build web1 control --progress=plain" >&2
exit 1
