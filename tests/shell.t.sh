#!/bin/bash
# shell: the command file it writes, the output it reads back, the exit codes.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox
B="$T/bin"
"$B/vm-create" lab1 --mode none >/dev/null 2>&1
U="$(sed -nE 's/^VM_UUID=//p' "$T/vms/lab1/vm.conf")"

refuses "a machine with no run yet" "no run known" -- "$B/shell" lab1 'dir'
beacon "$U" run1 ts-start ok "mode=shell"
cmd_dir="$T/http/cmd/$U/run1"; up_dir="$T/http/uploads/$U/run1"; mkdir -p "$up_dir"

# the command file: CRLF, @echo off, written whole (renamed into place)
printf 'hello from winpe\r\n[pdt] exit code 0\r\n' > "$up_dir/cmd-1.out"
out="$("$B/shell" lab1 'dir W:\' --timeout 5 2>&1)"; rc=$?
chk_rc "rc 0 when the machine's output says exit code 0" 0 "$rc" "$out"
chk "the output is printed without the exit-code trailer" "hello from winpe" "$(tr -d '\r' <<<"$out")"
chk "1.cmd is a CRLF cmd script: @echo off then the command" "@echo off|dir W:\|" "$(tr '\r\n' '|-' < "$cmd_dir/1.cmd" | sed 's/-//g')"
[[ ! -e "$cmd_dir/1.cmd.part" ]] && pass "no .part file left behind" || fail ".part" "left"

# the machine's exit code comes back as ours
printf 'boom\r\n[pdt] exit code 3\r\n' > "$up_dir/cmd-2.out"
out="$("$B/shell" lab1 'exit /b 3' --timeout 5 2>&1)"; rc=$?
chk_rc "the machine's exit code 3 is shell's exit code" 3 "$rc" "$out"
printf 'neg\r\n[pdt] exit code -1\r\n' > "$up_dir/cmd-3.out"
"$B/shell" lab1 'x' --timeout 5 >/dev/null 2>&1; rc=$?
chk_rc "an exit code outside 1..255 becomes 1" 1 "$rc"
[[ -f "$cmd_dir/3.cmd" ]] && pass "command files are numbered consecutively (3.cmd)" || fail "numbering" "$(ls "$cmd_dir")"

# timeout: no output file -> 2, with the hint
t0=$(date +%s); out="$("$B/shell" lab1 'slow' --timeout 1 2>&1)"; rc=$?
if (( rc == 2 )) && grep -q "timeout after 1 s" <<<"$out"; then control "no output within --timeout: rc 2 and a timeout message"; else fail "timeout path" "rc $rc: $out"; fi
(( $(date +%s) - t0 <= 3 )) && pass "the timeout is honoured" || fail "timeout honoured" "took $(( $(date +%s) - t0 )) s"

# --off writes the stop command
printf '[pdt] exit code 42\r\n' > "$up_dir/cmd-5.out"
out="$("$B/shell" lab1 --off --timeout 5 2>&1)"; rc=$?
chk_rc "--off exits 0" 0 "$rc" "$out"
chk_grep "--off writes 'exit /b 42' for WinPE" '^exit /b 42' "$(tr -d '\r' < "$cmd_dir/5.cmd")"
refuses "no command and no --off" "a command, or --off" -- "$B/shell" lab1

# a collector (Linux) run gets an sh script
beacon "$U" run2 collect ok "os=linux"
mkdir -p "$T/http/uploads/$U/run2"; printf 'linux\n[pdt] exit code 0\n' > "$T/http/uploads/$U/run2/cmd-1.out"
"$B/shell" lab1 'uname -a' --timeout 5 >/dev/null 2>&1
chk "after a 'collect' event the file is a #!/bin/sh script (LF)" "#!/bin/sh|uname -a|" "$(tr '\n' '|' < "$T/http/cmd/$U/run2/1.cmd")"
grep -q $'\r' "$T/http/cmd/$U/run2/1.cmd" && fail "no CR in the sh script" "CR found" || pass "no CR in the sh script"

# the note when the machine has probably left WinPE
beacon "$U" run2 ts-done ok
printf '[pdt] exit code 0\n' > "$T/http/uploads/$U/run2/cmd-2.out"
out="$("$B/shell" lab1 'x' --timeout 5 2>&1)"; rc=$?
if grep -q "may no longer be in WinPE" <<<"$out"; then pass "after ts-done shell warns the machine may no longer be in WinPE"
else fail "after ts-done shell warns the machine may no longer be in WinPE" "rc $rc, output [$out]; events in order: $("$B/status" lab1 2>&1 | tail -n +2 | awk '{print $5}' | tr '\n' ',')"; fi
finish
