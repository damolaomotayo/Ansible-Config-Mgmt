"""Sanity tests for the repo itself (layout, scripts, config, docs). Stdlib only. Run from the repo root:
    python3 -m unittest discover -s tests -v
"""
import os
import re
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

REQUIRED_FILES = [
    "README.md", "STEPS.md", "DEMO.md", "DIAGRAM_PROMPT.md", ".gitignore", ".gitattributes", ".env.example",
    "docker-compose.yml", "node/Dockerfile", "node/entrypoint.sh", "control/Dockerfile", "control/entrypoint.sh",
    "ansible/ansible.cfg", "ansible/inventory/hosts.yml", "ansible/inventory/group_vars/all/main.yml",
    "ansible/inventory/group_vars/all/vault.yml.example", "ansible/inventory/group_vars/web.yml",
    "ansible/inventory/host_vars/web1.yml", "ansible/inventory/host_vars/web2.yml",
    "ansible/playbooks/site.yml", "ansible/playbooks/rolling.yml", "ansible/playbooks/verify.yml",
    "ansible/roles/common/tasks/main.yml", "ansible/roles/nginx_site/tasks/main.yml",
    "ansible/roles/nginx_site/handlers/main.yml", "ansible/roles/nginx_site/templates/site.conf.j2",
    "ansible/roles/nginx_site/templates/index.html.j2", "ansible/roles/toolbox/tasks/main.yml",
    "scripts/lib.sh", "scripts/ctl.sh", "scripts/setup.sh", "scripts/preflight.sh", "scripts/up.sh",
    "scripts/smoke.sh", "scripts/demo.sh", "scripts/destroy.sh",
    "tests/test_ansible_logic.py", "tests/test_scripts.py",
]
SCRIPTS = [f for f in REQUIRED_FILES if f.endswith(".sh")]


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        return fh.read()


class LayoutTests(unittest.TestCase):
    def test_required_files_exist(self):
        for rel in REQUIRED_FILES:
            self.assertTrue(os.path.isfile(os.path.join(ROOT, rel)), f"missing {rel}")

    def test_scripts_have_shebang(self):
        for rel in SCRIPTS + ["node/entrypoint.sh", "control/entrypoint.sh"]:
            self.assertTrue(read(rel).startswith("#!/"), rel)

    def test_no_crlf_line_endings(self):
        for rel in REQUIRED_FILES:
            if rel.endswith((".sh", ".yml", ".j2", "Dockerfile", ".cfg")):
                with open(os.path.join(ROOT, rel), "rb") as fh:
                    self.assertNotIn(b"\r\n", fh.read(), rel)

    def test_gitignore_keeps_secrets_out_of_git(self):
        text = read(".gitignore")
        for entry in (".env", ".ssh/", ".vault_pass", "ansible/inventory/group_vars/all/vault.yml"):
            self.assertIn(entry, text)

    def test_no_stale_roles_from_other_drafts(self):
        roles = sorted(os.listdir(os.path.join(ROOT, "ansible", "roles")))
        self.assertEqual(roles, ["common", "nginx_site", "toolbox"])


