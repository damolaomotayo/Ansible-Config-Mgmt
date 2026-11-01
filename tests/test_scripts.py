"""Tests the shell helpers in scripts/lib.sh with a stub `docker` command (no Docker needed):
the docker compose command lines, the PLAY RECAP parsers, .env generation, vault-file safety.
"""
import os
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

STUB_DOCKER = r"""#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1" in
  info) exit 0 ;;
  compose)
    if [ "$2" = "run" ]; then
      [ -n "${STUB_RUN_FAILS:-}" ] && exit 1
      [ -n "${STUB_RUN_OUT:-}" ] && printf '%b' "$STUB_RUN_OUT"
    fi
    exit 0 ;;
esac
exit 0
"""

RECAP = """PLAY RECAP *********************************************************************
tools1                     : ok=9    changed=0    unreachable=0    failed=0    skipped=3    rescued=0    ignored=0
web1                       : ok=14   changed=3    unreachable=0    failed=0    skipped=7    rescued=0    ignored=0
web2                       : ok=14   changed=2    unreachable=0    failed=1    skipped=7    rescued=0    ignored=0
"""


class ScriptHelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ansible-scripts-")
        shutil.copytree(os.path.join(ROOT, "scripts"), os.path.join(self.tmp, "scripts"))
        shutil.copy(os.path.join(ROOT, ".env.example"), self.tmp)
        os.makedirs(os.path.join(self.tmp, "ansible", "inventory", "group_vars", "all"))
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        path = os.path.join(self.bin, "docker")
        with open(path, "w") as fh:
            fh.write(STUB_DOCKER)
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        self.log = os.path.join(self.tmp, "docker.log")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def sh(self, snippet, **extra_env):
        env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"], STUB_LOG=self.log, **extra_env)
        return subprocess.run(["bash", "-c", f'. "{self.tmp}/scripts/lib.sh"; {snippet}'], env=env,
                              capture_output=True, text=True, timeout=60)

    def logged(self):
        with open(self.log) as fh:
            return fh.read()

    def test_env_file_gets_your_user_and_group_id(self):
        self.sh("true")
        with open(os.path.join(self.tmp, ".env")) as fh:
            text = fh.read()
        self.assertIn(f"HOST_UID={os.getuid()}", text)
        self.assertIn(f"HOST_GID={os.getgid()}", text)
        self.assertIn("UBUNTU_IMAGE=ubuntu:24.04", text)

    def test_ctl_and_play_command_lines(self):
        self.sh("ctl ansible all -m ping; play playbooks/site.yml --check")
        lines = self.logged().splitlines()
        self.assertIn("compose run --rm -T control ansible all -m ping", lines)
        self.assertIn("compose run --rm -T control ansible-playbook playbooks/site.yml --check", lines)

    def test_recap_parsers(self):
        res = self.sh(f"out='{RECAP}'; recap_field web1 changed \"$out\"; recap_field web2 failed \"$out\"; "
                      f"recap_field tools1 ok \"$out\"; total_changed \"$out\"; total_failed \"$out\"")
        self.assertEqual(res.stdout.split(), ["3", "1", "9", "5", "1"])

    def test_wait_ssh_needs_three_pongs(self):
        pong = '{"ping": "pong"}'
        good = self.sh("sleep() { :; }; wait_ssh 2; echo rc=$?", STUB_RUN_OUT=f"web1 | SUCCESS => {pong}\\nweb2 | SUCCESS => {pong}\\ntools1 | SUCCESS => {pong}\\n")
        self.assertIn("rc=0", good.stdout)
        bad = self.sh("sleep() { :; }; wait_ssh 2; echo rc=$?", STUB_RUN_OUT=f"web1 | SUCCESS => {pong}\\n")
        self.assertIn("rc=1", bad.stdout)

    def test_failed_encryption_never_leaves_the_plaintext_token(self):
        res = self.sh("ensure_vault_file; echo rc=$?; ls ansible/inventory/group_vars/all", STUB_RUN_FAILS="1")
        self.assertIn("rc=1", res.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "ansible/inventory/group_vars/all/vault.yml")))

    def test_existing_vault_file_is_not_overwritten(self):
        path = os.path.join(self.tmp, "ansible/inventory/group_vars/all/vault.yml")
        with open(path, "w") as fh:
            fh.write("$ANSIBLE_VAULT;1.1;AES256\nkeep-me\n")
        self.sh("ensure_vault_file")
        with open(path) as fh:
            self.assertIn("keep-me", fh.read())

    def test_keys_and_vault_password_are_created_private(self):
        if not shutil.which("ssh-keygen") or not shutil.which("openssl"):
            self.skipTest("ssh-keygen/openssl not installed")
        self.sh("ensure_secrets")
        key = os.path.join(self.tmp, ".ssh", "id_ed25519")
        self.assertTrue(os.path.isfile(key) and os.path.isfile(key + ".pub"))
        self.assertEqual(oct(os.stat(key).st_mode & 0o777), "0o600")
        vp = os.path.join(self.tmp, ".vault_pass")
        self.assertEqual(oct(os.stat(vp).st_mode & 0o777), "0o600")
        with open(vp) as fh:
            first = fh.read()
        self.sh("ensure_secrets")                                  # a second call must not change the password
        with open(vp) as fh:
            self.assertEqual(first, fh.read())
        self.assertGreaterEqual(len(first.strip()), 32)


if __name__ == "__main__":
    unittest.main()
