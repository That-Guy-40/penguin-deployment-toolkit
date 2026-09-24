# Part 3: Bugs found along the way, and how to fix them

Reading code carefully enough to explain it tends to turn up problems. This
part collects the ones found while writing Parts 1 and 2.

Each bug is described the same way:

- **What you'd notice**: the symptom, in plain terms.
- **Try it**: commands that make it happen on your own machine.
- **Why it happens**: the cause, using words from Parts 0–2.
- **The fix**: a small, tested change.
- **The lesson**: the general idea worth remembering.

Two new words to start:

> **New term: reproduce / reproduction.** Making a bug happen on purpose,
> reliably. A bug you can reproduce is a bug you can prove fixed.
>
> **New term: patch (also called a diff).** A file listing the lines to
> remove (starting `-`) and add (starting `+`) to change a program. `git
> apply file.patch` makes those changes for you.

**Every bug below was reproduced on a real machine**, not just suspected
from reading. Every fix was tested, and the fixed scripts still pass the
project's own test suites (Phase 1: 51 of 51; Phase 2: 129 of 129, with a
stand-in `ssh` program because the test machine had no real one).

| # | Bug | Phases | Patch |
|---|-----|--------|-------|
| 1 | [Ctrl-D hangs until the other side hangs up](#bug-1-ctrl-d-hangs-until-the-other-side-hangs-up) | 1, 2 | core |
| 2 | [Options meant for the wrapped program get grabbed by socwrap](#bug-2-options-meant-for-the-wrapped-program-get-grabbed-by-socwrap) | 2 | core |
| 3 | [An argument with a space in it gets split in two](#bug-3-an-argument-with-a-space-in-it-gets-split-in-two) | 1, 2 | optional |
| 4 | [When socat fails, socwrap skips its clean-up and advice](#bug-4-when-socat-fails-socwrap-skips-its-clean-up-and-advice) | 1, 2 | core |
| 5 | [Telnet login prompts don't appear until you type](#bug-5-telnet-login-prompts-dont-appear-until-you-type) | 2 | core |
| 6 | [A late SIGUSR1 can stop socwrap while it shuts down](#bug-6-a-late-sigusr1-can-stop-socwrap-while-it-shuts-down) | 1, 2 | core |
| | [Smaller issues](#smaller-issues) | 2 | none |

**Applying the patches.** From the top folder of a socwrap copy at commit
`08ec3b7`:

```bash
git apply /path/to/tutorials/socwrap/patches/phase1-core-fixes.patch
git apply /path/to/tutorials/socwrap/patches/phase2-core-fixes.patch
git apply /path/to/tutorials/socwrap/patches/phase2-argv-quoting.patch   # optional; apply after the core patches
```

The patches only change the `phase1` and `phase2` folders. Later phases
copied the same code, so they probably have the same bugs. Checking that
is a good exercise.

---

## Bug 1: Ctrl-D hangs until the other side hangs up

**What you'd notice.** You're connected to a server and press Ctrl-D to
leave. The prompt disappears but socwrap doesn't exit. It sits there until
the *server* decides to close the connection. The same happens when
wrapping `cat`, or any program that waits for its input to end.

**Try it.**

```console
$ # a server that answers each line, then keeps the connection open for 30 s
$ socat TCP-LISTEN:2352,reuseaddr SYSTEM:'while read l; do echo "srv:$l"; done; sleep 30' &
$ printf 'one\n' | timeout 8 bash phase2/socwrap.sh -p '' -t 127.0.0.1 2352
srv:one
$ echo $?
124              ← "timeout" had to stop it after 8 seconds
```

(`printf 'one\n' |` types a line for you and then sends EOF, just like
pressing Ctrl-D. `timeout 8` stops the command after 8 seconds, and status
124 means it had to.)

**Why it happens.** When you're done, socwrap closes its end of the typing
pipe:

```bash
exec 4>&-     # the comment says: "socat sees EOF on stdin and exits"
```

But recall two facts from Part 0:

- A pipe only gives its reader EOF when **every** writing end is closed.
- Children **inherit** copies of their parent's file descriptors.

The copier and the watcher were both started *after* fd 4 was opened, so
each has its own copy of the writing end. socwrap closes its copy, but two
more are still open. socat never sees EOF, so it never finishes, and
socwrap waits for it indefinitely.

You can see the extra copies in `/proc`:

```
PID   program  open pipes
1467  bash     4 → typing pipe, 5 → output pipe     ← the input loop
1483  bash     4 → typing pipe, 5 → output pipe     ← the watcher: still has the typing pipe open!
1482  cat      0 → output pipe, 4 → typing pipe, …  ← the copier:  still has it open too!
1480  socat    0 → typing pipe, 1 → output pipe
```

(Leaving by typing `exit` still works, because then the *program* ends the
conversation. Only "I'm done, you hang up" is broken.)

**The fix.** When starting each helper, close its copy of fd 4 straight
away. `4>&-` after a command means "run this without fd 4":

```diff
-        cat <&5 &
+        cat <&5 4>&- &
 …
-    ) &
+    ) 4>&- &
```

The same change goes on the `tee` and telnet-cleaner versions of the
copier. With the patch, the example above finishes in **0.58 seconds**
instead of hanging. (socat waits half a second after EOF for any last
reply, which accounts for most of that.)

**The lesson.** Background helpers get copies of every open file
descriptor. If *closing* something is meant to signal "done", close it in
every helper that doesn't need it.

---

## Bug 2: Options meant for the wrapped program get grabbed by socwrap

**What you'd notice.**

```console
$ bash phase2/socwrap.sh --dry-run -- ls -t
[socwrap] ERROR: Mode 'tcp' requires a host
$ bash phase2/socwrap.sh -- bash -c 'echo hi'
[socwrap] ERROR: Chroot directory not found: echo hi
$ bash phase2/socwrap.sh -- python3 -c 'print(1)'
[socwrap] ERROR: Chroot directory not found: print(1)
```

**Why it happens.** Phase 2 reads the command line in two passes
([Part 2 §3](02-phase2-transport-modes.md#3-reading-the-command-line-in-two-passes)).
The first pass looks for `-t -u -T -U -s -c` in **every** word you typed.
It doesn't stop at `--`, which is supposed to mean "the rest belongs to the
program". So `-c` in `bash -c` is taken as socwrap's chroot option.
`bash -c`, `python3 -c`, `grep -c`, `ls -t`, `sort -u`, `tar -c` and
`curl -s` are all affected, and they're common.

**The fix.** When the first pass reaches `--`, copy everything from there
on unchanged and stop looking:

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

`"${args[@]:i}"` means "every item in the array from position `i`
onwards". That includes the `--` itself, which the second pass (getopt)
still needs to see.

**The lesson.** If you write your own option reader in front of a standard
one, it has to follow the same rules, including "stop at `--`".

---

## Bug 3: An argument with a space in it gets split in two

**What you'd notice.**

```console
$ printf '\n' | bash phase1/socwrap.sh --no-pty -- printf '[%s]\n' 'a b'
[a]
[b]
```

The program was meant to receive `a b` as **one** argument and print
`[a b]`. It received two.

**Why it happens.** socwrap puts the program and its arguments inside the
socat address, using bash's `printf '%q'` to add backslashes the way bash
would (`a\ b`). But socat isn't bash:

1. socat first reads the address with **its own** rules for quotes and
   backslashes. (These are what let it tell a comma inside an argument from
   the commas between options.)
2. Then `EXEC:` **splits the command at every space**, however it was
   quoted.

Tried directly with socat 1.8.0.0, every quoting style fails the same way:

```console
$ echo | socat - 'EXEC:printf [%s]\\n a\ b'      → [a] [b]
$ echo | socat - "EXEC:printf [%s]\\\\n 'a b'"   → [a] [b]
$ echo | socat - 'EXEC:printf [%s]\\n "a b"'     → [a] [b]
```

No quoting inside an `EXEC:` address keeps a space inside one argument.
(This is also why `--ssh-opts "-p 2222"` works by accident: see
[Part 2 §5.4](02-phase2-transport-modes.md#54-ssh-build_ssh_addr-p2446).)

**The fix (optional patch).** Don't put the arguments in the address at
all. Pass them to socat in an environment variable, and have a fixed,
never-changing address unpack them:

```bash
# in build_socat_cmd, exec mode:
SOCWRAP_ARGV=$(_sh_quote "${WRAP_TARGET[@]}")   # →  'printf' '[%s]\n' 'a  b'
export SOCWRAP_ARGV
remote_addr=$(build_exec_addr)

# in build_exec_addr:
local addr='SYSTEM:eval exec \"$SOCWRAP_ARGV\"'
```

Step by step:

- `_sh_quote` puts each argument in single quotes, the one quoting style
  every shell understands. (`it's` becomes `'it'\''s'`: close the quote,
  add an escaped `'`, reopen.)
- socat's `SYSTEM:` address runs its text with the basic shell `/bin/sh`.
  Here the text is always the same: `eval exec "$SOCWRAP_ARGV"`. `eval`
  unpacks the quoted arguments exactly, and `exec` replaces the shell with
  the program so nothing extra is left running.
- The `export` has to be in `build_socat_cmd`, not `build_exec_addr`. The
  builder runs inside `$( … )`, a subshell (Part 1 §4.6), so anything it
  exports vanishes when it finishes.

Tested with `'a  b'` (two spaces), `x,y`, `it's`, `c:d` and a literal
`$HOME`: all five arrive exactly as typed, and `python3 -q` still works on
a PTY.

**Why it's optional:** `--dry-run` now shows the fixed
`SYSTEM:eval exec "$SOCWRAP_ARGV"` instead of your command. The patch adds
a `Command :` line to the dry-run output to make up for that, and relaxes
one Phase 1 test from "output contains `EXEC`" to "contains `EXEC` or
`SYSTEM`".

**The lesson.** `printf '%q'` quotes for **bash**. Before quoting, find out
which program will actually read the text, and follow *its* rules.

---

## Bug 4: When socat fails, socwrap skips its clean-up and advice

**What you'd notice.** Connect to a port where nothing is listening. You
see socat's own terse error, and then socwrap just exits. The helpful
`connection refused — is the target listening?` message never appears.

**Try it.**

```console
$ printf 'x\n' | bash phase2/socwrap.sh -v -t 127.0.0.1 1
…
socat[796] E connect(5, AF=2 127.0.0.1:1, 16): Connection refused
[socwrap] DEBUG: cleanup() called with exit code 1
```

(Port 1 is almost never in use, so the connection is refused.)

**Why it happens.** Two separate reasons.

*Reason 1: strict mode stops the script at `wait`.*

```bash
set -e                                # strict mode, back on after the loop
…
wait "$socat_pid" 2>/dev/null         # socat failed, so this returns 1…
rc=$?                                 # …and strict mode stops the script before this line
```

Under `set -e`, any plain command that fails ends the script. `wait` returns
socat's exit status, so whenever socat fails, the script jumps straight to
its EXIT trap. It skips closing fd 5, stopping the copier and watcher, and
calling `_interpret_exit`, the function with the helpful messages.

*Reason 2: 111 isn't a socat exit status.* In the Linux kernel's list of
error numbers (**errno**), 111 means "connection refused". But socat
doesn't exit with that number. It exits with **1** for a refused
connection. So even without reason 1, the `111)` case could never match.

> **New term: errno.** The error number the Linux kernel reports when
> something fails, such as 111 for "connection refused". It's not the same
> thing as a program's exit status.

**The fix.**

```diff
-    wait "$socat_pid" 2>/dev/null
-    rc=$?
+    rc=0
+    wait "$socat_pid" 2>/dev/null || rc=$?
```

Strict mode never triggers on a command to the left of `||` (Part 1 §4.1),
so the status is saved and the script carries on. The Phase 2 patch also
changes the message for status 1 to match what actually causes it:
`connection refused, unreachable, or TLS failure? Re-run with -v`.

**The lesson.** Under `set -e`, save a command's status with
`cmd || rc=$?`, never `cmd; rc=$?`.

---

## Bug 5: Telnet login prompts don't appear until you type

**What you'd notice.** You connect to a router with `-T`. The welcome
message appears, but no `login:` prompt. You type your username blind,
press Enter, and only then does the prompt appear, with your answer after
it.

**Try it.** The lab's pretend telnet server sends `login: ` without a line
ending, just like a real one:

```console
$ bash labs/lab-servers.sh start
$ (sleep 3) | bash phase2/socwrap.sh -p '' -T 127.0.0.1 7004   # and watch for "login: "
```

Timed with a small script that watches for `login: ` on screen:

```
original:  login: never shown before input
patched:   login: visible after 0.02 s
```

The cleaner on its own shows the same thing:

```console
(printf 'login: '; sleep 2; echo) | cat            → first character after 0.002 s
(printf 'login: '; sleep 2; echo) | perl -pe '…'   → first character after 2.00 s
```

**Why it happens.** It's **buffering** (Part 1, step 3). `perl -p` reads
input **one whole line at a time**. Until a line ending arrives, perl holds
the partial line (`login: `) in its buffer. A telnet server deliberately
doesn't end the prompt's line, so the cursor waits after it. The line
ending only arrives after you've typed your name.

**The fix.** Read whatever bytes have arrived, clean them, and pass them on
straight away:

```perl
$| = 1;                                   # don't buffer output: print immediately
while (sysread(STDIN, my $b, 4096)) {     # read whatever has arrived (up to 4096 bytes)
    $b =~ s/\xff[\xfb-\xfe][\x00-\xff]//g;
    $b =~ s/\xff[\xf0-\xfa]//g;
    $b =~ s/\xff\xff/\xff/g;
    print $b;
}
```

`sysread` returns as soon as *any* data is available, not just a full
line.

One known limit: if a control code happened to be split across two reads,
it wouldn't be removed. That's rare in practice, because servers send
negotiation in small single pieces. A complete fix would keep an
unfinished `FF…` sequence back for the next read.

**The lesson.** Line-by-line tools (`perl -p`, `sed`, `awk`, `grep`) are a
poor fit for interactive conversations, where prompts don't end a line.

---

## Bug 6: A late SIGUSR1 can stop socwrap while it shuts down

**What you'd notice.** Now and then, usually when the program ends straight
away, socwrap exits with status **138** and your shell prints
`User defined signal 1`. Sometimes the command you just typed is missing
from the history file afterwards.

**Try it.** Wrap a program that ends at once, 30 times, and count the exit
statuses:

```console
$ for i in $(seq 30); do printf '\n' | bash phase2/socwrap.sh --no-pty -- printf 'x\n' >/dev/null 2>&1; echo $?; done | sort | uniq -c
      8 138
     22 0
```

138 is 128 + 10, and signal 10 is SIGUSR1. So socwrap was stopped by
SIGUSR1 in 8 of 30 runs. In a second test of 40 runs with a real command
typed, 7 were stopped, and **2 of those lost the command from the history
file.**

**Why it happens.** It's a **race condition** (Part 1, step 7). The input
loop can end for either of two reasons: the watcher's SIGUSR1, or its own
"has the copier stopped?" check. When the check wins, the watcher is still
running and about to send its signal. Meanwhile teardown does:

```bash
trap - USR1        # USR1 back to its DEFAULT action, which is: stop the process
history -w …       # ← the watcher's SIGUSR1 can land any time from here on
```

Part 0 §7 warned about exactly this: `trap -` doesn't mean "ignore", it
means "go back to the default", and the default for SIGUSR1 is to stop.
If the signal lands before `history -w`, the history is lost too.

**The fix.** *Ignore* SIGUSR1 during teardown, and stop the watcher
straight away:

```diff
     trap 'exit 130' INT
-    trap - USR1
+    trap '' USR1
+    kill "$monitor_pid" 2>/dev/null || true
```

After the patch: **0 of 50** runs were stopped and 0 hung, for both Phase 1
and Phase 2.

**The lesson.** `trap '' SIG` ignores a signal and `trap - SIG` restores the
default, which usually means stopping. If a signal might still arrive
late, ignore it.

---

## Smaller issues

These aren't patched. Each is minor, and most need a one-line change.

| Where | What's wrong |
|-------|--------------|
| SSH and chroot modes | `pty` is written into their builders, so **`--no-pty` has no effect** there, although `--help` says it applies. |
| `--dry-run` | `PTY: enabled` and `Timeout:` are shown for every mode, including network and Unix modes where they don't apply. |
| `--dry-run` | `Chroot shell:` always shows `/bin/sh`, even when you named a different shell. |
| UDP checks | The port isn't checked to be between 1 and 65535 (`-u host 99999` is accepted), unlike TCP. |
| `host:port` form | Splits at the first and last colon, so IPv6 addresses such as `::1` don't work in that form. Use `-t HOST PORT`. |
| Telnet without perl | The fallback `sed` pattern matches the literal text `^[[`, not the escape character, and nothing matches byte 255. **Without perl, nothing is cleaned**, though the warning only says "limited". |
| Telnet with perl | Subnegotiation contents leak through (the lab shows two stray bytes, `\030\001`). A real byte 255 followed by FB–FE loses the next character. |
| `build_exec_addr` comment | Says "socat READLINE handles character display", which is out of date since socwrap moved to `read -e`. |
| `--ssh-opts` | No shell is involved, so `~` isn't expanded. Use `$HOME/.ssh/key`, not `~/.ssh/key`. |
| Option reading | `--ssh-opts` is handled in both passes. The second copy only runs if you write `--ssh-opts=VALUE`. |
| Phase 2 tests | Seven SSH `--dry-run` tests fail on machines without `ssh`, because the pre-run checks require it even for a dry run. |
| Test coverage | The tests mostly check `--dry-run` text, so none of bugs 1–6 was caught. Each "Try it" above could become a **regression test**. |

> **New term: regression test.** A test that reproduces a fixed bug, so
> that if the bug ever comes back ("regresses"), the test fails.

---

## Before and after

| Check | Original | With the patches |
|-------|----------|------------------|
| Ctrl-D while a server keeps the connection open | hangs (stopped by `timeout` after 8 s) | exits in 0.58 s |
| `-- ls -t` and `-- bash -c 'echo from-bash-c'` | mistaken for socwrap options | runs the command |
| `-- printf '[%s]\n' 'a  b' 'x,y' "it's" 'c:d' '$HOME'` | split and changed | all arrive intact (optional patch) |
| Connect where nothing is listening | no advice; helpers not stopped | advice printed, exit 1, helpers stopped |
| Pretend telnet server's `login: ` | never shown before you type | shown after 0.02 s |
| Program that ends at once (×50) | stopped by SIGUSR1 in 8 of 30 and 7 of 40 runs | 0 of 50 |
| `phase1/tests/test_phase1.sh` | 51 / 51 | 51 / 51 |
| `phase2/tests/test_phase2.sh` (with stand-in ssh) | 129 / 129 | 129 / 129 (the optional patch includes its one test update) |