class SecurityAndConfigTests(unittest.TestCase):
    def test_only_the_two_web_servers_publish_ports(self):
        ports = re.findall(r'-\s*"([^"]+)"', read("docker-compose.yml"))
        published = [p for p in ports if re.match(r"^(\d+\.\d+\.\d+\.\d+:)?\d+:\d+$", p)]
        self.assertEqual(sorted(published), ["8081:80", "8082:80"])

    def test_ssh_is_never_published(self):
        self.assertNotRegex(read("docker-compose.yml"), r'"\d+:22"')

    def test_servers_allow_key_login_only(self):
        dockerfile = read("node/Dockerfile")
        self.assertIn("PasswordAuthentication no", dockerfile)
        self.assertIn("PermitRootLogin no", dockerfile)

    def test_vault_password_file_is_configured_and_no_secret_is_committed(self):
        self.assertIn("vault_password_file  = /run/vault_pass", read("ansible/ansible.cfg"))
        example = read("ansible/inventory/group_vars/all/vault.yml.example")
        self.assertIn("replaced-with-a-random-value", example)
        self.assertFalse(os.path.exists(os.path.join(ROOT, "ansible/inventory/group_vars/all/vault.yml")),
                         "a real vault file must never be in the shipped repo")
        self.assertFalse(os.path.exists(os.path.join(ROOT, ".vault_pass")))
        self.assertFalse(os.path.exists(os.path.join(ROOT, ".ssh")))

    def test_secret_template_is_root_only_and_hidden_from_logs(self):
        tasks = read("ansible/roles/nginx_site/tasks/main.yml")
        block = tasks[tasks.index("Write the secret"):]
        block = block[:block.index("- name:", 10)]
        self.assertIn('mode: "0600"', block)
        self.assertIn("no_log: true", block)

    def test_images_are_official_and_pinned(self):
        env = dict(re.findall(r"^(\w+)=(.*)$", read(".env.example"), re.M))
        self.assertRegex(env["UBUNTU_IMAGE"], r"^ubuntu:\d+\.\d+$")
        self.assertRegex(env["PYTHON_IMAGE"], r"^python:\d+\.\d+-slim$")
        self.assertIn("ansible-core==2.18.1", read("control/Dockerfile"))

    def test_playbooks_use_fully_qualified_module_names_and_no_shell_module(self):
        for rel in [f for f in REQUIRED_FILES if f.startswith("ansible/") and f.endswith(".yml")]:
            text = read(rel)
            self.assertNotRegex(text, r"^\s+(shell|command):", rel)          # must be ansible.builtin.*
            self.assertNotIn("ansible.builtin.shell", text, rel)


class ScriptRuleTests(unittest.TestCase):
    def test_no_curl_f_against_docker_hub(self):
        for rel in SCRIPTS:
            for line in read(rel).splitlines():
                if "registry-1.docker.io" in line and "curl" in line:
                    self.assertNotRegex(line, r"curl\s+-\w*f", f"{rel}: {line}")

    def test_preflight_accepts_http_200_and_401_for_docker_hub(self):
        text = read("scripts/preflight.sh")
        self.assertIn('"$code" = "200"', text)
        self.assertIn('"$code" = "401"', text)

    def test_no_pipe_into_grep_q(self):                     # under pipefail this randomly fails
        for rel in SCRIPTS:
            for n, line in enumerate(read(rel).splitlines(), 1):
                if line.strip().startswith("#"):
                    continue
                self.assertNotRegex(line, r"\|\s*grep\s+-\w*q", f"{rel}:{n}: {line}")

    def test_extra_vars_with_spaces_are_json(self):
        for n, line in enumerate(read("scripts/demo.sh").splitlines(), 1):
            self.assertNotRegex(line, r'-e\s+"?site_message=', f"demo.sh:{n} would be split at the space")

    def test_demo_has_all_scenarios_and_smoke_has_a_count(self):
        demo = read("scripts/demo.sh")
        for name in ("converge", "drift", "change", "rolling", "vault", "adhoc"):
            self.assertIn(f"scenario_{name}()", demo)
        smoke = read("scripts/smoke.sh")
        self.assertEqual(len(re.findall(r"^check ", smoke, re.M)), 13)
        self.assertIn("All %d checks passed.", smoke)

    def test_demo_does_not_hide_a_failed_check_behind_set_e(self):
        self.assertNotIn("set -e", read("scripts/demo.sh").replace("set -euo", "XX"))


class DocsTests(unittest.TestCase):
    def test_steps_has_prerequisites_first_and_the_key_items(self):
        text = read("STEPS.md")
        self.assertLess(text.index("## Prerequisites"), text.index("## Step 0"))
        for needle in ("8081-8082", "chmod +x scripts/*.sh", "chmod 400", "All 13 checks passed.",
                       "sudo apt update", "Terminate", "My IP", "changed=0"):
            self.assertIn(needle, text)

    def test_demo_md_is_very_short(self):
        text = read("DEMO.md")
        self.assertLess(len(text.split()), 450)
        self.assertLess(len(text.splitlines()), 40)

    def test_diagram_prompt_mentions_the_main_parts(self):
        text = read("DIAGRAM_PROMPT.md")
        for needle in ("Ansible", "control", "inventory", "playbook", "8081", "SSH", "Vault"):
            self.assertIn(needle, text)

    def test_every_script_is_documented_in_steps(self):
        steps = read("STEPS.md")
        for rel in ("setup.sh", "preflight.sh", "up.sh", "smoke.sh", "demo.sh", "destroy.sh", "ctl.sh"):
            self.assertIn(rel, steps)


if __name__ == "__main__":
    unittest.main()
