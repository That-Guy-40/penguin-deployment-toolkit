#!/bin/bash
# tests/lib.sh - sourced by every tests/*.t.sh: a sandbox copy of bin/ with its own
# config.sh, fake firmware and ROM files, and fake qemu-system-x86_64 / qemu-img /
# socat on PATH (tests/fakes/), so that the bin/ scripts run for real against a
# repo that is not this one and a QEMU that only records what it was asked.
#
# Rows (one per line on stdout, bin/tests sums them):
#   PASS     <what>                 the property holds
#   FAIL     <what>: <detail>       it does not
#   CONTROL  <what>                 a check that must REFUSE or FAIL did so (the assertion bites)
#   UNKNOWN  <what>: <why>          could not be checked here (never a pass)
# A test file with no CONTROL row fails the run: all-PASS is indistinguishable
# from checking nothing.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$REPO/tests"
NFAIL=0

pass()    { echo "PASS     $1"; }
fail()    { echo "FAIL     $1: ${2:-}"; NFAIL=$((NFAIL + 1)); }
control() { echo "CONTROL  $1"; }
unknown() { echo "UNKNOWN  $1: ${2:-}"; }
# chk <what> <want> <got>
chk() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want '$2' got '$3'"; fi; }
# chk_rc <what> <want-rc> <got-rc> [output]
chk_rc() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want rc $2 got $3${4:+: $(head -c 300 <<<"$4")}"; fi; }
# chk_grep <what> <ERE> <text>
chk_grep() { if grep -qE -- "$2" <<<"$3"; then pass "$1"; else fail "$1" "no match for '$2' in: $(head -c 300 <<<"$3")"; fi; }
# refuses <what> <ERE expected in stderr> -- <command...>: the command must exit non-zero
# AND say why; a CONTROL row, because it proves the refusal path is alive.
refuses() {
    local what="$1" want="$2"; shift 2; [[ "$1" == -- ]] && shift
    local out rc; out="$("$@" 2>&1)"; rc=$?
    if (( rc != 0 )) && grep -qE -- "$want" <<<"$out"; then control "$what"
    elif (( rc == 0 )); then fail "$what" "exited 0, expected a refusal"
    else fail "$what" "refused (rc $rc) but without '$want': $(head -c 300 <<<"$out")"; fi
}

# sandbox: a throwaway repo at $T with bin/ copied in. Sets T, PATH and the FAKE_* knobs.
sandbox() {
    # bin/lib.sh exports these; inherited from a shell that sourced the real repo's
    # lib.sh they would point the sandbox's scripts at this checkout's run/ and http/
    unset PDT_ROOT STATE_DIR HTTP_DIR BEACON_LOG ACCESS_LOG
    T="$(mktemp -d /tmp/pdt-tests.XXXXXX)"; export T
    mkdir -p "$T/bin" "$T/fakebin" "$T/vms" "$T/run" "$T/http/machines" "$T/http/roles/demo" "$T/pxe" "$T/fw" "$T/roms"
    cp -a "$REPO/bin/." "$T/bin/"
    cp -a "$TESTS/fakes/." "$T/fakebin/"
    : > "$T/pxe/ipxe.efi"; : > "$T/fw/CODE.fd"; : > "$T/fw/VARS.fd"; : > "$T/fw/CODE_NOSMM.fd"; : > "$T/fw/OTHER.fd"
    : > "$T/roms/efi-e1000e.rom"; : > "$T/roms/efi-virtio.rom"
    echo "APPS=" > "$T/http/roles/demo/role.cfg"
    cat > "$T/config.sh" <<CONF
HTTP_HOST="10.0.2.2"
HTTP_PORT="8099"
VM_MEMORY="2G"
VM_CPUS="2"
VM_DISK_SIZE="1G"
OVMF_CODE="$T/fw/CODE.fd"
OVMF_VARS_TEMPLATE="$T/fw/VARS.fd"
OVMF_CODE_NOSMM="$T/fw/CODE_NOSMM.fd"
IPXE_ROM_DIR="$T/roms"
CONF
    export PATH="$T/fakebin:$PATH"
    export FAKE_QEMU_ARGV="$T/qemu.argv" FAKE_MONITOR_LOG="$T/monitor.log" FAKE_MONITOR_REPLY="$T/monitor.reply"
    unset FAKE_QEMU_FAIL FAKE_ACPI_HONOURED VM_BOOT_FIRMWARE QEMU_TRACE 2>/dev/null || true
    trap sandbox_cleanup EXIT
}
# sandbox_cleanup: end every fake QEMU this sandbox started (by the pid in its own
# pidfile, never by pattern), then remove the directory (ours, by name pattern).
sandbox_cleanup() {
    local f p
    for f in "$T"/vms/*/qemu.pid "$T"/fake-child.pid; do
        [[ -f "$f" ]] || continue
        p="$(cat "$f")"; [[ "$p" =~ ^[0-9]+$ ]] && kill "$p" 2>/dev/null
    done
    [[ "$T" == /tmp/pdt-tests.* ]] && rm -rf "$T"
}
# argv_has <exact line>: QEMU was given this argument
argv_has() { grep -Fxq -- "$1" "$FAKE_QEMU_ARGV"; }
# argv_pair <option> <ERE>: QEMU was given <option> followed by a value matching
argv_pair() { awk -v o="$1" -v r="$2" '$0 == o { getline; if ($0 ~ r) f = 1 } END { exit !f }' "$FAKE_QEMU_ARGV"; }
argv_count() { grep -Fxc -- "$1" "$FAKE_QEMU_ARGV" || true; }
# beacon <uuid> <run> <step> <ev> [extra-query] [epoch]: one run/beacons.log line
beacon() {
    # Not date +%s.%3N: uutils coreutils 0.10.0 (Ubuntu 26.04's date) formats %3N
    # from the nanosecond integer without zero-padding it to 9 digits, so in the
    # first tenth of every second it prints 10x or 100x the real value and the
    # timestamps run backwards (ns=012765933 -> %3N=140; tests/README.md). %N is
    # right; cut it to milliseconds here.
    local t="${6:-$(date +%s.%N)}"; [[ -n "${6:-}" ]] || t="${t::-6}"
    printf '%s %s 10.0.2.15 id=%s&run=%s&step=%s&ev=%s%s\n' "$(date -d "@${t%.*}" -Is)" "$t" "$1" "$2" "$3" "$4" "${5:+&$5}" >> "$T/run/beacons.log"
}
finish() { exit $(( NFAIL > 0 )); }
