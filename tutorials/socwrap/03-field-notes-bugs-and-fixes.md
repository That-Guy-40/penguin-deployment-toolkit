# Part 3: Field notes, bugs and fixes

Reading code closely enough to explain it tends to turn up bugs. These are
the ones found while writing Parts 1 and 2. **Every item below was
reproduced on a real run**, not just inferred from reading. Where there's a
fix, it was tested too, and the patched scripts still pass the project's own
suites (phase 1: 51/51; phase 2: 129/129, with a stub `ssh` on PATH because
the reference machine has no ssh client).

Why this belongs in a tutorial: each bug shows a Unix idea from Parts 1 and
2 that's easy to get wrong. Fd inheritance, `set -e` edge cases, signal
timing, and tools with their own quoting rules.

| # | Bug | Phases | Effect | Patch |
|---|-----|--------|--------|-------|
| 1 | [Ctrl-D hangs until the far side hangs up](#bug-1-ctrl-d-hangs-until-the-far-side-hangs-up) | 1, 2 | EOF doesn't end the session in network modes, or with programs that wait for stdin EOF | core |
| 2 | [Mode flags are stolen from the wrapped command](#bug-2-mode-flags-are-stolen-from-the-wrapped-command) | 2 | `-- bash -c …`, `-- ls -t`, `-- grep -c …` are misparsed | core |
| 3 | [Arguments containing spaces are split by socat](#bug-3-arguments-containing-spaces-are-split-by-socat) | 1, 2 | `-- cmd 'a b'` reaches the program as two arguments | optional |
| 4 | [socat errors skip teardown and the exit-code explanation](#bug-4-socat-errors-skip-teardown-and-the-exit-code-explanation) | 1, 2 | "connection refused" advice never shown, helpers not reaped | core |
| 5 | [Telnet prompts without a newline are held back](#bug-5-telnet-prompts-without-a-newline-are-held-back) | 2 | `login:` isn't shown until after you've typed | core |
| 6 | [A late SIGUSR1 can kill socwrap during teardown](#bug-6-a-late-sigusr1-can-kill-socwrap-during-teardown) | 1, 2 | exit status 138, sometimes history lost | core |
| | [Smaller issues](#smaller-issues) | 2 | help text and dry-run mismatches, edge cases | none |

Patches, relative to the socwrap repo root at commit `08ec3b7`:

```bash
cd socwrap
git apply /path/to/tutorials/socwrap/patches/phase1-core-fixes.patch
git apply /path/to/tutorials/socwrap/patches/phase2-core-fixes.patch
git apply /path/to/tutorials/socwrap/patches/phase2-argv-quoting.patch   # optional, apply after core
```

The patches fix the phase 1 and 2 directories only. Later phases copied the
same code, so they probably have the same bugs. Checking them is a good
exercise.

---

## Bug 1: Ctrl-D hangs until the far side hangs up

**Symptom.** Press Ctrl-D in a TCP session to a server that keeps its end
open, or while wrapping `cat` or any program that runs until stdin closes.
The prompt disappears and socwrap hangs.

**Reproduce.**

```console
$ socat TCP-LISTEN:2352,reuseaddr SYSTEM:'while read l; do echo "srv:$l"; done; sleep 30' &
$ printf 'one\n' | timeout 8 bash phase2/socwrap.sh -p '' -t 127.0.0.1 2352
srv:one
socat[8609] W exiting on signal 15
$ echo $?
124                      # killed by timeout after 8.00 s
```

**Cause.** Teardown depends on this line:

```bash
exec 4>&-     # "Close our write end of in_pipe — socat sees EOF on stdin and exits"
```

A FIFO only reports EOF when **every** write descriptor is closed, in every
process. The output forwarder (`cat <&5 &`) and the monitor subshell
(`( … ) &`) were forked **after** `exec 4>"$in_pipe"`, and a fork copies all
open fds. So both hold their own copy of fd 4 and keep the pipe open.
`/proc` shows it:

```
PID   COMM   FDs pointing at the (deleted) FIFOs
1467  bash   4->…/stdin  5->…/stdout      ← main loop
1483  bash   4->…/stdin  5->…/stdout      ← monitor: holds the write end
1482  cat    0->…/stdout 4->…/stdin 5->…  ← forwarder: holds the write end
1480  socat  0->…/stdin  1->…/stdout
```

socat never sees EOF, never exits, and `wait "$socat_pid"` blocks until the
remote end closes. In EXEC mode, typing `exit` still works because the
*child* ends the session. Only "I'm done, you hang up" is broken.

**Fix.** Close fd 4 in each helper as it's started:

```diff
-        cat <&5 &
+        cat <&5 4>&- &
 …
-    ) &
+    ) 4>&- &
```

The same change goes on the `tee` and telnet-scrubber forwarder variants.
With the patch, the same reproduction exits in **0.58 s**, which is socat's
0.5 s half-close timeout plus a little overhead.

**Lesson.** Background jobs inherit every open fd. When a descriptor's
*closing* means something (EOF on a pipe, releasing a lock, closing a
socket), close it explicitly in every child that doesn't need it.

---

## Bug 2: Mode flags are stolen from the wrapped command

**Symptom.**

```console
$ bash phase2/socwrap.sh --dry-run -- ls -t
[socwrap] ERROR: Mode 'tcp' requires a host
$ bash phase2/socwrap.sh -- bash -c 'echo hi'
[socwrap] ERROR: Chroot directory not found: echo hi
$ bash phase2/socwrap.sh -- python3 -c 'print(1)'
[socwrap] ERROR: Chroot directory not found: print(1)
```

**Cause.** The phase 2 pre-pass
([Part 2 §3](02-phase2-transport-modes.md#3-two-pass-argument-parsing))
walks **all** of `"$@"` looking for `-t -u -T -U -s -c`. It never stops at
`--`, so arguments that belong to the wrapped command are taken as socwrap
modes. `bash -c`, `python3 -c`, `grep -c`, `ls -t`, `sort -u`, `tar -c`,
`ssh -T` and `curl -s` are all affected, and they're very common.

**Fix.** Stop at `--` and pass the rest through untouched:

```diff
             --ssh-opts)
                 OPT_SSH_OPTS="$next"
                 i=$((i + 2))
                 ;;
+            --)
+                # Everything after -- belongs to the wrapped command: copy it
+                # through untouched and stop scanning for mode flags.
+                remaining_args+=("${args[@]:i}")
+                break
+                ;;
```

`"${args[@]:i}"` is bash array slicing: every element from index `i`
onwards, **including** the `--` itself, which `getopt` still needs to see.

**Lesson.** A hand-written pre-parser must follow the same `--` convention
as the real parser that runs after it.

---

## Bug 3: Arguments containing spaces are split by socat

**Symptom.**

```console
$ printf '\n' | bash phase1/socwrap.sh --no-pty -- printf '[%s]\n' 'a b'
[a]
[b]
```

**Cause.** `build_exec_addr` quotes the argv with bash's `printf '%q'`
(`a\ b`) and builds `EXEC:printf \[%s\]\\n a\ b`. But socat isn't a shell:

1. socat's **address parser** handles quotes and backslashes itself (so
   `\,` and `\:` protect the separators).
2. `EXEC:` then **splits the command on whitespace**, and a space escaped at
   the shell level doesn't survive that.

These experiments with socat 1.8.0.0 show it:

```console
$ echo | socat - 'EXEC:printf [%s]\\n a\ b'      → [a] [b]
$ echo | socat - "EXEC:printf [%s]\\\\n 'a b'"   → [a] [b]
$ echo | socat - 'EXEC:printf [%s]\\n "a b"'     → [a] [b]
```

No quoting inside an `EXEC:` address keeps an argument with a space in it
as one argument. The same thing explains why `--ssh-opts "-p 2222"` works
**by accident**
([Part 2 §5.4](02-phase2-transport-modes.md#54-ssh-build_ssh_addr-p2446)):
the space socwrap failed to split on is split by socat instead.

**Fix (optional patch).** Keep the arguments out of the address altogether:

```bash
# build_socat_cmd, exec branch
SOCWRAP_ARGV=$(_sh_quote "${WRAP_TARGET[@]}")   # 'printf' '[%s]\n' 'a  b'
export SOCWRAP_ARGV
remote_addr=$(build_exec_addr)

# build_exec_addr
local addr='SYSTEM:eval exec \"$SOCWRAP_ARGV\"'
```

- `_sh_quote` wraps each argument in POSIX single quotes (`it's` becomes
  `'it'\''s'`). That's safe for `/bin/sh`, unlike `%q`, which can produce
  bash-only `$'…'` strings.
- The socat address is now a **constant**. `\"` gets through socat's parser
  as a literal `"`, so sh runs `eval exec "$SOCWRAP_ARGV"`. That rebuilds
  the exact argv, and `exec` replaces the shell so no extra process is left
  behind.
- The export has to happen in `build_socat_cmd`. `build_exec_addr` runs
  inside `$( … )`, a subshell, so anything exported there disappears.

Tested with `'a  b'` (two spaces), `x,y`, `it's`, `c:d` and a literal
`$HOME`: all five arrive intact. `python3 -q` still works with a PTY. Why is
it optional? `--dry-run` now shows `SYSTEM:eval exec "$SOCWRAP_ARGV"`
instead of the command. The patch adds a `Command :` line to dry-run output
to make up for it, and relaxes one phase 1 test from "contains `EXEC`" to
"contains `EXEC` or `SYSTEM`".

**Lesson.** `printf %q` quotes for **bash**. Before you quote, check who
will actually parse the string.

---

## Bug 4: socat errors skip teardown and the exit-code explanation

**Symptom.** `-t 127.0.0.1 1` (nothing listening) shows socat's own error
and exits. The friendly `connection refused — is the target listening?`
message never appears:

```console
$ printf 'x\n' | bash phase2/socwrap.sh -v -t 127.0.0.1 1
…
socat[796] E connect(5, AF=2 127.0.0.1:1, 16): Connection refused
[socwrap] DEBUG: cleanup() called with exit code 1
```

**Cause 1: `set -e` at the `wait`.**

```bash
set -e                                # restored after the loop
…
wait "$socat_pid" 2>/dev/null         # returns socat's status: 1
rc=$?                                 # never reached
```

A plain command that fails under `set -e` ends the script. So on **any**
non-zero socat exit, the script jumps straight to the EXIT trap. It skips
closing fd 5, killing and reaping the forwarder and monitor, and
`_interpret_exit`.

**Cause 2: 111 is never socat's exit status.** 111 is the Linux *errno* for
ECONNREFUSED. socat exits **1** for a refused connection, so the `111)` arm
couldn't match even without cause 1.

**Fix.**

```diff
-    wait "$socat_pid" 2>/dev/null
-    rc=$?
+    rc=0
+    wait "$socat_pid" 2>/dev/null || rc=$?
```

A failure on the left of `||` doesn't trigger `set -e`. The phase 2 patch
also changes the message for exit 1 to something that fits the real cases:
`connection refused, unreachable, or TLS failure? Re-run with -v`. The
harmless `111)` arm is left in place.

**Lesson.** Under `set -e`, capture a status with `cmd || rc=$?`, never with
`cmd; rc=$?`.

---

## Bug 5: Telnet prompts without a newline are held back

**Symptom.** Connecting to a router with `-T`, you see the banner but no
`login:` prompt. After you type your username and press Enter, the prompt
and the echo arrive together.

**Reproduce** with the lab's fake telnetd, which sends `login: ` with no
newline:

```console
$ bash labs/lab-servers.sh start
$ (sleep 3) | bash phase2/socwrap.sh -p '' -T 127.0.0.1 7004 | <timer that watches for "login: ">
login: never shown                         # original
login: visible after 0.02s                 # patched
```

The same effect, reduced to the filter alone:

```console
(printf 'login: '; sleep 2; echo) | cat            → first byte after 0.002 s
(printf 'login: '; sleep 2; echo) | perl -pe '…'   → first byte after 2.00 s
```

**Cause.** `perl -p` wraps the script in `while (<STDIN>) { …; print }`.
`<STDIN>` reads a whole **line**, so a partial line (the prompt) waits in
perl's buffer until a newline arrives. Telnet servers leave the cursor
after the prompt on purpose, so that newline only comes after you type.

**Fix.** Read whatever bytes are available and write them out straight
away:

```perl
$| = 1;                                   # autoflush STDOUT
while (sysread(STDIN, my $b, 4096)) {     # returns as soon as any bytes arrive
    $b =~ s/\xff[\xfb-\xfe][\x00-\xff]//g;
    $b =~ s/\xff[\xf0-\xfa]//g;
    $b =~ s/\xff\xff/\xff/g;
    print $b;
}
```

One known limit: an IAC sequence split across two reads isn't removed. Over
TCP this is rare, because servers send negotiation as one small write. A
thorough fix would keep a trailing incomplete `\xff…` sequence in a buffer
for the next read.

**Lesson.** Line-oriented filters (`perl -p`, `sed`, `awk`, `grep`) aren't
suitable for interactive streams where prompts don't end in a newline.

---

## Bug 6: A late SIGUSR1 can kill socwrap during teardown

**Symptom.** Sometimes, when the wrapped program exits right away (or the
remote end closes as you press Enter), socwrap dies with status **138**
(128 + SIGUSR1 = 10), and the shell prints `User defined signal 1`.

**Reproduce.** Run a program that exits immediately, 30 times:

```console
$ for i in $(seq 30); do printf '\n' | bash phase2/socwrap.sh --no-pty -- printf 'x\n' >/dev/null 2>&1; echo $?; done | sort | uniq -c
      8 138
     22 0
```

That's 8 out of 30. In a second run of 40 with a real command typed, 7 were
killed, and **2 of those lost the command from the history file.**

**Cause.** The loop can end for two reasons: the monitor's `USR1`, or the
`kill -0 "$cat_pid"` check after the 50 ms sleep. When the second one wins,
the monitor is still running. Teardown then does:

```bash
trap - USR1                       # reset USR1 to its DEFAULT action: terminate
history -w …                      # ← the monitor's USR1 can land anywhere from here on
```

and the monitor's delayed `kill -USR1 $$` kills the script, sometimes
before `history -w` has run.

**Fix.** *Ignore* USR1 during teardown instead of resetting it, and stop the
monitor straight away:

```diff
     trap 'exit 130' INT
-    trap - USR1
+    trap '' USR1
+    kill "$monitor_pid" 2>/dev/null || true
```

After the patch: **0 of 50** runs killed and 0 hung, for phase 1 and phase 2.

**Lesson.** `trap - SIG` means "restore the default", and for most signals
the default is to die. If a signal can still arrive late, use `trap '' SIG`
to ignore it.

---

## Smaller issues

Not patched. Each one is small, and most are a one-line change.

| Where | Issue |
|-------|-------|
| `build_ssh_addr`, `build_chroot_addr` | The PTY options are hard-coded, so **`--no-pty` is ignored** in ssh and chroot modes, although `--help` lists it for "EXEC/SSH/chroot modes". |
| `run_dry` | `PTY: enabled` and `Timeout:` are printed for every mode, including TCP, UDP and Unix, which never use a PTY or (for Unix) a timeout. |
| `run_dry` | `Chroot shell:` always shows `OPT_CHROOT_SHELL` (`/bin/sh`), even when a shell was given after the directory. |
| `preflight` (udp) | No 1–65535 range check (`-u h 99999` is accepted), unlike TCP. |
| pre-pass `host:port` | Splits at the first and last colons, so IPv6 literals (`::1:80`, `[::1]:80`) don't work. Use the two-word form. |
| `iac_scrub_cmd` (sed fallback) | The pattern `\^\[\[` matches the literal text `^[[`, not the ESC byte, and nothing matches `0xFF`. **Without perl, telnet scrubbing does nothing**, but the tool only warns that it's "limited". |
| `iac_scrub_cmd` (perl) | Subnegotiation payloads leak (`IAC SB 18 01 IAC SE` leaves the bytes `\030\001` on screen). A literal `FF FF` followed by `FB`–`FE` is misread, so the next byte is lost. |
| `build_exec_addr` | The comment on `echo=0` says "socat READLINE handles character display", which is out of date since the move to `read -e`. |
| `--ssh-opts` | No shell is involved, so `~` isn't expanded (`-i ~/.ssh/key` fails). Use `$HOME/.ssh/key`. |
| parse_args | `--ssh-opts` appears in both the pre-pass and `getopt`. Only `--ssh-opts=VALUE` reaches the `getopt` branch. |
| `test_phase2.sh` | Seven SSH dry-run tests fail on machines without an ssh client, because preflight requires `ssh` even for `--dry-run`. Either skip those tests when ssh is absent or let dry-run skip the check. |
| Test coverage | The suites mostly check `--dry-run` text, so none of bugs 1–6 was caught. Each bug above has a ready-made reproduction that could become a regression test. |

---

## Summary of what the patched scripts were checked against

| Check | Original | Patched |
|-------|----------|---------|
| Ctrl-D in TCP mode, server keeps connection open | hangs (killed after 8 s) | exits in 0.58 s |
| `-- ls -t`, `-- bash -c 'echo from-bash-c'` | mode misparsed | runs the command |
| `-- printf '[%s]\n' 'a  b' 'x,y' "it's" 'c:d' '$HOME'` | split and mangled | all intact (optional patch) |
| `-t 127.0.0.1 1` | no socwrap message, helpers never reaped | warning printed, exit 1, helpers reaped |
| Fake telnetd `login: ` prompt | never shown before input | shown after 0.02 s |
| Wrapped program exits immediately (×50) | killed by USR1 in 8/30 and 7/40 runs | 0/50 |
| `phase1/tests/test_phase1.sh` | 51/51 | 51/51 |
| `phase2/tests/test_phase2.sh` (stub ssh) | 129/129 | 129/129 core, 129/129 with the quoting patch and its test tweak |
