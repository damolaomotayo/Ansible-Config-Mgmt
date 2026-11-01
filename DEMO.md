# Demo cheat sheet (1-minute read)

**What it does:** Setting up a server by hand (install software, edit config files, create users) is slow and nobody remembers exactly what was done. With **Ansible** you write it down once, as a **playbook**, and run it on any number of servers. Here, three fresh servers are configured with one command, all on this one EC2 instance.

**How it works:**
1. The **inventory** lists the servers and their groups (`web1`, `web2`, `tools1`).
2. **Roles** describe what each group needs: install nginx, write a config file from a template, create a user.
3. `ansible-playbook` logs in to every server over SSH and does only what is missing.
4. Run it again and it changes nothing (`changed=0`): the playbook describes the *end state*, not a list of commands.
5. Passwords and tokens live in an **Ansible Vault** file: encrypted on disk, delivered to the server, never shown.

**Example 1: drift repair (`./scripts/demo.sh drift`)**
Open `http://<PUBLIC-IP>:8081/`. Deface the page by hand on the server. Run the playbook with `--check --diff`: Ansible shows exactly what is wrong without touching anything. Run it for real: the page is repaired and the other server is left alone.

**Example 2: rolling update (`./scripts/demo.sh rolling`)**
Release 2 goes to `web1` first; only when it answers its health check does `web2` get it. Refresh both pages to see "Release 2".

**Bonus:** `change` shows one variable updating every server, and nginx reloaded only when its own config changes; `adhoc` runs one-off commands on the whole fleet; `vault` proves the secret is encrypted.

**If asked "why not a shell script?":** A script says *how* and breaks when run twice. Ansible says *what*, can preview changes, and is safe to repeat.
