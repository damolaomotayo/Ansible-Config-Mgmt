#!/usr/bin/env bash
# Shared helpers. Sourced by the other scripts, not run directly.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Use plain docker if the current user may talk to the daemon, otherwise sudo.
if docker info >/dev/null 2>&1; then DOCKER="docker"; else DOCKER="sudo docker"; fi
DC="$DOCKER compose"

VAULT_FILE="$ROOT/ansible/inventory/group_vars/all/vault.yml"
WEB1_URL="${WEB1_URL:-http://127.0.0.1:8081}"      # as seen from the instance itself
WEB2_URL="${WEB2_URL:-http://127.0.0.1:8082}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

set_env() { # KEY VALUE: add the line to .env unless it is already there
  grep -q "^$1=" "$ROOT/.env" || echo "$1=$2" >> "$ROOT/.env"
}
ensure_env() { # create .env on first run; the control container runs as YOUR user id, saved here for compose
  [ -f "$ROOT/.env" ] || cp "$ROOT/.env.example" "$ROOT/.env"
  set_env HOST_UID "$(id -u)"
  set_env HOST_GID "$(id -g)"
  set -a; . "$ROOT/.env"; set +a
}
ensure_keys() { # SSH key pair the control container uses to log in to the servers
  if [ ! -f "$ROOT/.ssh/id_ed25519" ]; then
    mkdir -p "$ROOT/.ssh"; chmod 700 "$ROOT/.ssh"
    ssh-keygen -q -t ed25519 -N '' -C ansible-lab -f "$ROOT/.ssh/id_ed25519"
  fi
}
ensure_vault_pass() { # the password that locks the Ansible Vault file
  if [ ! -s "$ROOT/.vault_pass" ]; then
    ( umask 077; openssl rand -hex 16 > "$ROOT/.vault_pass" )
  fi
}
ensure_secrets() { ensure_env; ensure_keys; ensure_vault_pass; }
ensure_env

# ---- the Ansible control container (runs as you, so files it writes are yours) ----
ctl() { $DC run --rm -T control "$@"; }
play() { ctl ansible-playbook "$@"; }                    # play playbooks/site.yml [options]

ensure_vault_file() { # creates ansible/.../vault.yml with a random token and ENCRYPTS it. Needs the control image.
  [ -f "$VAULT_FILE" ] && return 0
  ( umask 077
    printf -- '---\nvault_site_api_token: "%s"\n' "$(openssl rand -hex 16)" > "$VAULT_FILE" )
  if ! ctl ansible-vault encrypt /ansible/inventory/group_vars/all/vault.yml >/dev/null 2>&1; then
    rm -f "$VAULT_FILE"                                   # never leave the plaintext behind
    return 1
  fi
}

public_ip() { # EC2 metadata (IMDSv2), then a public what-is-my-ip fallback
  local tok ip=""
  tok="$(curl -fsS -m 2 -X PUT http://169.254.169.254/latest/api/token \
         -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  if [ -n "$tok" ]; then
    ip="$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $tok" \
          http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
  fi
  if [ -z "$ip" ]; then
    ip="$(curl -fsS -m 4 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  echo "${ip:-<EC2-PUBLIC-IP>}"
}

http_code() { curl -s -o /dev/null -m 4 -w '%{http_code}' "$1" 2>/dev/null || true; }   # 000 = no connection

wait_http() { # LABEL URL [SECONDS]  (any 2xx)
  local label="$1" url="$2" secs="${3:-60}" i
  for ((i = 0; i < secs; i++)); do
    if curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null; then ok "$label is up"; return 0; fi
    sleep 1
  done
  fail "$label did not answer at $url within ${secs}s"
  return 1
}

# ---- the three servers ----
nodes_up()    { $DC up -d --build web1 web2 tools1; }
nodes_reset() { $DC up -d --force-recreate --no-deps web1 web2 tools1; }     # brand-new, unconfigured servers
node_sh()     { $DOCKER exec "ansible-lab-$1" sh -c "$2"; }                  # node_sh web1 'ls /var/www'

wait_ssh() { # until Ansible can log in to all 3 servers
  local i out
  for ((i = 0; i < ${1:-60}; i++)); do
    out="$(ctl ansible all -m ping -o 2>&1 || true)"
    if [ "$(grep -c '"ping": "pong"' <<<"$out")" = "3" ]; then return 0; fi
    sleep 1
  done
  return 1
}

# ---- reading Ansible's "PLAY RECAP" ----
# recap_field HOST FIELD OUTPUT   e.g.  recap_field web1 changed "$out"  ->  3
recap_field() {
  local line
  line="$(grep -E "^$1 +: " <<<"$3" | tail -n 1)"
  sed -n "s/.* $2=\([0-9]*\).*/\1/p" <<<"$line"
}
total_changed() { # OUTPUT -> sum of changed= over all hosts in the recap
  local sum=0 n
  for n in $(grep -E '^[a-z0-9]+ +: ok=' <<<"$1" | sed -n 's/.* changed=\([0-9]*\).*/\1/p'); do sum=$((sum + n)); done
  echo "$sum"
}
total_failed() {
  local sum=0 n
  for n in $(grep -E '^[a-z0-9]+ +: ok=' <<<"$1" | sed -n 's/.* failed=\([0-9]*\).*/\1/p'); do sum=$((sum + n)); done
  echo "$sum"
}
