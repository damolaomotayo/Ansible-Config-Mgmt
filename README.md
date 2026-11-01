# Configuration Management with Ansible

Three fresh servers, configured by one command. A small fleet (two web servers and a tool server) is described once as **Ansible playbooks and roles**; Ansible logs in to each server over SSH, installs nginx, writes config files from templates, creates users and delivers an encrypted secret. Run it twice and the second run changes nothing. Break something by hand and Ansible shows the difference and repairs it. Everything runs on **one EC2 instance**: the "servers" are Ubuntu containers running SSH, and Ansible runs from its own container.

**Start with [STEPS.md](STEPS.md)**: prerequisites first (including the exact security group rules and every `chmod`), then copy-paste commands. **Presenting it? Read [DEMO.md](DEMO.md) first.**

```
 browser ──http://<EC2-PUBLIC-IP>:8081/──▶ web1 ─┐
          ──http://<EC2-PUBLIC-IP>:8082/──▶ web2 ─┤ servers: Ubuntu 24.04 + sshd + python3 (containers)
                                              tools1 ─┘
 ./scripts/ctl.sh ─▶ control container (ansible-core 2.18) ──SSH (key login, private network)──▶ all three
                       │ inventory/  playbooks/  roles/  Ansible Vault (encrypted secret)
```

## What's in it

| Piece | What it demonstrates |
|---|---|
| `ansible/inventory/` | Hosts and groups; `group_vars` and `host_vars` (web1 is blue, web2 is orange) |
| `roles/common` | Packages, group and user, a managed-by note (applied to every server) |
| `roles/nginx_site` | Install, templates (page, nginx config), file modes, a **handler** that reloads nginx, `nginx -t` check |
| `roles/toolbox` | Packages, a script from a template, logrotate, a cron job (different group, different role) |
| `playbooks/site.yml` | The whole fleet in one file; safe to run repeatedly (**idempotent**) |
| `playbooks/rolling.yml` | `serial: 1` rolling update with a health check between servers |
| `playbooks/verify.yml` | Read-only assertions (pages, secret file permissions) |
| Ansible Vault | `group_vars/all/vault.yml` is encrypted; the secret lands in a root-only file and never on a page |
| `scripts/demo.sh` | Six self-checking scenarios, each ending in `PASS` or `FAIL` |

## The demo scenarios

| Scenario | What happens | Expected result |
|---|---|---|
| `converge` | Three brand-new servers, one `site.yml` run, then a second run | Pages are up; second run `changed=0` on every server |
| `drift` | Deface web1's page by hand | `--check --diff` shows it (web1 `changed=1`, web2 `changed=0`) and touches nothing; a real run repairs it |
| `change` | Change `site_message`, then enable caching | Both pages update; nginx is reloaded only for the config change; same inputs again: `changed=0` |
| `rolling` | `rolling.yml -e site_version=2` | web1 is health-checked before web2 is touched; both show Release 2 |
| `vault` | Inspect the secret end to end | Encrypted on disk, root-only file on the server, not on the page, wrong password fails |
| `adhoc` | One-off commands on the fleet | 3 pongs, facts say Ubuntu, `service` reports `changed: false` |

## Key ideas to be able to explain

- **Declarative and idempotent:** a playbook states the end state; running it again changes nothing, so it is safe to repeat.
- **Agentless:** nothing is installed on the servers except SSH and Python; Ansible connects, does the work and leaves.
- **Inventory, groups and variables:** which servers exist, how they are grouped, and which setting wins (command line > host_vars > group_vars > role defaults).
- **Roles:** reusable bundles (tasks, templates, handlers, defaults), so a playbook reads like a table of contents.
- **Templates (Jinja2):** one file, many servers; each page shows its own name, colour and OS (Ansible's *facts*).
- **Handlers:** "reload nginx" runs only when a file that needs it actually changed.
- **Check mode and diff:** a safe preview of exactly what a run would change.
- **Rolling updates:** `serial: 1` plus a health check means a bad release stops after one server.
- **Vault:** secrets can live in Git encrypted; only the vault password (never committed) opens them.

## Repo layout

```
README.md  STEPS.md  DEMO.md  DIAGRAM_PROMPT.md  .env.example  docker-compose.yml
node/       Dockerfile (Ubuntu + sshd + python3, packages pre-downloaded)  entrypoint.sh
control/    Dockerfile (python + pinned ansible-core)  entrypoint.sh
ansible/    ansible.cfg  inventory/ (hosts, group_vars, host_vars)  playbooks/  roles/
scripts/    lib.sh ctl.sh setup.sh preflight.sh up.sh smoke.sh demo.sh destroy.sh
tests/      test_ansible_logic.py  test_scripts.py  test_repo.py
```

## Limitations (kept simple on purpose)

- **The servers are containers**, not VMs. They have no systemd, so services are started with the `service` command and cron/ssh are the only daemons. On real Ubuntu VMs the same roles work with systemd.
- **Packages are pre-downloaded** into the server image (not installed), so Ansible's `apt` tasks are fast and need no download during the demo. They are still real installs.
- **SSH uses one key pair** generated on the instance (`.ssh/`, git-ignored). Servers accept key login only and SSH is never published to the internet.
- **The vault password is a plain file** (`.vault_pass`, git-ignored). Real teams keep it in a password manager or CI secret store.
- **Tests:** the playbooks and roles are tested for real with ansible-core (a scratch folder as the "server", plus a real run on an Ubuntu 24.04 machine with real `apt`, users, nginx started through `service`, cron and a handler reload), and the script helpers with a stub `docker`. The Docker parts (building the two images, SSH between the containers, `docker compose`) are proven on the instance by `preflight.sh`, `smoke.sh` and `demo.sh`.
- **Pinned versions** (`ubuntu:24.04`, `python:3.12-slim`, `ansible-core==2.18.1`) can be changed in `.env` / `control/Dockerfile` if one is ever withdrawn.
