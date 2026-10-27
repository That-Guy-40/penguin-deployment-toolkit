"""tests/pylib.py - the row conventions of tests/lib.sh for the Python tests, plus a
sandbox repo (bin/ copied, its own config.sh) so that bin/_pdt.py reads the sandbox's
logs and VMs, never this repo's."""
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
_nfail = 0


def pass_(what):
    print(f"PASS     {what}")


def fail(what, detail=""):
    global _nfail
    _nfail += 1
    print(f"FAIL     {what}: {detail}")


def control(what):
    print(f"CONTROL  {what}")


def unknown(what, why):
    print(f"UNKNOWN  {what}: {why}")


def chk(what, want, got):
    if want == got:
        pass_(what)
    else:
        fail(what, f"want {want!r} got {got!r}")


def chk_true(what, cond, detail=""):
    pass_(what) if cond else fail(what, detail)


def sandbox():
    """A throwaway repo with bin/ copied in and a config.sh; returns its path."""
    for k in ("PDT_ROOT", "STATE_DIR", "HTTP_DIR", "BEACON_LOG", "ACCESS_LOG"):
        os.environ.pop(k, None)   # bin/lib.sh's exports, if inherited, would point at the real repo
    t = tempfile.mkdtemp(prefix="pdt-tests.")
    shutil.copytree(os.path.join(REPO, "bin"), os.path.join(t, "bin"), ignore=shutil.ignore_patterns("__pycache__"))
    for d in ("vms", "run", "http/machines"):
        os.makedirs(os.path.join(t, d))
    with open(os.path.join(t, "config.sh"), "w") as f:
        f.write('HTTP_HOST="10.0.2.2"\nHTTP_PORT="8099"\n')
    return t


def finish():
    sys.exit(1 if _nfail else 0)
