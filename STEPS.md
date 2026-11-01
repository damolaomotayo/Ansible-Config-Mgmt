# STEPS: Configuration Management with Ansible

## Prerequisites (set these up BEFORE step 1)

| Need | Details |
|---|---|
| **AWS account** | Any account that can launch EC2. No IAM role, no other AWS service. Use one region for everything below. |
| **Instance type** | `m7i-flex.large` (2 vCPU, 8 GiB). This project needs about 1.5 GiB. |
| **OS image (AMI)** | Ubuntu Server 24.04 LTS (64-bit x86). 22.04 also works. |
| **Disk** | 20 GiB gp3. |
| **Key pair** | An RSA `.pem` key pair created in EC2 (step 0a). |
| **Security group** | Created in step 0b. **Inbound: exactly two rules: (1) SSH, TCP port 22; (2) Custom TCP, port range 8081-8082 (the web1 and web2 pages). Both with source My IP.** **Outbound: leave the default (All traffic, 0.0.0.0/0)**, because the instance must reach Docker Hub, PyPI (Ansible is installed from it), Ubuntu's apt mirrors and Docker's apt repo. |
| **Code on the instance** | Option A: private GitHub repo plus a fine-grained token (Contents: Read) used as the password for `git clone`. Option B: copy the zip with `scp` (step 2). |
| **Accounts / tokens** | None. The SSH key pair and the Ansible Vault password are generated on the instance (git-ignored). |
| **On your laptop** | A terminal with `ssh`/`scp` and a web browser. **No SSH tunnel is needed:** you open the pages directly at `http://<PUBLIC-IP>:8081/` and `:8082/`. |

**Time:** about 10 minutes of setup (first run downloads two images and builds two more), 4 minutes for the full demo. **Cost:** about $0.10/hour at your quoted rate, plus pennies for the disk. Do step 12 when finished.

---

## Step 0: Create the key pair, security group and instance (AWS console)

**0a. Key pair.** EC2 > Network & Security > Key pairs > **Create key pair**. Name `ansible-lab-key`, type **RSA**, format **.pem**. The file downloads once; keep it safe. On your laptop, lock down its permissions:

```bash
# Linux / macOS
chmod 400 ~/Downloads/ansible-lab-key.pem
```
```powershell
# Windows PowerShell (OpenSSH)
icacls "$HOME\Downloads\ansible-lab-key.pem" /inheritance:r /grant:r "$($env:USERNAME):(R)"
```

**0b. Security group.** EC2 > Network & Security > Security Groups > **Create security group**.
- Name: `ansible-lab-sg`, Description: `SSH and lab pages from my IP`, VPC: the default VPC.
- **Inbound rules > Add rule** (do it twice):
  1. Type `SSH`, Protocol `TCP`, Port range `22`, Source `My IP`
  2. Type `Custom TCP`, Protocol `TCP`, Port range `8081-8082`, Source `My IP`
- **Outbound rules:** leave the default rule (Type `All traffic`, Destination `0.0.0.0/0`).
- Click **Create security group**.

> Showing the demo to someone on a different network? Their browser is blocked by "My IP". Either share your screen, or add their public IP followed by `/32` as the source of the 8081-8082 rule. Do not use `0.0.0.0/0`.

**0c. Launch the instance.** EC2 > Instances > **Launch instances**.
- Name: `ansible-lab-box`
- Application and OS Image: **Ubuntu**, choose **Ubuntu Server 24.04 LTS**, architecture **64-bit (x86)**
- Instance type: `m7i-flex.large`
- Key pair: `ansible-lab-key`
- Network settings > **Edit**: Auto-assign public IP **Enable**; Firewall: **Select existing security group** > `ansible-lab-sg`
- Configure storage: **20 GiB**, `gp3`
- Advanced details > IAM instance profile: leave as **No IAM role**
- Click **Launch instance**, wait until Instance state is `Running` and Status check is `2/2 passed`, then copy the **Public IPv4 address**. This is your `<PUBLIC-IP>` below.

> If your network changes later, SSH and the pages will time out because "My IP" no longer matches. Edit **both** inbound rules of `ansible-lab-sg` and set Source to My IP again. Stopping and starting the instance also gives it a new public IP.

## Step 1: Connect to the instance (from your laptop)

```bash
ssh -i ~/Downloads/ansible-lab-key.pem ubuntu@<PUBLIC-IP>
```
Type `yes` at the fingerprint prompt. Every command from here to step 11 runs **on the instance**.

