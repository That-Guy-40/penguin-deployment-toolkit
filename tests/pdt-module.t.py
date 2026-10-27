#!/usr/bin/env python3
"""bin/_pdt.py: the beacon and access-log parsers, id resolution, the age column."""
import contextlib
import io
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import pylib as t

T = t.sandbox()
try:
    sys.path.insert(0, os.path.join(T, "bin"))
    import _pdt

    # paths() come from the sandbox's lib.sh + config.sh, not this repo's
    p = _pdt.paths()
    t.chk("paths(): STATE_DIR is the sandbox's run/", os.path.join(T, "run"), p["STATE_DIR"])
    t.chk("paths(): BASE_URL from the sandbox config", "http://10.0.2.2:8099", p["BASE_URL"])

    # parse_beacon
    e = _pdt.parse_beacon("2026-10-27T18:00:00-04:00 1761602400.123 10.0.2.15 id=ABCD-1&run=77&step=20-disk&ev=ok&msg=one+disk&rc=0\n")
    t.chk_true("a valid beacon line parses", e is not None)
    t.chk("the id is lower-cased", "abcd-1", e["id"])
    t.chk("step, ev, run, msg decoded (+ is a space)", ("20-disk", "ok", "77", "one disk"), (e["step"], e["ev"], e["run"], e["msg"]))
    t.chk("t is the millisecond column as a float", 1761602400.123, e["t"])
    t.chk("iso and addr kept", ("2026-10-27T18:00:00-04:00", "10.0.2.15"), (e["iso"], e["addr"]))
    t.chk("a beacon without run gets run=''", "", _pdt.parse_beacon("i 1.0 a id=x&step=s&ev=ok")["run"])
    for bad, why in [("2026 1.0 10.0.2.15 step=s&ev=ok", "no id"), ("2026 1.0 10.0.2.15 id=x&ev=ok", "no step"),
                     ("2026 1.0 10.0.2.15 id=x&step=s", "no ev"), ("2026 notanumber 10.0.2.15 id=x&step=s&ev=ok", "msec not a number"),
                     ("only three columns here", "too few columns"), ("", "empty line")]:
        if _pdt.parse_beacon(bad) is None:
            t.control(f"parse_beacon rejects a line with {why}")
        else:
            t.fail(f"parse_beacon rejects a line with {why}", "parsed")

    # read_access_events: the two synthetic events, and nothing else
    acc = os.path.join(T, "run", "access.log")
    with open(acc, "w") as f:
        f.write('10.0.2.15 2026-10-27T18:00:01-04:00 1761602401.000 "GET /boot.ipxe?uuid=AAAA-1&product=lab-vm&mfr=PDT&mac=52:54:00:aa:bb:cc&nic=8086:10d3&chip=SNP HTTP/1.1" 200 1234 0.001\n')
        f.write('10.0.2.15 2026-10-27T18:00:02-04:00 1761602402.000 "GET /winpe/boot.wim?id=AAAA-1 HTTP/1.1" 200 524288000 2.000\n')
        f.write('10.0.2.15 2026-10-27T18:00:03-04:00 1761602403.000 "GET /boot.ipxe?uuid=AAAA-1 HTTP/1.1" 404 0 0.001\n')
        f.write('10.0.2.15 2026-10-27T18:00:04-04:00 1761602404.000 "GET /ts/deploy.seq HTTP/1.1" 200 10 0.001\n')
        f.write('10.0.2.15 2026-10-27T18:00:05-04:00 1761602405.000 "GET /boot.ipxe HTTP/1.1" 200 10 0.001\n')
        f.write("garbage line that is not an access log line\n")
    ev = _pdt.read_access_events(acc)
    t.chk("three synthetic events from six lines (ipxe ok, wim, ipxe 404); other requests and garbage ignored", 3, len(ev))
    ipxe = ev[0]
    t.chk("boot.ipxe fetch -> step ipxe ev ok with the identity fields", ("ipxe", "ok", "aaaa-1", "lab-vm", "52:54:00:aa:bb:cc", "8086:10d3", "SNP"),
          (ipxe["step"], ipxe["ev"], ipxe["id"], ipxe["product"], ipxe["mac"], ipxe["nic"], ipxe["chip"]))
    wim = ev[1]
    t.chk("boot.wim served -> step wim with the size and rate", ("wim", "ok", "500 MiB in 2.0s (250 MiB/s)"), (wim["step"], wim["ev"], wim["msg"]))
    t.chk("a 404 on boot.ipxe is ev=fail", "fail", ev[2]["ev"])
    t.chk("read_access_events on a missing file is empty", [], _pdt.read_access_events(os.path.join(T, "nope")))

    # read_beacons + all_events order
    bl = os.path.join(T, "run", "beacons.log")
    with open(bl, "w") as f:
        f.write("2026 1761602400.000 10.0.2.15 id=AAAA-1&run=1&step=ts-start&ev=ok\n")
        f.write("broken\n")
        f.write("2026 1761602410.000 10.0.2.15 id=AAAA-1&run=1&step=ts-done&ev=ok\n")
    _pdt._paths = None   # make sure paths() is re-read from the sandbox (it is cached)
    allev = _pdt.all_events()
    t.chk("all_events merges beacons and access events sorted by time", ["ts-start", "ipxe", "wim", "ipxe", "ts-done"], [e["step"] for e in allev])

    # resolve_id and vm_names
    os.makedirs(os.path.join(T, "vms", "lab1"))
    with open(os.path.join(T, "vms", "lab1", "vm.conf"), "w") as f:
        f.write("VM_NAME=lab1\nVM_UUID=AAAA-1\n")
    t.chk("resolve_id by VM name (lower-cased)", "aaaa-1", _pdt.resolve_id("lab1"))
    t.chk("vm_names maps uuid -> name", {"aaaa-1": "lab1"}, _pdt.vm_names())
    u = "12345678-1234-1234-1234-123456789abc"
    t.chk("resolve_id by full UUID, no events needed", u, _pdt.resolve_id(u.upper(), events=[]))
    evs = [dict(id="aaaa-1"), dict(id="aaab-2")]
    t.chk("resolve_id by unique prefix", "aaab-2", _pdt.resolve_id("aaab", evs))
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        try:
            _pdt.resolve_id("aaa", evs)
            t.fail("an ambiguous prefix is refused", "returned")
        except SystemExit as e:
            t.control(f"an ambiguous prefix (2 matches) is refused with exit {e.code}")
        try:
            _pdt.resolve_id("zzz", evs)
            t.fail("an unknown id is refused", "returned")
        except SystemExit:
            t.control("an unknown id is refused")
    t.chk_true("both refusals say why on stderr", "matches 2" in err.getvalue() and "'zzz' is not a VM name" in err.getvalue(), err.getvalue())

    # age
    t.chk("age boundaries: 89s, 1m, 89m, 1h, 47h, 2d, and negatives clamp to 0s",
          ["89s", "1m", "89m", "1h", "47h", "2d", "0s"], [_pdt.age(s) for s in (89, 90, 5399, 5400, 172799, 172800, -5)])
finally:
    shutil.rmtree(T, ignore_errors=True)
t.finish()
