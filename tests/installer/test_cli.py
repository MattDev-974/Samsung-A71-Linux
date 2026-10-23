import os, subprocess, sys, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
class CliTest(unittest.TestCase):
    def call(self, *args, env=None):
        e=os.environ.copy(); e.update(env or {})
        return subprocess.run([str(ROOT/"install.sh"),*args],cwd=ROOT,env=e,text=True,capture_output=True)
    def test_help_version(self):
        self.assertEqual(self.call("--help").returncode,0)
        self.assertEqual(self.call("--version").returncode,0)
    def test_unknown_and_missing(self):
        self.assertEqual(self.call("--option-inconnue").returncode,2)
        self.assertEqual(self.call("--profile").returncode,2)
        self.assertEqual(self.call("--describe-profile").returncode,2)
    def test_profiles(self):
        r=self.call("--list-profiles"); self.assertEqual(r.returncode,0)
        self.assertIn("server",r.stdout); self.assertNotIn("wifi",r.stdout.lower()); self.assertNotIn("audio",r.stdout.lower())
        self.assertEqual(self.call("--describe-profile","server").returncode,0)
    def test_dryrun_no_write(self):
        with tempfile.TemporaryDirectory() as td:
            e={"A71_LOG_DIR":td,"A71_NO_WRITE":"1"}
            r=self.call("--dry-run","--profile","server",env=e)
            self.assertEqual(r.returncode,0); self.assertEqual(list(Path(td).iterdir()),[])
    def test_check(self):
        with tempfile.TemporaryDirectory() as td:
            r=self.call("--check",env={"A71_LOG_DIR":td})
            self.assertEqual(r.returncode,0)
            self.assertEqual(len(list(Path(td).glob("*.log"))),1)
if __name__=="__main__": unittest.main(verbosity=2)
