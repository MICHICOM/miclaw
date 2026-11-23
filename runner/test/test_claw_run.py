"""claw-run の入力検証と systemd-run 引数生成のテスト（systemd が無い環境でも実行可能）。

    python3 -I -m unittest discover -s runner/test -v
"""
import importlib.machinery
import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path

HERE = Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("claw_run", str(HERE.parent / "claw-run"))
spec = importlib.util.spec_from_loader("claw_run", loader)
cr = importlib.util.module_from_spec(spec)
loader.exec_module(cr)


class FakeStdin:
    def __init__(self, data: bytes):
        self.buffer = io.BytesIO(data)


class ClawRunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.prompts = root / "prompts"
        self.jobs = root / "jobs"
        self.prompts.mkdir()
        self.jobs.mkdir()
        (self.prompts / "nightly.md").write_text("テストを実行して失敗を直す")
        self.cfg_file = root / "runner.json"
        self.cfg_file.write_text(json.dumps({
            "jobs_root": str(self.jobs),
            "repos_root": str(root / "repos"),
            "prompts_root": str(self.prompts),
            "limits": {"MemoryMax": "2G"},
        }))
        os.chmod(self.cfg_file, 0o644)
        self._orig = (cr.CONFIG_FILE, cr.run_user_home)
        cr.CONFIG_FILE = self.cfg_file
        cr.run_user_home = lambda cfg: Path("/home/clawrun")

    def tearDown(self):
        cr.CONFIG_FILE, cr.run_user_home = self._orig
        self.tmp.cleanup()

    def run_cli(self, args, stdin=b""):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = cr.main(args, stdin=FakeStdin(stdin))
        return code, out.getvalue(), err.getvalue()

    def test_dry_run_builds_confined_unit(self):
        code, out, err = self.run_cli(["--agent", "codex", "--job", "nightly-001", "--prompt-file", "nightly.md", "--dry-run"])
        self.assertEqual(code, 0, err)
        plan = json.loads(out)
        argv = plan["argv"]
        self.assertEqual(argv[0], "systemd-run")
        for expected in [
            "--unit=claw-job-nightly-001", "--wait", "--collect", "--pipe",
            "--property=User=clawrun", "--property=ProtectSystem=strict", "--property=ProtectHome=tmpfs",
            "--property=NoNewPrivileges=yes", "--property=RuntimeMaxSec=1800", "--property=CapabilityBoundingSet=",
            "--property=MemoryMax=2G", "--property=CPUQuota=150%", "--property=TasksMax=256",
            f"--property=ReadWritePaths={self.jobs / 'nightly-001'}",
            "--property=BindPaths=/home/clawrun/.codex",
        ]:
            self.assertIn(expected, argv)
        cmd = argv[argv.index("--") + 1:]
        self.assertEqual(cmd[:2], ["codex", "exec"])
        self.assertIn(f"{self.jobs / 'nightly-001'}/last-message.txt", cmd)
        # プロンプト本文は argv に載らない（ps で見えない）
        self.assertFalse(any("失敗を直す" in a for a in argv))
        self.assertFalse((self.jobs / "nightly-001").exists(), "dry-run must not create the job dir")

    def test_stdin_prompt_and_auto_job_id(self):
        code, out, err = self.run_cli(["--agent", "claude", "--dry-run"], stdin="READMEを直して".encode())
        self.assertEqual(code, 0, err)
        plan = json.loads(out)
        self.assertRegex(plan["job"], r"^claude-\d{8}-\d{6}-[0-9a-f]{6}$")
        self.assertIn("--property=BindPaths=-/home/clawrun/.claude.json", plan["argv"])

    def test_rejects_unknown_or_disabled_agents(self):
        for agent in ["gemini", "bash", "../codex"]:
            code, _, err = self.run_cli(["--agent", agent, "--dry-run"], stdin=b"x")
            self.assertEqual(code, cr.EX_USAGE, agent)
            self.assertIn("not enabled", err)

    def test_rejects_path_traversal_and_bad_ids(self):
        cases = [
            ["--agent", "codex", "--repo", "../etc", "--dry-run"],
            ["--agent", "codex", "--repo", "a/b", "--dry-run"],
            ["--agent", "codex", "--job", "../../tmp/x", "--dry-run"],
            ["--agent", "codex", "--job", "UPPER", "--dry-run"],
            ["--agent", "codex", "--prompt-file", "../runner.json", "--dry-run"],
            ["--agent", "codex", "--prompt-file", "/etc/shadow", "--dry-run"],
            ["--agent", "codex", "--prompt-file", "missing.md", "--dry-run"],
            ["--agent", "codex", "--timeout", "10", "--dry-run"],
            ["--agent", "codex", "--timeout", "99999", "--dry-run"],
        ]
        for args in cases:
            code, _, _ = self.run_cli(args, stdin=b"x")
            self.assertEqual(code, cr.EX_USAGE, args)

    def test_rejects_symlinked_prompt(self):
        os.symlink("/etc/hostname", self.prompts / "evil.md")
        code, _, err = self.run_cli(["--agent", "codex", "--prompt-file", "evil.md", "--dry-run"])
        self.assertEqual(code, cr.EX_USAGE)

    def test_rejects_empty_and_oversized_prompts(self):
        self.assertEqual(self.run_cli(["--agent", "codex", "--dry-run"], stdin=b"  \n")[0], cr.EX_USAGE)
        self.assertEqual(self.run_cli(["--agent", "codex", "--dry-run"], stdin=b"x" * 70000)[0], cr.EX_USAGE)

    def test_job_ids_are_single_use(self):
        (self.jobs / "dup-job").mkdir()
        code, _, err = self.run_cli(["--agent", "codex", "--job", "dup-job", "--dry-run"], stdin=b"x")
        self.assertEqual(code, cr.EX_USAGE)
        self.assertIn("already exists", err)

    def test_refuses_writable_config(self):
        os.chmod(self.cfg_file, 0o666)
        code, _, err = self.run_cli(["--agent", "codex", "--dry-run"], stdin=b"x")
        self.assertEqual(code, cr.EX_USAGE)
        self.assertIn("root-owned", err)


if __name__ == "__main__":
    unittest.main()
