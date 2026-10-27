#!/bin/bash
# await: new events only, fail short-circuits, timeout, --run and --from-start.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox
B="$T/bin"
"$B/vm-create" lab1 --mode none >/dev/null 2>&1
U="$(sed -nE 's/^VM_UUID=//p' "$T/vms/lab1/vm.conf")"
OTHER="11111111-2222-3333-4444-555555555555"

# an event that arrives after await starts satisfies it
( sleep 1; beacon "$U" r1 ts-start ok; beacon "$U" r1 shell ok "msg=hi" ) &
out="$("$B/await" lab1 shell 10 2>&1)"; rc=$?; wait
chk_rc "await <vm> <step> returns 0 on the step's ok event" 0 "$rc" "$out"
chk_grep "and prints it" "await: .* shell ok" "$out"

# an event that arrived BEFORE await started does not count (the control for the "new events only" rule)
out="$("$B/await" lab1 shell 1 2>&1)"; rc=$?
if (( rc == 2 )) && grep -q "TIMEOUT" <<<"$out"; then control "an earlier 'shell ok' does not satisfy a new await (rc 2, TIMEOUT)"; else fail "new events only" "rc $rc: $out"; fi
chk_grep "the timeout message names the last event seen" "no event from this machine|last event: " "$out"
out="$("$B/await" lab1 shell 1 --from-start 2>&1)"; rc=$?
chk_rc "--from-start accepts the earlier event" 0 "$rc" "$out"

# ev=fail for any step first -> 1
( sleep 1; beacon "$U" r1 20-disk fail "rc=5" ) &
out="$("$B/await" lab1 ts-done 10 2>&1)"; rc=$?; wait
chk_rc "a fail event before the step returns 1" 1 "$rc" "$out"
chk_grep "and names it" "FAILED before ts-done: .* 20-disk fail rc=5" "$out"

# another machine's events are ignored
( sleep 1; beacon "$OTHER" r9 ts-done ok ) &
out="$("$B/await" lab1 ts-done 3 2>&1)"; rc=$?; wait
chk_rc "another machine's ts-done does not satisfy (timeout, rc 2)" 2 "$rc" "$out"

# --run latest: only the latest run's events, from its first line (including earlier ones)
beacon "$U" r2 ts-start ok; beacon "$U" r2 ts-done ok
out="$("$B/await" lab1 ts-done 1 --run latest 2>&1)"; rc=$?
chk_rc "--run latest sees the latest run's earlier ts-done" 0 "$rc" "$out"
out="$("$B/await" lab1 shell 1 --run latest 2>&1)"; rc=$?
if (( rc == 2 )); then control "--run latest does not see run r1's 'shell ok' (another run)"; else fail "--run latest isolates the run" "rc $rc: $out"; fi
out="$("$B/await" lab1 ts-done 1 --run r1 2>&1)"; rc=$?
chk_rc "--run r1 (by id): r1's own fail event (20-disk) is seen first, rc 1" 1 "$rc" "$out"
out="$("$B/await" lab1 ts-done 1 --run r7 2>&1)"; rc=$?
chk_rc "--run <unknown id> is an error (rc 2)" 2 "$rc" "$out"
chk_grep "that says the run is unknown" "no run r7" "$out"

# ids: the uuid itself and a unique prefix work like the name
out="$("$B/await" "$U" ts-done 1 --run latest 2>&1)"; rc=$?
chk_rc "a full UUID as id" 0 "$rc" "$out"
out="$("$B/await" "${U:0:8}" ts-done 1 --run latest 2>&1)"; rc=$?
chk_rc "a unique UUID prefix as id" 0 "$rc" "$out"
refuses "an id that matches nothing" "not a VM name, a UUID, or a unique prefix" -- "$B/await" zzz ts-done 1
finish
