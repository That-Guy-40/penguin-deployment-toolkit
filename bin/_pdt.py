"""_pdt.py - shared by the Python tools in bin/ (status, await, logs, lint).

Reads the two logs bin/serve writes. They are the only "database":
  run/beacons.log  one line per event sent by a target:  <iso8601> <msec> <addr> <query-string>
  run/access.log   every other request; two synthetic events are derived from it:
                   ipxe (boot.ipxe fetched, with identity) and wim (boot.wim served)
"""
import os
import re
import subprocess
import sys
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
ACCESS_RE = re.compile(r'^(\S+) (\S+) ([\d.]+) "(\S+) (\S+) [^"]*" (\d+) (\d+) ([\d.]+)$')

_paths = None


def paths():
    """STATE_DIR, HTTP_DIR, BASE_URL... as bin/lib.sh computes them from config.sh."""
    global _paths
    if _paths is None:
        keys = ["STATE_DIR", "HTTP_DIR", "PXE_DIR", "VMS_DIR", "BEACON_LOG", "ACCESS_LOG", "BASE_URL", "HTTP_PORT", "HTTP_BIND"]
        script = 'source "$1/bin/lib.sh"; for k in %s; do printf "%%s\\n" "${!k}"; done' % " ".join(keys)
        r = subprocess.run(["bash", "-c", script, "_", ROOT], capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(r.stderr.strip() or "cannot load config.sh")
        _paths = dict(zip(keys, r.stdout.split("\n")))
    return _paths


def die(msg, code=2):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def parse_beacon(line):
    """One beacons.log line -> event dict, or None if it is not a valid event."""
    parts = line.rstrip("\n").split(" ", 3)
    if len(parts) != 4:
        return None
    iso, msec, addr, args = parts
    try:
        t = float(msec)
    except ValueError:
        return None
    ev = {k: v[-1] for k, v in urllib.parse.parse_qs(args, keep_blank_values=True).items()}
    if not ev.get("id") or not ev.get("step") or not ev.get("ev"):
        return None
    ev.update(t=t, iso=iso, addr=addr, id=ev["id"].lower(), run=ev.get("run", ""))
    return ev


def read_beacons(path=None):
    path = path or paths()["BEACON_LOG"]
    if not os.path.exists(path):
        return []
    with open(path, errors="replace") as f:
        return [e for e in map(parse_beacon, f) if e]


def read_access_events(path=None):
    """Synthetic events nobody sends: 'ipxe' and 'wim', derived from the access log."""
    path = path or paths()["ACCESS_LOG"]
    out = []
    if not os.path.exists(path):
        return out
    with open(path, errors="replace") as f:
        for line in f:
            m = ACCESS_RE.match(line.rstrip("\n"))
            if not m:
                continue
            addr, iso, msec, _method, uri, status, size, secs = m.groups()
            url = urllib.parse.urlsplit(uri)
            q = {k: v[-1] for k, v in urllib.parse.parse_qs(url.query, keep_blank_values=True).items()}
            base = dict(t=float(msec), iso=iso, addr=addr, run="")
            if url.path == "/boot.ipxe" and q.get("uuid"):
                out.append(dict(base, id=q["uuid"].lower(), step="ipxe", ev="ok" if status == "200" else "fail",
                                product=q.get("product", ""), mfr=q.get("mfr", ""), mac=q.get("mac", ""),
                                serial=q.get("serial", "")))
            elif url.path == "/winpe/boot.wim" and q.get("id"):
                rate = int(size) / float(secs) / 1048576 if float(secs) > 0 else 0
                out.append(dict(base, id=q["id"].lower(), step="wim", ev="ok" if status == "200" else "fail",
                                msg=f"{int(size) / 1048576:.0f} MiB in {float(secs):.1f}s ({rate:.0f} MiB/s)"))
    return out


def all_events():
    return sorted(read_beacons() + read_access_events(), key=lambda e: e["t"])


def resolve_id(arg, events=None):
    """A VM name, a full UUID, or a unique UUID prefix -> lowercase UUID."""
    conf = os.path.join(paths()["VMS_DIR"], arg, "vm.conf")
    if os.path.isfile(conf):
        for line in open(conf):
            if line.startswith("VM_UUID="):
                return line.split("=", 1)[1].strip().lower()
    low = arg.lower()
    if UUID_RE.match(low):
        return low
    known = sorted({e["id"] for e in (events if events is not None else all_events())})
    hits = [i for i in known if i.startswith(low)]
    if len(hits) == 1:
        return hits[0]
    die(f"'{arg}' is not a VM name, a UUID, or a unique prefix of a known id" + (f" (matches {len(hits)})" if hits else ""))


def vm_names():
    """uuid -> lab VM name, for display."""
    out = {}
    vms = paths()["VMS_DIR"]
    if os.path.isdir(vms):
        for name in os.listdir(vms):
            conf = os.path.join(vms, name, "vm.conf")
            if os.path.isfile(conf):
                for line in open(conf):
                    if line.startswith("VM_UUID="):
                        out[line.split("=", 1)[1].strip().lower()] = name
    return out


def age(seconds):
    seconds = int(max(0, seconds))
    if seconds < 90:
        return f"{seconds}s"
    if seconds < 5400:
        return f"{seconds // 60}m"
    if seconds < 172800:
        return f"{seconds // 3600}h"
    return f"{seconds // 86400}d"
