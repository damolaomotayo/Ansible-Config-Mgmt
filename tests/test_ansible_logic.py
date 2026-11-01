"""Runs the REAL playbooks and roles with a real ansible-core, but WITHOUT Docker, SSH, apt or root:
every "server" is localhost writing under a scratch folder (the `fs_root` variable), and the tasks that
install packages, create users and start services are switched off (`manage_system=false`).

Checks: templates render, file permissions, a second run changes nothing (idempotence), --check/--diff shows
drift and a real run repairs it, variable changes propagate, handlers fire only when nginx's own config changes,
the rolling playbook, and Ansible Vault (encrypted on disk, readable only with the password, secret never on a page).

Skipped if ansible-playbook is not found. Set ANSIBLE_BIN_DIR to the folder holding it.
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BIN_DIR = os.environ.get("ANSIBLE_BIN_DIR")


def find(tool):
    if BIN_DIR and os.path.exists(os.path.join(BIN_DIR, tool)):
        return os.path.join(BIN_DIR, tool)
    return shutil.which(tool)


PLAYBOOK, VAULT, INVENTORY = find("ansible-playbook"), find("ansible-vault"), find("ansible-inventory")
TOKEN = "tok-9f3a7c1e5b2d4a60"

LOCAL_INVENTORY = """
all:
  children:
    web:
      hosts:
        web1: {{fs_root: "{base}/web1"}}
        web2: {{fs_root: "{base}/web2"}}
    tools:
      hosts:
        tools1: {{fs_root: "{base}/tools1"}}
  vars:
    ansible_connection: local
    ansible_python_interpreter: "{python}"
