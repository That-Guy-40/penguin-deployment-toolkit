#!/bin/bash
# status: the table's flags (FAIL, STUCK?, busy), names, the detail view.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox
B="$T/bin"
"$B/vm-create" lab1 --mode none >/dev/null 2>&1
U="$(sed -nE 's/^VM_UUID=//p' "$T/vms/lab1/vm.conf")"
F="aaaaaaaa-0000-0000-0000-000000000001"; S="bbbbbbbb-0000-0000-0000-000000000002"; Y="cccccccc-0000-0000-0000-000000000003"
now=$(date +%s)
out="$("$B/status" 2>&1)"
chk_grep "no logs yet: says so" "no events yet" "$out"
beacon "$U" r1 ts-start ok "mode=deploy&product=lab-vm&model=lab-vm" "$((now-100))"
beacon "$U" r1 20-disk ok "msg=one+disk" "$((now-90))"
beacon "$F" r1 ts-start ok "mode=deploy" "$((now-80))"
beacon "$F" r1 30-apply fail "rc=7" "$((now-70))"
beacon "$S" r1 ts-start ok "mode=deploy" "$((now-1300))"
beacon "$S" r1 35-updates start "" "$((now-1200))"
beacon "$Y" r1 35-updates start "" "$((now-1200))"
mkdir -p "$T/http/uploads/$Y/r1"; touch "$T/http/uploads/$Y/r1/ts.log"
out="$("$B/status" 2>&1)"
chk_grep "the lab VM's row carries its name" "^$U +lab1 +20-disk ok" "$out"
chk_grep "a machine whose last event is ev=fail is flagged FAIL" "^$F +30-apply fail +[0-9]+[sm] +FAIL" "$out"
chk_grep "sitting on ev=start for 20 min with no uploads: STUCK\?" "^$S +35-updates start +[0-9]+m +STUCK\?" "$out"
chk_grep "sitting on ev=start but pushing logs: busy" "^$Y +35-updates start +[0-9]+m +busy" "$out"
chk_grep "the DETAIL column carries msg=" "msg=one disk" "$out"
chk_grep "mode and product columns" "deploy +r1 +lab-vm +lab-vm" "$out"
out="$("$B/status" --stale 30 2>&1)"
grep -qE "^$S .*STUCK" <<<"$out" && fail "--stale 30 lifts the STUCK? flag at 20 min" "still flagged" || control "--stale 30: the 20-minute machine is no longer STUCK? (the flag follows the threshold)"
out="$("$B/status" lab1 2>&1)"
chk_grep "detail view: header with id and name" "^$U +lab1" "$out"
chk_grep "detail view: the boot's first event at +0.0s with its fields" "\+ *0\.0s +\(\+ *0\.0s\) +ts-start +ok +mode=deploy model=lab-vm product=lab-vm" "$out"
chk_grep "detail view: the second event 10 s after the first" "\(\+ *10\.0s\) +20-disk +ok +msg=one disk" "$out"
refuses "detail of an unknown machine" "not a VM name, a UUID" -- "$B/status" nobody
finish
