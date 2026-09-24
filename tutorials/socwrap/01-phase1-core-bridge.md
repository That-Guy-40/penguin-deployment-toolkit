# Part 1: Phase 1, the core bridge

Phase 1 is a single 730-line bash script that proves one idea: **you can put
GNU readline in front of any line-oriented program using only bash builtins
and socat.** Every later phase reuses this design, so it pays to understand
all of it.

- [1. The problem](#1-the-problem)
- [2. The architecture in one picture](#2-the-architecture-in-one-picture)
- [3. Reading the script top to bottom](#3-reading-the-script-top-to-bottom)
  - [3.1 Strict mode and that unusual IFS](#31-strict-mode-and-that-unusual-ifs)
  - [3.2 Defaults and environment overrides](#32-defaults-and-environment-overrides)
  - [3.3 Logging helpers](#33-logging-helpers)
  - [3.4 Cleanup and global traps](#34-cleanup-and-global-traps)
  - [3.5 Environment detection](#35-environment-detection)
  - [3.6 Building the socat address](#36-building-the-socat-address)
  - [3.7 Dry run](#37-dry-run)
  - [3.8 `run_socat()`: the heart of socwrap](#38-run_socat-the-heart-of-socwrap)
  - [3.9 Argument parsing with getopt](#39-argument-parsing-with-getopt)
  - [3.10 `main()`](#310-main)
- [4. PTY or no PTY?](#4-pty-or-no-pty)
- [5. The test harness](#5-the-test-harness)
- [6. Hands-on exercises](#6-hands-on-exercises)
- [7. Recap](#7-recap)

---

## 1. The problem

`nc host 80`, `telnet router`, `sqlite3`, a bare `python3` built without
readline, `ed`: these programs read raw lines from stdin. They have no arrow
keys, no history and no Ctrl-R. The usual fix is `rlwrap`, which isn't always
installed on a jump box, a container or a router shell.

socat has a `READLINE` address that looks like the answer:

```bash
socat READLINE,history=~/.h TCP:host:80
```

The project's author ran into a bug with it: **the prompt stays invisible
until you press the first key.** socat's readline support is also a
compile-time option that many distributions leave out.

socwrap's answer is to stop asking socat to do readline. bash already links
GNU readline, and `read -e` exposes it. So:

- **bash does the thinking**: prompt, editing, history.
- **socat does the plumbing**: connecting to whatever is on the other side.

---

## 2. The architecture in one picture

```
            your terminal
                 │  keystrokes
                 ▼
   ┌──────────────────────────────┐
   │ main bash process            │  IFS= read -e -r -p "$PROMPT" line
   │  (readline loop)             │  history -s "$line"
   └──────────────┬───────────────┘  printf '%s\n' "$line" >&4
                  │ fd 4 (write end)
                  ▼
            [ FIFO  "stdin" ]   ← unlinked right after opening
                  │
                  ▼ fd 0
   ┌──────────────────────────────┐
   │ socat  -  EXEC:cmd,pty,…     │───────►  wrapped command (own PTY, own session)
   └──────────────┬───────────────┘◄───────
                  │ fd 1
                  ▼
            [ FIFO  "stdout" ]
                  │ fd 5 (read end)
                  ▼
   ┌──────────────────────────────┐
   │ output forwarder: cat / tee  │──────► your terminal (and optional log file)
   └──────────────────────────────┘

   ┌──────────────────────────────┐
   │ monitor subshell             │  while kill -0 $socat_pid; do sleep 0.05; done
   │                              │  kill -USR1 $$   → breaks the readline loop
   └──────────────────────────────┘
```

This is the real process tree while wrapping `python3 -q`, captured with
`ps --forest`:

```
  PID  PPID COMMAND
 8832     1 bash phase1/socwrap.sh -H /tmp/hp -- python3 -q     ← readline loop
 8845  8832  \_ socat - EXEC:python3 -q,pty,setsid,echo=0,stderr
 8847  8832  \_ cat                                             ← output forwarder
 8848  8832  \_ bash phase1/socwrap.sh …                        ← monitor subshell
 8877  8848      \_ sleep 0.05                                  ← monitor's poll
```

`python3` itself doesn't appear. socat started it with `setsid`, so it runs in
a new session with its own PTY, outside the process group `ps` was asked about.

Keep this picture in mind: **five cooperating processes, two FIFOs and one
signal.**

---

## 3. Reading the script top to bottom

### 3.1 Strict mode and that unusual IFS

```bash
set -euo pipefail          # P1:21
IFS=$'\n\t'                # P1:22
```

`set -euo pipefail` is the standard "unofficial bash strict mode":

| Flag | Effect |
|------|--------|
| `-e` | Exit when any command fails (with the well-known exceptions: inside `if`/`while` conditions and in `&&`/`\|\|` lists) |
| `-u` | Treat unset variables as errors |
| `-o pipefail` | A pipeline fails if any part fails, not just the last |

`IFS=$'\n\t'` removes **space** from the word-splitting characters. After
this, an unquoted `$var` holding `a b` stays one word. It's a guard against
filenames with spaces, but it has two side effects you'll see later:

1. `"${array[*]}"` joins with the **first** character of IFS, which is now a
   newline. So `debug "socat command: ${SOCAT_CMD[*]}"` prints one element per
   line:
   ```
   [socwrap] DEBUG: socat command: socat
   -
   EXEC:python3 -q,pty,setsid,echo=0,stderr
   ```
2. Any code that *wants* to split on spaces must set IFS locally. The address
   builders do exactly this (`local IFS=','` at P1:290). In Phase 2,
   `--ssh-opts` does **not**, which matters in
   [Part 3, bug 3](03-field-notes-bugs-and-fixes.md#bug-3-arguments-containing-spaces-are-split-by-socat).

### 3.2 Defaults and environment overrides

```bash
readonly DEFAULT_HISTFILE="${HOME}/.socwrap_history"   # P1:29
readonly DEFAULT_HISTSIZE=500
readonly DEFAULT_PROMPT="socwrap> "

OPT_HISTFILE="${SOCWRAP_HISTFILE:-$DEFAULT_HISTFILE}"   # P1:35
OPT_HISTSIZE="${SOCWRAP_HISTSIZE:-$DEFAULT_HISTSIZE}"
OPT_PROMPT="${SOCWRAP_PROMPT:-$DEFAULT_PROMPT}"
```

Precedence is **CLI flag > environment variable > built-in default.** The
environment is read first, and `parse_args` overwrites it if a flag is given.

Two arrays hold the important state:

```bash
declare -a SOCAT_CMD=()     # the full socat argv, built later
declare -a WRAP_TARGET=()   # everything after `--`
```

The code uses arrays rather than strings so the command's arguments never go
through word splitting or glob expansion while bash is handling them.

### 3.3 Logging helpers

`err`, `warn`, `info` and `debug` (P1:57–80) all write to **stderr**, never to
stdout. That's deliberate: stdout carries the wrapped program's output, and
`--detect` prints JSON on stdout that other tools may parse. `debug` checks
`OPT_VERBOSE` first. `die` calls `err` and then `exit 1`.

### 3.4 Cleanup and global traps

```bash
cleanup() {                                  # P1:86
    local rc=$?
    if [[ -n "$SAVED_STTY" ]]; then
        stty "$SAVED_STTY" 2>/dev/null || stty sane 2>/dev/null || true
    else
        stty sane 2>/dev/null || true
    fi
    exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT    # 128 + SIGINT(2)
trap 'exit 143' TERM   # 128 + SIGTERM(15)
trap 'exit 129' HUP    # 128 + SIGHUP(1)
```

Things to notice:

- **One exit path.** INT, TERM and HUP just call `exit N`, and `exit` fires
  the EXIT trap. So the terminal is restored however the script ends.
- `local rc=$?` must be the **first** line in `cleanup`. Any command before
  it would overwrite `$?`.
- `stty -g` (taken later at P1:378) saves the terminal settings as an opaque
  string that `stty` can restore exactly. `stty sane` is the fallback.
- The exit codes follow the shell convention of 128 plus the signal number.

These are the **global** traps. `run_socat` replaces INT and adds USR1 while
the readline loop runs, then puts them back ([§3.8](#38-run_socat-the-heart-of-socwrap)).

### 3.5 Environment detection

`detect_env()` (P1:153–222) probes the system with small predicates:

| Helper | How it decides |
|--------|----------------|
| `_check_socat_available` | `command -v socat` |
| `_socat_version` | `socat -V \| awk '/socat version/{print $3; exit}'` |
| `_socat_has_readline` | `socat -V \| grep -qi readline` |
| `_socat_has_pty` | `socat -V \| grep -qiE 'WITH_PTY\|openpty'` |
| `_bash_version_int` | `printf '%d%02d' major minor`, so 5.2 → `502`, easy to compare with `-ge 400` |

With `jq` it builds JSON using `jq -n --arg … --argjson …`. This is the
correct way to build JSON from shell: `--arg` makes a properly escaped
string, and `--argjson` passes `true`/`false` through as real booleans.
Without jq it prints `key=value` lines from a heredoc.

```console
$ bash phase1/socwrap.sh --detect
{
  "socwrap_version": "1.0.0-phase1",
  "bash": { "version": "5.2.21(1)-release", "meets_minimum": true },
  "socat": {
    "available": true, "version": "1.8.0.0",
    "readline_support": true, "pty_support": true
  },
  "optional_tools": { "rlwrap": false, "jq": true },
  "ready": true
}
```

`ready` depends only on socat and bash. `readline_support` is informational,
which is the whole point of the design.

`preflight()` (P1:230) is the enforcing version: it `die`s if bash is older
than 4 or socat is missing.

### 3.6 Building the socat address

socat always takes two **addresses** and copies bytes between them. socwrap's
command is always:

```
socat  -  <remote-address>
```

`-` means "my own stdin and stdout", which will be the two FIFOs.
`build_exec_addr()` (P1:259–292) builds the remote address:

```bash
cmd_str=$(printf '%q ' "${target[@]}")   # shell-quote every word
cmd_str="${cmd_str% }"                   # drop trailing space
local addr="EXEC:${cmd_str}"

if [[ "$OPT_NO_PTY" -eq 0 ]]; then
    opts+=("pty")      # give the child a pseudo-terminal
    opts+=("setsid")   # new session: detach from socwrap's controlling tty
    opts+=("echo=0")   # PTY must not echo; readline already displayed the line
fi
opts+=("stderr")       # child's stderr → our stderr (so errors are visible)

local IFS=','
printf '%s,%s' "$addr" "${opts[*]}"      # "${opts[*]}" joins with ','
```

Result:

```
EXEC:python3 -q,pty,setsid,echo=0,stderr
```

About each option:

- **`pty`**: many programs (python, sqlite3, anything using `isatty()`)
  behave differently when stdin is a terminal. They print prompts, flush
  after each line and enable colour. A PTY makes them act as if a person
  were typing.
- **`setsid`**: the child gets its own session. Without it, a Ctrl-C in your
  terminal could go straight to the child's process group.
- **`echo=0`**: a PTY echoes input back by default. You've already seen the
  line in readline, so without this every line would appear twice. (The
  code comment at P1:276 still mentions "socat READLINE", which is left over
  from before the switch to `read -e`.)
- **`ctty` is left out on purpose** (P1:279): it opens `/dev/tty`, which fails
  in containers and detached sessions.
- `local IFS=','` in a function scopes the IFS change to that function. It's
  a neat way to join an array with commas.

The `printf '%q'` quoting is meant to protect arguments with spaces. socat
**doesn't follow shell quoting rules** in `EXEC:`, though, so this doesn't
work as intended. See
[Part 3, bug 3](03-field-notes-bugs-and-fixes.md#bug-3-arguments-containing-spaces-are-split-by-socat).

### 3.7 Dry run

`run_dry()` (P1:328) prints both layers without starting anything, so it's
the first thing to try when something looks wrong:

```console
$ bash phase1/socwrap.sh --dry-run -p "py> " -- python3 -q

[socwrap] DRY RUN — would execute:

  Readline layer (bash read -e):
    Prompt      : py>
    History file: /root/.socwrap_history
    History size: 500

  socat I/O bridge:
    socat \
      - \
      EXEC:python3 -q,pty,setsid,echo=0,stderr

[socwrap] PTY          : enabled
```

With `--no-pty` the address becomes `EXEC:/bin/bash --norc,stderr`.

### 3.8 `run_socat()`: the heart of socwrap

P1:367–514. We'll go through it in stages.

#### Stage 1: prepare

```bash
histdir=$(dirname "$OPT_HISTFILE")
[[ -d "$histdir" ]] || mkdir -p "$histdir" || warn …
SAVED_STTY=$(stty -g 2>/dev/null) || true
```

The `|| true` matters under `set -e`: when stdin isn't a terminal (in tests
or a pipeline) `stty -g` fails, and that mustn't kill the script.

#### Stage 2: two FIFOs and an ordering puzzle

```bash
tmpdir=$(mktemp -d)
in_pipe="${tmpdir}/stdin";  out_pipe="${tmpdir}/stdout"
mkfifo "$in_pipe" "$out_pipe"

"${SOCAT_CMD[@]}" 0<"$in_pipe" 1>"$out_pipe" &    # (A) background socat
socat_pid=$!

exec 4>"$in_pipe"     # (B) main shell: write end of in_pipe
exec 5<"$out_pipe"    # (C) main shell: read end of out_pipe
rm -rf "$tmpdir"      # (D) unlink both FIFOs
```

**Opening a FIFO blocks until the other end is opened too.** A reader waits
for a writer, and a writer waits for a reader. Here is how the steps above
avoid a deadlock:

1. (A) forks. The child applies its redirections **left to right**, so it
   first opens `in_pipe` for reading and blocks there.
2. (B) opens `in_pipe` for writing. Now both ends exist, so both opens
   return.
3. The child moves on to `1>"$out_pipe"`, opening it for writing, and blocks.
4. (C) opens `out_pipe` for reading. Both ends exist, so both return, and
   the child execs socat.

If (B) and (C) were swapped, the parent would block opening `out_pipe` for
reading while the child was still blocked opening `in_pipe`. Neither would
ever move: a deadlock. That's why the code comment says "Order matters".

(D) is a classic Unix trick. Once a FIFO is open, its **directory entry is no
longer needed**. The kernel keeps the pipe alive while any fd refers to it.
Deleting the directory right away means nothing is left in `/tmp` if the
script is killed with SIGKILL, and no other process can open the pipes by
path. You can see it in `/proc`:

```
/proc/<socwrap>/fd/4 -> /tmp/tmp.1txpf5uxIl/stdin (deleted)
/proc/<socwrap>/fd/5 -> /tmp/tmp.1txpf5uxIl/stdout (deleted)
```

#### Stage 3: the output forwarder

```bash
if [[ -n "$OPT_LOG" ]]; then
    _tee_cmd=(tee -a "$OPT_LOG")
    command -v stdbuf >/dev/null && _tee_cmd=(stdbuf -oL tee -a "$OPT_LOG")
    "${_tee_cmd[@]}" <&5 &
else
    cat <&5 &
fi
cat_pid=$!
```

The output path runs **independently of the input loop**. Output from the
wrapped program shows up whenever it arrives, even while you're halfway
through typing a line. `stdbuf -oL` makes `tee` line-buffered, so the log
file stays current. (`tee` writing to a terminal is already fine; the concern
is the log file.)

#### Stage 4: the monitor and SIGUSR1

```bash
(
    while kill -0 "$socat_pid" 2>/dev/null; do sleep 0.05; done
    kill -USR1 $$ 2>/dev/null
) &
monitor_pid=$!
```

The main loop spends nearly all its time blocked inside `read -e`. It needs
a way to be told "the other side has gone". So:

- `kill -0 PID` sends no signal. It only checks that the process exists.
- When socat disappears, the subshell sends `SIGUSR1` to `$$`. In a subshell
  `$$` is still the **parent** script's PID, which is exactly what's wanted.
- A signal that arrives while bash is inside `read` makes `read` return
  early, after bash has run the trap.

Why poll instead of `wait`? A process can only be reaped once. If the
monitor were allowed to `wait` on socat, the main script couldn't read
socat's exit code later. (In fact a subshell can't `wait` for its parent's
children at all.) Polling every 50 ms is cheap and leaves reaping to
`run_socat`.

#### Stage 5: turn on history in a non-interactive shell

```bash
set -o history
HISTSIZE="$OPT_HISTSIZE"; HISTFILESIZE="$OPT_HISTSIZE"
history -r "$OPT_HISTFILE" 2>/dev/null || true
```

A script runs in a **non-interactive** shell, where history is off, so
`history -s` would do nothing. `set -o history` turns it on. `history -r`
loads the file, so the up arrow and Ctrl-R work from the first prompt.

#### Stage 6: loop-local traps

```bash
trap 'true' INT               # Ctrl-C cancels the current line only
local _loop_exit=0
trap '_loop_exit=1' USR1      # monitor says socat is gone
```

The global `trap 'exit 130' INT` would end the whole session on Ctrl-C. For
the length of the loop, INT is swapped for a no-op. readline discards the
half-typed line, `read` returns 130, and the loop shows a fresh prompt. This
matches how bash itself behaves.

#### Stage 7: the readline loop

```bash
set +e
while true; do
    IFS= read -e -r -p "$OPT_PROMPT" line
    rc=$?
    [[ $_loop_exit -eq 1 ]] && break            # USR1 during read

    if [[ $rc -eq 0 ]]; then
        [[ -n "$line" ]] && history -s "$line"  # add to in-memory history
        printf '%s\n' "$line" >&4 || break      # send; EPIPE ⇒ socat gone
        sleep 0.05                              # let output print before the next prompt
        [[ $_loop_exit -eq 1 ]] && break
        kill -0 "$cat_pid" 2>/dev/null || break # forwarder gone ⇒ program exited
    elif [[ $rc -eq 130 ]]; then
        continue                                # Ctrl-C
    else
        break                                   # Ctrl-D / EOF
    fi
done
set -e
```

Line by line:

- **`IFS=`** keeps leading and trailing whitespace. Indented Python must reach
  the REPL unchanged.
- **`-r`** stops backslashes being treated as escapes (`\n` stays as those two
  characters).
- **`-e`** uses readline, which is the whole reason for this project.
- **`-p`** gives readline the prompt, so it redraws correctly when you edit,
  search or resize.
- **`set +e` / `set -e`**: `read` returns non-zero on EOF and on signals.
  Under `-e` that would end the script **before** history is saved.
- **`history -s`** adds the line to history without running it. Empty lines
  are skipped.
- **`sleep 0.05`** is a pragmatic fix for a race. For fast commands such as
  `pwd`, the reply arrives after `read -e` has already drawn the next prompt,
  which leaves the output after the prompt. 50 ms is usually enough for
  `cat` to print first. It's a heuristic: a slow network target will still
  race, and that's why later phases rework this area.
- **Why check `cat_pid` rather than `socat_pid`?** When the wrapped program
  exits (you typed `exit`), socat closes its **stdout** straight away, so
  `cat` gets EOF and exits. socat itself may stay alive while its stdin is
  still open. So "cat has gone" is the quicker and more reliable sign that
  the other end has finished. It saves you from seeing a dead prompt and
  having to type `exit` twice.

#### Stage 8: teardown

```bash
trap 'exit 130' INT;  trap - USR1          # restore global traps
history -w "$OPT_HISTFILE" 2>/dev/null || true
set +o history
exec 4>&-                                   # EOF to socat's stdin …
wait "$socat_pid" 2>/dev/null; rc=$?        # … and reap socat
exec 5>&-
kill "$cat_pid" "$monitor_pid" 2>/dev/null || true
wait "$cat_pid" 2>/dev/null || true
case $rc in 0) … ;; 1) warn … ;; 2) warn … ;; esac
return $rc
```

The intended sequence: save history, then close the write end of `in_pipe`
so socat sees EOF, forwards the EOF to the program (which exits), and socat
exits. Then reap everything.

Two of these lines don't do what the comments say.
[Part 3](03-field-notes-bugs-and-fixes.md) explains both:

- `exec 4>&-` **doesn't** deliver EOF, because the forwarder and the monitor
  inherited fd 4 when they were forked ([bug 1](03-field-notes-bugs-and-fixes.md#bug-1-ctrl-d-hangs-until-the-far-side-hangs-up)).
- A non-zero `wait` under `set -e` exits the script before
  `rc=$?` runs ([bug 4](03-field-notes-bugs-and-fixes.md#bug-4-socat-errors-skip-teardown-and-the-exit-code-explanation)).

(`exec 5>&-` closes fd 5, which was opened for reading. `>&-` and `<&-` both
just close the descriptor, so this works.)

### 3.9 Argument parsing with getopt

```bash
getopt --test >/dev/null 2>&1 || getopt_rc=$?
[[ $getopt_rc -ne 4 ]] && warn "util-linux getopt not found …"
```

`getopt --test` exits with **4** only for the enhanced util-linux `getopt`,
which is the version that supports long options. BSD and macOS `getopt`
return something else.

```bash
parsed=$(getopt --options "H:n:p:l:dDvVh" \
                --longoptions "history:,histsize:,prompt:,log:,dry-run,detect,no-pty,verbose,version,help" \
                --name socwrap -- "$@")
eval set -- "$parsed"
```

`getopt` rewrites the arguments into a normal form: options first, each
value as a separate quoted word, then `--`, then everything else.
`eval set --` loads that back into `$1 $2 …`. After that a plain `case`
loop with `shift`/`shift 2` does the rest, and anything after `--` becomes
`WRAP_TARGET`.

`-V` and `-h` print and `exit 0` inside the parser, so they never reach
`main`.

### 3.10 `main()`

```
parse_args → [--detect? print, exit] → require a command
          → [--verbose? banner + detect to stderr]
          → preflight → build_socat_cmd → [--dry-run? print, exit] → run_socat
```

Detect and dry-run both exit before anything is started. That makes them
safe to use as diagnostics.

---

## 4. PTY or no PTY?

This is the most common source of confusion with phase 1.

```bash
# looks broken: bash's own "bash-5.2$ " prompt appears next to "bash> "
bash phase1/socwrap.sh -p "bash> " -- /bin/bash

# recommended
bash phase1/socwrap.sh --no-pty -p "bash> " -- /bin/bash --norc --noprofile

# alternative: keep the PTY and blank the shell's prompt
bash phase1/socwrap.sh -p "bash> " -- env PS1='' /bin/bash --norc --noprofile
```

With a PTY, bash decides it's interactive (`isatty(0)` is true) and prints
its own PS1. With `--no-pty`, bash's stdin is a pipe, so it runs as a script
reader with no prompt and no job control. socwrap's readline does all the
editing.

Rule of thumb:

| Wrapped program | Use |
|-----------------|-----|
| Shells (`bash`, `sh`, `zsh`) | `--no-pty`, or PTY with `PS1=''` |
| REPLs that only prompt on a tty (`python3`, `sqlite3`) | default PTY |
| Plain filters (`cat`, `bc -q`, `ed`) | either works |

---

## 5. The test harness

`lib/test_lib.sh` is a small TAP-compatible framework. It provides
`describe`, `assert_eq`, `assert_contains`, `assert_match`,
`assert_exit_code` and more. Each phase's `tests/test_phaseN.sh` sources it.

```bash
bash lib/test_lib.sh --self-test        # test the framework itself
bash phase1/tests/test_phase1.sh        # 51 tests
bash phase1/tests/test_phase1.sh --tap  # machine-readable, for CI
```

The suites are **cumulative**: `test_phase2.sh` sources `test_phase1.sh` and
runs its functions again against the phase 2 script, so a later phase can't
quietly break an earlier feature. Most checks go through `--dry-run`,
`--detect` and argument handling. The live-session tests feed stdin from a
pipe with `timeout` as a safety net, and the harder interactive behaviour is
in `tests/MANUAL_TESTS.md`.

On the reference machine phase 1 passes **51/51**.

---

## 6. Hands-on exercises

1. **Watch the plumbing.** In one terminal run
   `bash phase1/socwrap.sh -H /tmp/h -- python3 -q`. In another:
   ```bash
   pid=$(pgrep -f 'H /tmp/h -- python3' | head -1)
   ps -o pid,ppid,comm,args --forest -g "$(ps -o sid= -p "$pid" | tr -d ' ')"
   ls -l /proc/$pid/fd | grep deleted
   ```
   Find the five processes and the two unlinked FIFOs.

2. **Prove the ordering argument.** Copy the script, swap the
   `exec 4>` and `exec 5<` lines, and run it. It hangs before the first
   prompt. Why? (Answer in [§3.8, stage 2](#stage-2-two-fifos-and-an-ordering-puzzle).)

3. **Ctrl-C versus Ctrl-D.** Type half a line and press Ctrl-C. The line is
   discarded and the session carries on. Then press Ctrl-C on an empty
   prompt, and then Ctrl-D. Compare the effects with the traps in
   [stage 6](#stage-6-loop-local-traps).

4. **Race the prompt.** Wrap `bash --norc` with `--no-pty`, run `pwd`
   several times, then change `sleep 0.05` to `sleep 0` in a copy and try
   again. How often does the output land after the prompt?

5. **History round-trip.** Use `-H /tmp/myhist -n 3`, type five commands and
   exit. `cat /tmp/myhist`: why are there only three lines?

6. **Double echo.** In a copy, remove `echo=0` from `build_exec_addr` and
   wrap `python3 -q`. Every line now appears twice. Explain which layer
   prints each copy.

Continue to **[Part 2: Phase 2, transport modes](02-phase2-transport-modes.md)**.

---

## 7. Recap

- readline comes from `read -e`, so socat only moves bytes.
- Two FIFOs are opened in a careful order and then unlinked.
- There are five processes: the loop, socat, the target, the forwarder and
  the monitor.
- `SIGUSR1` from the monitor breaks a blocked `read`. INT is scoped to
  "cancel the line".
- History is enabled by hand in a non-interactive shell and saved on the way
  out.
- `--no-pty` for shells, a PTY for tty-sensitive REPLs.