## Step 2: Update packages and get the code

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git unzip
```

**Option A (private GitHub repo):**
```bash
git clone https://github.com/<you>/ansible-config-mgmt.git
cd ansible-config-mgmt
```
When asked, username = your GitHub username, password = the fine-grained token.

**Option B (no GitHub), run from your laptop in the folder holding the zip, then continue on the instance:**
```bash
# on your laptop
scp -i ~/Downloads/ansible-lab-key.pem ansible-config-mgmt.zip ubuntu@<PUBLIC-IP>:~
# on the instance
unzip ansible-config-mgmt.zip
cd ansible-config-mgmt
```

## Step 3: Make the scripts executable (do not skip)

Files that were zipped, uploaded to GitHub or copied between systems often lose their "executable" flag. Without this you get `Permission denied`.

```bash
chmod +x scripts/*.sh node/entrypoint.sh control/entrypoint.sh
ls -l scripts/        # every .sh line should start with -rwxr-xr-x
```

## Step 4: Install Docker

```bash
./scripts/setup.sh
```
It runs `apt update`/`upgrade`, installs `ca-certificates curl git gnupg openssl openssh-client python3 unzip`, installs Docker Engine and Compose v2 from Docker's official repo (falling back to Ubuntu's `docker.io` package if that repo is unreachable), starts Docker and prints the versions. Takes 3-5 minutes. It ends with `Setup complete.` Ansible itself is **not** installed on the instance: it runs from its own container.

## Step 5: Unit tests

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```
Ends with `OK` (takes a few seconds). Nine Ansible-logic tests show as `skipped` because the instance has no Ansible installed on the host; they were run for real before the zip was built. The rest test the scripts and the repo layout.

## Step 6: Preflight (run this well before the demo)

```bash
./scripts/preflight.sh
```
Creates `.env`, an SSH key pair and a random vault password; checks Docker, disk, memory and ports 8081-8082; checks that Docker Hub, PyPI and Ubuntu's package archive are reachable; pulls `ubuntu:24.04` and `python:3.12-slim`; builds the server image and the Ansible control image; creates the encrypted vault file; checks every playbook's syntax and the inventory; and runs the tests. Every line must say `ok`, and the last line is `Preflight passed. Safe to run ./scripts/up.sh`. First run takes 3-6 minutes.

## Step 7: Create and configure the fleet

```bash
./scripts/up.sh
```
Builds the images, starts three brand-new servers (`web1`, `web2`, `tools1`), waits until Ansible can log in to all of them, then runs `ansible-playbook playbooks/site.yml`. Takes about 1-2 minutes. The play recap at the end shows `failed=0` for every server, and it prints:

```
web1 : http://<PUBLIC-IP>:8081/      (blue page)
web2 : http://<PUBLIC-IP>:8082/      (orange page)
```

## Step 8: Health check

```bash
./scripts/smoke.sh
```
Every line says `ok` and it ends with **`All 13 checks passed.`** (It includes a second `site.yml` run that must report `changed=0`.)

## Step 9: Open the pages in your browser (on your laptop)

- `http://<PUBLIC-IP>:8081/`: a **blue** page headed `web1`, with "Managed by Ansible", the release, the group and the operating system Ansible discovered.
- `http://<PUBLIC-IP>:8082/`: an **orange** page headed `web2`.

## Step 10: Run the demo (on the instance)

```bash
./scripts/demo.sh all           # all six scenarios, about 5 minutes
```
Or one at a time (each starts from three brand-new servers):
```bash
./scripts/demo.sh converge   # empty servers to a working fleet; second run changes nothing
./scripts/demo.sh drift      # deface a page by hand; --check --diff shows it; a real run repairs it
./scripts/demo.sh change     # one variable updates every server; nginx reloads only when its config changes
./scripts/demo.sh rolling    # release 2, one server at a time with a health check in between
./scripts/demo.sh vault      # the secret is encrypted on disk, root-only on the server, never on a page
./scripts/demo.sh adhoc      # one-off commands on the whole fleet
```
Each scenario ends with a green `PASS`. Keep both pages open and refresh while they run. To see Ansible's complete output instead of the summary lines: `DEMO_VERBOSE=1 ./scripts/demo.sh drift`.

## Step 11: Useful commands (a manual walkthrough you can do live)

```bash
./scripts/ctl.sh ansible-inventory --graph                          # the fleet and its groups
./scripts/ctl.sh ansible all -m ping                                # can Ansible reach everything? (3 x pong)
./scripts/ctl.sh ansible-playbook playbooks/site.yml                # configure: changed=0 means nothing to do
sudo docker exec ansible-lab-web1 sh -c 'echo defaced > /var/www/site/index.html'    # break it by hand
./scripts/ctl.sh ansible-playbook playbooks/site.yml --check --diff # preview: shows the defaced page, changes nothing
./scripts/ctl.sh ansible-playbook playbooks/site.yml                # repair: web1 changed=1
./scripts/ctl.sh ansible-playbook playbooks/site.yml -e '{"site_message": "Hello"}'   # change a variable
./scripts/ctl.sh ansible-playbook playbooks/rolling.yml -e site_version=2             # rolling update
./scripts/ctl.sh ansible-playbook playbooks/site.yml                # back to release 1
./scripts/ctl.sh ansible-playbook playbooks/verify.yml              # read-only checks
./scripts/ctl.sh ansible-vault view inventory/group_vars/all/vault.yml   # the decrypted secret (needs the vault password)
head -c 60 ansible/inventory/group_vars/all/vault.yml               # what is really on disk: $ANSIBLE_VAULT;1.1;AES256...
```

## Step 12: Clean up, then terminate the instance

```bash
./scripts/destroy.sh
```
Then in the AWS console: EC2 > Instances > select `ansible-lab-box` > **Instance state > Terminate instance**. Optionally delete the `ansible-lab-sg` security group and `ansible-lab-key` key pair too.

---

## What you should see

| Step | Result |
|---|---|
| 5 | Tests end with `OK` (9 skipped) |
| 6 | All `ok`, then `Preflight passed.` |
| 7 | A play recap with `failed=0` for web1, web2 and tools1, then two URLs containing your public IP |
| 8 | `All 13 checks passed.` |
| 9 | Blue `web1` page and orange `web2` page, both saying `Managed by Ansible` |
| 10 | Six `PASS` lines, then `All scenarios passed.` |

## Risky dependencies and fallbacks

| Dependency | Risk | Fallback |
|---|---|---|
| Docker Hub images (`ubuntu`, `python`) | Rate limit or a withdrawn tag | `sudo docker login` with a free account, or change the tag in `.env` and re-run `./scripts/preflight.sh` |
| PyPI (installs `ansible-core` while building the control image) | Unreachable or slow | Preflight checks it and retries the build 3 times. Once built, the image is cached. **Run preflight early** |
| Ubuntu package archive (the server image downloads openssh, python, nginx, cron...) | Unreachable or slow | Same: preflight checks it and retries; once built, nothing is downloaded during the demo |
| `download.docker.com` (Docker apt repo) | Unreachable | `setup.sh` falls back to Ubuntu's `docker.io` automatically |
| Do not run `destroy.sh` before the demo | It deletes the built images | Re-run preflight afterwards |
| MinIO, LocalStack | **Not used** | none needed |

## If something goes wrong

| Symptom | Fix |
|---|---|
| SSH: `Connection timed out` | Your IP changed. Edit security group `ansible-lab-sg`, inbound rule SSH port 22, Source My IP. Also confirm the instance is Running and has a public IP. |
| Browser: page never loads at `http://<PUBLIC-IP>:8081/` | (1) Use `http://` not `https://`, and include the port. (2) The inbound rule for 8081-8082 must exist with Source My IP. (3) Check the IP is the instance's current public IP. (4) On the instance: `curl -I http://localhost:8081/healthz` should return `200`. If that works, the problem is the security group. If it does not, run `./scripts/ctl.sh ansible-playbook playbooks/site.yml` (the servers may be unconfigured). |
| Testing the public IP from the instance itself hangs | Expected: the security group only allows your laptop's IP. Use `localhost` on the instance. |
| SSH: `Permission denied (publickey)` | Use user `ubuntu` (not `ec2-user`), the right `.pem`, and `chmod 400` on it. |
| SSH: `UNPROTECTED PRIVATE KEY FILE` | `chmod 400 ansible-lab-key.pem` |
| `./scripts/x.sh: Permission denied` | `chmod +x scripts/*.sh` (step 3). Or run with `bash scripts/x.sh`. |
| `bad interpreter: /usr/bin/env bash^M` | Windows line endings. Run `sed -i 's/\r$//' scripts/*.sh node/entrypoint.sh control/entrypoint.sh` |
| `permission denied` on the Docker socket in your own commands | The scripts use `sudo` for you. For manual commands use `sudo docker ...`, or log out and back in once. |
| Preflight: `PyPI reachable` or `Ubuntu package archive reachable` fails | Check the outbound rule is All traffic; try again in a minute. |
| Preflight: `Build the server and control images` fails | `sudo docker compose build web1 control --progress=plain` shows the failing step (usually a network blip; run preflight again). |
| Preflight: `Port 8081` (or 8082) `is free` fails | `sudo ss -ltnp \| grep -E ':808[12] '`, stop what uses it, or `./scripts/destroy.sh` if it is an old run of this project. |
| `up.sh`: `Ansible could not reach the servers` | `sudo docker compose ps` (three servers running?); `sudo docker logs ansible-lab-web1`; then `./scripts/ctl.sh ansible all -m ping -vvv` shows the SSH error. |
| `ansible ... UNREACHABLE ... Permission denied (publickey)` | The servers have an old key. `./scripts/destroy.sh`, then `./scripts/up.sh` (a new key pair and new servers). |
| `ERROR! Attempting to decrypt but no vault secrets found` or `Decryption failed` | `.vault_pass` does not match `vault.yml`. Delete both (`rm .vault_pass ansible/inventory/group_vars/all/vault.yml`) and run `./scripts/up.sh`. |
| A task fails on `service nginx start` | `sudo docker exec ansible-lab-web1 nginx -t` shows config errors; `sudo docker exec ansible-lab-web1 tail /var/log/nginx/error.log` |
| `demo.sh`: `could not recreate the servers` | `sudo docker compose up -d --force-recreate web1 web2 tools1` shows the error. |
| `demo.sh`: a `rolling` health check keeps retrying | The page did not come up: `curl -i http://localhost:8081/healthz`, then `sudo docker exec ansible-lab-web1 service nginx status`. |
| Disk full | `sudo docker system prune -af` (this removes the built images; preflight builds them again) |