"""


@unittest.skipUnless(PLAYBOOK and VAULT and INVENTORY, "ansible-core not found (set ANSIBLE_BIN_DIR)")
class AnsibleLogicTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="ansible-logic-")
        cls.base = os.path.join(cls.tmp, "fs")
        cls.dir = os.path.join(cls.tmp, "ansible")
        shutil.copytree(os.path.join(ROOT, "ansible"), cls.dir, ignore=shutil.ignore_patterns("vault.yml"))
        cls.passfile = os.path.join(cls.tmp, "vault_pass")
        with open(cls.passfile, "w") as fh:
            fh.write("correct-horse-battery\n")
        os.chmod(cls.passfile, 0o600)
        with open(os.path.join(cls.dir, "inventory", "hosts.yml"), "w") as fh:
            fh.write(LOCAL_INVENTORY.format(base=cls.base, python=shutil.which("python3") or "/usr/bin/python3"))
        cls.vault_file = os.path.join(cls.dir, "inventory", "group_vars", "all", "vault.yml")
        with open(cls.vault_file, "w") as fh:
            fh.write(f'---\nvault_site_api_token: "{TOKEN}"\n')
        res = cls.run_cmd(VAULT, "encrypt", cls.vault_file)
        assert res.returncode == 0, res.stdout + res.stderr
        cfg = os.path.join(cls.dir, "ansible.cfg")
        with open(cfg) as fh:
            text = fh.read()
        with open(cfg, "w") as fh:
            fh.write(text.replace("/run/vault_pass", cls.passfile))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @classmethod
    def run_cmd(cls, binary, *args, extra_env=None):
        env = dict(os.environ, ANSIBLE_CONFIG=os.path.join(cls.dir, "ansible.cfg"), ANSIBLE_NOCOLOR="1",
                   ANSIBLE_FORCE_COLOR="0", ANSIBLE_HOME=os.path.join(cls.tmp, "home"))
        if binary == VAULT:
            args = (*args[:1], "--vault-password-file", cls.passfile, *args[1:])
        env.update(extra_env or {})
        return subprocess.run([binary, *args], cwd=cls.dir, env=env, capture_output=True, text=True, timeout=300)

    def play(self, playbook="site.yml", *args, variables=None):
        extra = {"manage_system": False, "ansible_become": False, **(variables or {})}
        res = self.run_cmd(PLAYBOOK, f"playbooks/{playbook}", "-e", json.dumps(extra), *args)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        return res.stdout

    @staticmethod
    def recap(out, host, field):
        line = [l for l in out.splitlines() if re.match(rf"^{host}\s+: ", l)][-1]
        return int(re.search(rf"\b{field}=(\d+)", line).group(1))

    def path(self, host, rel):
        return os.path.join(self.base, host, rel)

    def read(self, host, rel):
        with open(self.path(host, rel)) as fh:
            return fh.read()

    def reset(self):
        shutil.rmtree(self.base, ignore_errors=True)

    # ---------------------------------------------------------------- tests
    def test_01_syntax_of_every_playbook(self):
        for name in ("site", "rolling", "verify"):
            res = self.run_cmd(PLAYBOOK, f"playbooks/{name}.yml", "--syntax-check")
            self.assertEqual(res.returncode, 0, name + res.stdout + res.stderr)

    def test_02_inventory_groups(self):
        res = self.run_cmd(INVENTORY, "--list")
        data = json.loads(res.stdout)
        self.assertEqual(sorted(data["web"]["hosts"]), ["web1", "web2"])
        self.assertEqual(data["tools"]["hosts"], ["tools1"])
        self.assertEqual(data["_meta"]["hostvars"]["web1"]["site_color"], "#2563eb")
        self.assertEqual(data["_meta"]["hostvars"]["web2"]["site_color"], "#d97706")

    def test_03_first_run_builds_everything_then_second_run_changes_nothing(self):
        self.reset()
        out = self.play()
        for host in ("web1", "web2", "tools1"):
            self.assertGreater(self.recap(out, host, "changed"), 0, host)
            self.assertEqual(self.recap(out, host, "failed"), 0, host)
        page = self.read("web1", "var/www/site/index.html")
        for text in ("Managed by Ansible", "<h1>web1</h1>", "Release 1", "#2563eb", "web"):
            self.assertIn(text, page)
        self.assertIn("#d97706", self.read("web2", "var/www/site/index.html"))
        self.assertIn("location = /healthz", self.read("web1", "etc/nginx/sites-available/site.conf"))
        self.assertTrue(os.path.islink(self.path("web1", "etc/nginx/sites-enabled/site.conf")))
        self.assertIn("report from tools1", self.read("tools1", "usr/local/bin/disk-report.sh"))
        self.assertTrue(os.access(self.path("tools1", "usr/local/bin/disk-report.sh"), os.X_OK))
        self.assertIn("groups:      tools", self.read("tools1", "etc/ansible-managed.txt"))
        out2 = self.play()
        for host in ("web1", "web2", "tools1"):
            self.assertEqual(self.recap(out2, host, "changed"), 0, f"{host} is not idempotent:\n{out2}")

    def test_04_secret_file_is_private_and_secret_is_not_on_the_page(self):
        self.play()
        secret = self.path("web1", "etc/site/secret.env")
        self.assertEqual(oct(os.stat(secret).st_mode & 0o777), "0o600")
        self.assertEqual(self.read("web1", "etc/site/secret.env").strip(), f"API_TOKEN={TOKEN}")
        self.assertNotIn(TOKEN, self.read("web1", "var/www/site/index.html"))
        self.assertNotIn(TOKEN, self.read("web1", "etc/nginx/sites-available/site.conf"))

    def test_05_drift_is_shown_by_check_mode_and_repaired_by_a_real_run(self):
        self.play()
        page = self.path("web1", "var/www/site/index.html")
        with open(page, "w") as fh:
            fh.write("defaced by hand\n")
        out = self.play("site.yml", "--check", "--diff")
        self.assertEqual(self.recap(out, "web1", "changed"), 1)
        self.assertEqual(self.recap(out, "web2", "changed"), 0)
        self.assertIn("defaced by hand", out)                       # the diff shows what would be replaced
        self.assertEqual(self.read("web1", "var/www/site/index.html"), "defaced by hand\n")   # check mode touched nothing
        out = self.play()
        self.assertEqual(self.recap(out, "web1", "changed"), 1)
        self.assertIn("Managed by Ansible", self.read("web1", "var/www/site/index.html"))

    def test_06_variable_changes_propagate_and_handler_fires_only_for_nginx_config(self):
        self.play()
        out = self.play(variables={"site_message": "Hello from the demo"})
        self.assertIn("Hello from the demo", self.read("web1", "var/www/site/index.html"))
        self.assertIn("Hello from the demo", self.read("web2", "var/www/site/index.html"))
        self.assertEqual(self.recap(out, "tools1", "changed"), 0)
        self.assertNotIn("RUNNING HANDLER [nginx_site : reload nginx]", out)   # only the page changed
        out = self.play(variables={"site_message": "Hello from the demo", "site_cache_seconds": 60})
        self.assertIn("RUNNING HANDLER [nginx_site : reload nginx]", out)      # nginx's own config changed
        self.assertIn("max-age=60", self.read("web1", "etc/nginx/sites-available/site.conf"))
        out = self.play(variables={"site_message": "Hello from the demo", "site_cache_seconds": 60})
        self.assertEqual(sum(self.recap(out, h, "changed") for h in ("web1", "web2", "tools1")), 0)
        self.play()
        self.assertIn("Configured by Ansible", self.read("web1", "var/www/site/index.html"))

    def test_07_rolling_update_touches_web_servers_one_at_a_time(self):
        self.play()
        out = self.play("rolling.yml", "--skip-tags", "health", variables={"site_version": "2"})
        self.assertIn("Release 2", self.read("web1", "var/www/site/index.html"))
        self.assertIn("Release 2", self.read("web2", "var/www/site/index.html"))
        self.assertEqual(self.recap(out, "web1", "failed") + self.recap(out, "web2", "failed"), 0)
        self.assertGreaterEqual(out.count("PLAY [Rolling update of the web servers]"), 1)
        # with serial: 1 every task is announced once per server, so the first task appears twice
        self.assertEqual(out.count("TASK [nginx_site : Create the site folders]"), 2)
        self.play()

    def test_08_vault_file_is_encrypted_and_needs_the_password(self):
        with open(self.vault_file) as fh:
            self.assertTrue(fh.read().startswith("$ANSIBLE_VAULT;1.1;AES256"))
        ok = self.run_cmd(VAULT, "view", self.vault_file)
        self.assertIn(TOKEN, ok.stdout)
        wrong = os.path.join(self.tmp, "wrong")
        with open(wrong, "w") as fh:
            fh.write("not-the-password\n")
        res = subprocess.run([VAULT, "view", "--vault-password-file", wrong, self.vault_file],
                             capture_output=True, text=True, env=dict(os.environ, ANSIBLE_HOME=self.tmp))
        self.assertNotEqual(res.returncode, 0)
        self.assertNotIn(TOKEN, res.stdout)

    def test_09_token_appears_in_no_plain_text_repo_file(self):
        for folder, _, files in os.walk(self.dir):
            for name in files:
                full = os.path.join(folder, name)
                if full == self.vault_file:
                    continue
                with open(full, "rb") as fh:
                    self.assertNotIn(TOKEN.encode(), fh.read(), full)


if __name__ == "__main__":
    unittest.main()
