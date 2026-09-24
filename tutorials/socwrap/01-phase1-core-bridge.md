# Part 1: Phase 1, the core bridge

Phase 1 is one bash script, 730 lines long. It proves one idea:

> **You can give any line-by-line program arrow keys, history and Ctrl-R
> search, using only bash and socat.**

Every later phase of socwrap is built on this script, so this part goes
through it slowly.

**Words from [Part 0](00-building-blocks.md) used here:** shell, script,
process, parent/child, background process, stdin/stdout/stderr, file
descriptor (fd), pipe, named pipe (FIFO), EOF, signal, trap, exit status,
PTY, echo, readline, socat address. If any of these feel shaky, the
[glossary](GLOSSARY.md) links back to where each is explained.

New words introduced in this part are marked **New term**, as before.

- [1. The idea in one picture](#1-the-idea-in-one-picture)
- [2. Trying it before reading it](#2-trying-it-before-reading-it)
- [3. How the script is organised](#3-how-the-script-is-organised)
- [4. Walking through the code](#4-walking-through-the-code)
  - [4.1 Safety settings at the top](#41-safety-settings-at-the-top)
  - [4.2 Settings and where they come from](#42-settings-and-where-they-come-from)
  - [4.3 Printing messages](#43-printing-messages)
  - [4.4 Tidying up on the way out](#44-tidying-up-on-the-way-out)
  - [4.5 Checking the machine: `--detect`](#45-checking-the-machine---detect)
  - [4.6 Writing the socat address](#46-writing-the-socat-address)
  - [4.7 Showing the plan without running it: `--dry-run`](#47-showing-the-plan-without-running-it---dry-run)
  - [4.8 The main event: `run_socat()`](#48-the-main-event-run_socat)
  - [4.9 Reading the command line](#49-reading-the-command-line)
  - [4.10 `main()`: the running order](#410-main-the-running-order)
- [5. PTY or no PTY?](#5-pty-or-no-pty)
- [6. How the project tests itself](#6-how-the-project-tests-itself)
- [7. Exercises](#7-exercises)
- [8. What you now know](#8-what-you-now-know)

Line numbers look like `P1:367`, meaning line 367 of `phase1/socwrap.sh`,
at socwrap commit `08ec3b7`.

---

## 1. The idea in one picture

socwrap splits the work between two tools, each doing what it's good at:

- **bash does the thinking.** It shows the prompt, lets you edit the line,
  and keeps the history. It does this with its built-in `read -e` command,
  which uses the readline library.
- **socat does the plumbing.** It connects to the program or server on the
  other side and moves bytes back and forth. That's all.

These two halves are the two **layers** the project keeps mentioning.

> **New term: layer.** One part of a system with a single job, stacked on
> or beside another. Here: the readline layer (bash) and the transport
> layer (socat).

They're joined by two named pipes, one for each direction:

```
   you type
      │
      ▼
 ┌─────────────────────┐
 │ bash: the input loop│   shows the prompt, lets you edit,
 │  (readline)         │   saves history, sends the finished line →
 └─────────┬───────────┘
           │ fd 4
           ▼
    ═══ named pipe "stdin" ═══
           │
           ▼
 ┌─────────────────────┐          ┌────────────────────────┐
 │ socat               │ ◄──────► │ the wrapped program    │
 │                     │          │ (python3, sqlite3, …)  │
 └─────────┬───────────┘          └────────────────────────┘
           │
           ▼
    ═══ named pipe "stdout" ═══
           │ fd 5
           ▼
 ┌─────────────────────┐
 │ the copier (cat)    │ ──► your screen (and a log file, if you asked for one)
 └─────────────────────┘

 ┌─────────────────────┐
 │ the watcher         │  checks every 1/20 s: "is socat still running?"
 │                     │  when it isn't, sends SIGUSR1 to the input loop
 └─────────────────────┘
```

> **New term: wrap / wrapped program.** "Wrapping" a program means running
> it with socwrap in front of it. The wrapped program is the one you're
> actually talking to, such as `python3`.

This is the real list of processes while socwrap wraps `python3`, captured
with `ps --forest` (which draws parents and children as a tree):

```
  PID  PPID COMMAND
 8832     1 bash phase1/socwrap.sh -H /tmp/hp -- python3 -q     ← the input loop
 8845  8832  \_ socat - EXEC:python3 -q,pty,setsid,echo=0,stderr
 8847  8832  \_ cat                                             ← the copier
 8848  8832  \_ bash phase1/socwrap.sh …                        ← the watcher
 8877  8848      \_ sleep 0.05                                  ← the watcher pausing
```

(`PPID` is the parent's PID. `python3` isn't listed because socat
deliberately starts it in a separate group of processes; see
[§4.6](#46-writing-the-socat-address).)

**Five processes, two named pipes and one signal.** Everything below
explains how the script sets that up and takes it down again.

---

## 2. Trying it before reading it

It helps to see the tool working before reading its code. You need bash
and socat installed.

```bash
git clone https://github.com/That-Guy-40/socwrap && cd socwrap

bash phase1/socwrap.sh --detect                 # is this machine ready?
bash phase1/socwrap.sh -p "py> " -- python3 -q  # python with arrow keys and history
```

Type `x = 6`, then `x * 7`, then press ↑ twice. Leave with `exit()` or
Ctrl-D.

The `--` in the command is a common convention. It means "socwrap's own
options stop here; everything after this is the program to run".

> **New term: option (or flag).** A setting you pass on the command line,
> like `-p "py> "` (a short option with a value) or `--detect` (a long
> option). `--` marks the end of a program's own options.

---

## 3. How the script is organised

The script is divided into sections, each a group of **functions**:

> **New term: function.** A named block of code you can run by name, like
> a small command defined inside the script.

| Section | What it does | Where |
|---------|--------------|-------|
| Safety settings | Makes bash stop on errors | P1:20–22 |
| Settings | Default values, overridable | P1:28–50 |
| Messages | `err`, `warn`, `info`, `debug`, `die` | P1:57–80 |
| Tidy-up | Restore the terminal on exit | P1:86–105 |
| Checks | `detect_env`, `preflight` | P1:111–242 |
| Address builder | Writes the socat address | P1:259–317 |
| Running | `run_dry`, `run_socat` | P1:328–514 |
| Command line | `show_help`, `parse_args` | P1:520–681 |
| Main | `main` puts it all in order | P1:687–730 |

bash reads the whole file first and only then runs `main "$@"` on the last
line, so the functions can appear in any order.

---

## 4. Walking through the code

### 4.1 Safety settings at the top

```bash
set -euo pipefail          # P1:21
IFS=$'\n\t'                # P1:22
```

**`set -euo pipefail`** turns on three safety features. People call this
**strict mode**:

| Setting | Plain meaning |
|---------|---------------|
| `-e` | If a command fails, stop the script instead of carrying on. |
| `-u` | Using a variable that was never set is an error, which catches typos. |
| `-o pipefail` | In `a \| b \| c`, count it as failed if **any** step fails, not just the last one. |

> **New term: strict mode.** The `set -euo pipefail` line: make bash stop at
> the first sign of trouble.

`-e` has exceptions that come up later. It doesn't apply to a command used
as an `if` or `while` test, or on the left of `||` or `&&`. The difference
between `cmd; rc=$?` and `cmd || rc=$?` turns out to matter a lot
([bug 4 in Part 3](03-field-notes-bugs-and-fixes.md#bug-4-when-socat-fails-socwrap-skips-its-clean-up-and-advice)).

**`IFS=$'\n\t'`** needs a bit more explanation. When bash expands an
unquoted variable, it chops the value into separate words wherever it sees
certain characters. That's **word splitting**, and the characters are
listed in a variable called **IFS**. Normally IFS is space, tab and
newline. This line **removes space**, so a value like `my file.txt` stays
in one piece.

> **New term: word splitting and IFS.** bash cutting a value into separate
> words. IFS ("internal field separator") lists the characters it cuts on.

It's a safety measure against filenames with spaces in them. Keep it in
mind, though, because it has two side effects later on:

1. When the script prints a list, it joins the items with the first
   character of IFS, which is now a newline. So the `--verbose` output puts
   each part of the socat command on its own line.
2. Any code that *does* want to split on spaces has to change IFS itself.
   Phase 2's `--ssh-opts` doesn't, and only works by luck
   ([Part 3, bug 3](03-field-notes-bugs-and-fixes.md#bug-3-an-argument-with-a-space-in-it-gets-split-in-two)).

### 4.2 Settings and where they come from

```bash
readonly DEFAULT_HISTFILE="${HOME}/.socwrap_history"    # P1:29
readonly DEFAULT_HISTSIZE=500
readonly DEFAULT_PROMPT="socwrap> "

OPT_HISTFILE="${SOCWRAP_HISTFILE:-$DEFAULT_HISTFILE}"    # P1:35
OPT_HISTSIZE="${SOCWRAP_HISTSIZE:-$DEFAULT_HISTSIZE}"
OPT_PROMPT="${SOCWRAP_PROMPT:-$DEFAULT_PROMPT}"
```

- `readonly` means the value can't be changed later.
- `${A:-B}` means "use A if it's set and not empty, otherwise B".
- `SOCWRAP_HISTFILE` and the others are **environment variables**, settings
  you can pass to any program from the shell, like
  `SOCWRAP_PROMPT="db> " bash socwrap.sh …`.

> **New term: environment variable.** A named setting passed from a shell
> to the programs it starts.

So each setting has three possible sources, and the first one found wins:
**command-line option → environment variable → built-in default.**

Two **arrays** hold the important data:

```bash
declare -a SOCAT_CMD=()     # the socat command, built later, one word per slot
declare -a WRAP_TARGET=()   # the program to wrap: everything after --
```

> **New term: array.** A variable that holds a list of values, each in its
> own numbered slot. `"${arr[@]}"` gives them back as separate words,
> exactly as stored.

Keeping a command in an array rather than one long string means an
argument like `my file.txt` stays one argument. It never goes through word
splitting.

### 4.3 Printing messages

`err`, `warn`, `info` and `debug` (P1:57–80) print a tagged message such as
`[socwrap] WARN: …`. All of them print to **stderr**, never stdout. stdout
is reserved for the wrapped program's output and for the machine-readable
`--detect` report, so status messages never get mixed into either.

`debug` only prints when you pass `--verbose`. `die` prints an error and
stops the script with exit status 1.

### 4.4 Tidying up on the way out

A program on a PTY can leave your terminal in a strange state, for
example with typing invisible. socwrap makes sure it restores the terminal
however it ends:

```bash
cleanup() {                                  # P1:86
    local rc=$?                              # remember why we're exiting
    if [[ -n "$SAVED_STTY" ]]; then
        stty "$SAVED_STTY" 2>/dev/null || stty sane 2>/dev/null || true
    else
        stty sane 2>/dev/null || true
    fi
    exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT    # Ctrl-C     → exit status 128+2
trap 'exit 143' TERM   # kill       → 128+15
trap 'exit 129' HUP    # window shut → 128+1
```

- **`stty`** is the tool that reads and changes terminal settings.
  `stty -g` prints the current settings as one string (saved later, in
  §4.8), and `stty "$that_string"` puts them back. `stty sane` resets to
  reasonable defaults, as a fallback.
- **Every route leads to the EXIT trap.** Ctrl-C, `kill` and a closed
  window each call `exit`, and `exit` always runs the EXIT trap. So the
  tidy-up runs every time.
- `local rc=$?` has to be the very first line. `$?` changes after every
  command, so it must be saved before anything else runs.
- `|| true` means "if that failed, never mind". Under strict mode that's
  how you say a failure is acceptable.

These are the script's **general** traps. While you're typing, socwrap
swaps some of them for different ones (§4.8, step 6).

### 4.5 Checking the machine: `--detect`

`detect_env()` (P1:153–222) checks what's installed and prints a report.
Each check is a small helper function:

| Helper | Question it answers | How |
|--------|---------------------|-----|
| `_check_socat_available` | Is socat installed? | `command -v socat` finds a program on the search path |
| `_socat_version` | Which version? | read `socat -V` and pick out the version number |
| `_socat_has_readline` | Was socat built with readline? | search `socat -V` output for "readline" |
| `_socat_has_pty` | Can socat make PTYs? | search for `WITH_PTY` or `openpty` |
| `_bash_version_int` | Is bash new enough? | turns 5.2 into `502`, so it can be compared with `400` (bash 4.0) |

If the `jq` tool is installed, the report comes out as **JSON**, a
structured text format other programs can read easily. `jq -n --arg …`
builds the JSON safely, handling quote marks inside values properly.
Without jq it prints plain `name=value` lines.

> **New term: JSON.** A widely used text format for structured data:
> `{"name": "value", "ready": true}`.

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

`ready` only needs socat and bash 4 or later. `readline_support` is shown
for interest only. socwrap never uses socat's readline, which is the whole
point of the design.

A second function, `preflight()` (P1:230), makes the same essential checks
just before running and stops with an error if bash is too old or socat is
missing. "Preflight" as in a pilot's checklist before take-off.

### 4.6 Writing the socat address

socwrap always runs socat the same way:

```
socat  -  <the other side>
```

`-` means "socat's own stdin and stdout", which will be connected to the
two named pipes. `build_exec_addr()` (P1:259–292) writes the other side:

```bash
cmd_str=$(printf '%q ' "${target[@]}")   # quote each word of the command
cmd_str="${cmd_str% }"                   # remove the trailing space
local addr="EXEC:${cmd_str}"

if [[ "$OPT_NO_PTY" -eq 0 ]]; then
    opts+=("pty")      # give the program a fake terminal
    opts+=("setsid")   # start it in its own separate group of processes
    opts+=("echo=0")   # the fake terminal must not echo; readline already showed the line
fi
opts+=("stderr")       # let the program's error messages reach your screen

local IFS=','
printf '%s,%s' "$addr" "${opts[*]}"      # join the options with commas
```

For `python3 -q` the result is:

```
EXEC:python3 -q,pty,setsid,echo=0,stderr
```

The four address options, one at a time:

- **`pty`** gives the program a fake terminal (Part 0 §9), so python shows
  its `>>>` prompt and replies straight away instead of saving output up.
- **`setsid`** puts the program in a new **session**, a separate group of
  processes with its own terminal. That way Ctrl-C in *your* terminal is
  handled by socwrap and doesn't hit the program directly. It's also why
  `python3` didn't appear in the process tree in §1.

  > **New term: session.** A group of processes that share one terminal.

- **`echo=0`** turns off the fake terminal's echo. You've already seen
  your line in readline, so without this every line would appear twice.
  (The comment beside it in the code still mentions "socat READLINE", left
  over from an older version.)
- **`stderr`** lets the program's error messages through to your screen.

And one thing left out on purpose: socat's `ctty` option. It needs to open
`/dev/tty`, and that fails inside containers.

Two small bash techniques in this function:

- **`$( … )`** runs a command and captures what it prints. That's
  **command substitution**. It runs the command in a **subshell**, a
  temporary copy of the script, so changes made inside don't reach the
  main script. This detail matters in Part 3.

  > **New term: command substitution / subshell.** `$(cmd)` captures cmd's
  > output; it runs in a throwaway copy of the shell.

- **`local IFS=','`** changes IFS only inside this function, so
  `"${opts[*]}"` joins the options with commas. It's a neat way to join a
  list.

`printf '%q'` is meant to protect arguments containing spaces by adding
backslashes, as bash would. But socat reads the address with **its own
rules**, not bash's, so the protection doesn't work. See
[Part 3, bug 3](03-field-notes-bugs-and-fixes.md#bug-3-an-argument-with-a-space-in-it-gets-split-in-two).

### 4.7 Showing the plan without running it: `--dry-run`

A **dry run** prints what would happen and then stops. `run_dry()`
(P1:328) prints both layers:

> **New term: dry run.** A rehearsal: show the plan without carrying it out.

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

When something doesn't work, try `--dry-run` first.

### 4.8 The main event: `run_socat()`

This function (P1:367–514) builds the picture from §1, runs your typing
session, and then takes it all down again. It happens in eight steps.

#### Step 1: get ready

```bash
histdir=$(dirname "$OPT_HISTFILE")
[[ -d "$histdir" ]] || mkdir -p "$histdir" || warn …   # make the history folder if needed
SAVED_STTY=$(stty -g 2>/dev/null) || true               # save terminal settings for later
```

`|| true` is needed because `stty -g` fails when there's no real terminal
(during automated tests, for example), and strict mode would otherwise
stop the script.

#### Step 2: make the two named pipes, in the right order

```bash
tmpdir=$(mktemp -d)                       # a fresh, empty temporary folder
in_pipe="${tmpdir}/stdin"; out_pipe="${tmpdir}/stdout"
mkfifo "$in_pipe" "$out_pipe"             # create the two named pipes

"${SOCAT_CMD[@]}" 0<"$in_pipe" 1>"$out_pipe" &   # (A) start socat in the background
socat_pid=$!

exec 4>"$in_pipe"      # (B) open the "typing" pipe for writing, as fd 4
exec 5<"$out_pipe"     # (C) open the "output" pipe for reading, as fd 5
rm -rf "$tmpdir"       # (D) delete the folder, pipes and all
```

Recall from Part 0 that **opening a named pipe waits until the other end
is opened too.** That makes the order of these lines important:

1. (A) starts socat's process. Before socat itself runs, the new process
   handles its redirections from left to right. So it first opens
   `in_pipe` for reading, and **waits**.
2. (B) opens `in_pipe` for writing. Both ends are now open, so both sides
   stop waiting.
3. socat's process moves on to `1>"$out_pipe"`, opens it for writing, and
   **waits**.
4. (C) opens `out_pipe` for reading. Both ends are open, both continue, and
   socat starts.

Now imagine swapping (B) and (C). The script would wait at `out_pipe`
while socat's process was still waiting at `in_pipe`. Each would wait for
the other forever. That's called a **deadlock**, and it's why the code
comment says "Order matters". (Exercise 2 lets you see it for yourself.)

> **New term: deadlock.** Two processes each waiting for the other, so
> neither ever moves.

Step (D) uses the other named-pipe fact from Part 0: once a pipe is open,
its name isn't needed. Deleting a file's name is called **unlinking** it.
Doing that straight away means nothing is left in `/tmp`, even if socwrap
is killed abruptly, and no other program can find the pipes by name. On
Linux you can see the pipes still open but marked deleted:

> **New term: unlink.** Remove a file's name. Anything that already has the
> file open can keep using it.

```
/proc/<socwrap's PID>/fd/4 -> /tmp/tmp.1txpf5uxIl/stdin (deleted)
/proc/<socwrap's PID>/fd/5 -> /tmp/tmp.1txpf5uxIl/stdout (deleted)
```

(`/proc` is a folder Linux fills with live information about every
process. `/proc/PID/fd` lists that process's open file descriptors.)

#### Step 3: start the copier

```bash
if [[ -n "$OPT_LOG" ]]; then
    _tee_cmd=(tee -a "$OPT_LOG")                        # copy to the screen AND a log file
    command -v stdbuf >/dev/null && _tee_cmd=(stdbuf -oL tee -a "$OPT_LOG")
    "${_tee_cmd[@]}" <&5 &
else
    cat <&5 &                                           # just copy to the screen
fi
cat_pid=$!
```

The copier runs **in the background**, separately from your typing. That
lets the program's output appear the moment it arrives, even while you're
halfway through a line.

- `cat` copies its input to its output.
- `tee` does the same and also appends a copy to a file (`-a` = append).
- `stdbuf -oL` makes `tee` pass output along **line by line** instead of
  saving up large chunks first. Saving data up before passing it on is
  called **buffering**. Without this, the log file could lag behind.

> **New term: buffering.** Collecting data before passing it on, for
> efficiency. **Line buffering** passes on each complete line. Buffering
> becomes important again in Part 2.

#### Step 4: start the watcher

```bash
(
    while kill -0 "$socat_pid" 2>/dev/null; do sleep 0.05; done
    kill -USR1 $$ 2>/dev/null
) &
monitor_pid=$!
```

The input loop spends almost all its time waiting for you to type. It needs
some way to learn "the other side has gone away". So a small background
process (the **watcher**, called the *monitor* in the code):

- asks every 1/20 of a second, "is socat still running?" `kill -0` sends
  no signal at all. It only checks whether the process exists.
- when socat has gone, sends **SIGUSR1** to the input loop. Inside the
  parentheses, `$$` still means the main script's PID.

A signal arriving while bash is waiting inside `read` interrupts the wait.
That's how the input loop wakes up.

Checking again and again like this is called **polling**.

> **New term: polling.** Repeatedly checking whether something has changed,
> instead of being notified.

Why not simply `wait` for socat? Because a process's exit status can only
be collected once, and the main script needs it at the end. (A subshell
can't collect its parent's children anyway.)

#### Step 5: switch history on

```bash
set -o history
HISTSIZE="$OPT_HISTSIZE"; HISTFILESIZE="$OPT_HISTSIZE"
history -r "$OPT_HISTFILE" 2>/dev/null || true
```

When bash runs a script, history is switched off. It's only meant for
people typing. These lines turn it on, set the maximum number of entries,
and **r**ead the saved history file, so ↑ and Ctrl-R work from the very
first prompt.

#### Step 6: change what Ctrl-C does while you type

```bash
trap 'true' INT               # Ctrl-C: do nothing special (readline clears the line)
local _loop_exit=0
trap '_loop_exit=1' USR1      # SIGUSR1 from the watcher: set a flag
```

The general trap from §4.4 would end socwrap on Ctrl-C. While you're
typing, that would be annoying, so it's replaced with a do-nothing trap.
readline clears your half-typed line and you get a fresh prompt, just as in
bash.

The USR1 trap only sets a **flag**, a variable that records "this has
happened", which the loop checks.

> **New term: flag (variable).** A variable used as an on/off marker.

#### Step 7: the input loop

This is the heart of socwrap:

```bash
set +e                                           # don't stop on errors inside the loop
while true; do
    IFS= read -e -r -p "$OPT_PROMPT" line        # show prompt, let the user edit a line
    rc=$?
    [[ $_loop_exit -eq 1 ]] && break             # the watcher says socat has gone

    if [[ $rc -eq 0 ]]; then                     # got a line
        [[ -n "$line" ]] && history -s "$line"   # add it to history (if not empty)
        printf '%s\n' "$line" >&4 || break       # send it into the pipe
        sleep 0.05                               # give the reply time to print
        [[ $_loop_exit -eq 1 ]] && break
        kill -0 "$cat_pid" 2>/dev/null || break  # copier gone = program finished
    elif [[ $rc -eq 130 ]]; then
        continue                                 # Ctrl-C: just show a fresh prompt
    else
        break                                    # Ctrl-D or another reason to stop
    fi
done
set -e
```

The `read` line does most of the work:

| Part | Meaning |
|------|---------|
| `read … line` | Read one line into the variable `line`. |
| `-e` | Use **readline**. This is the key to the whole project. |
| `-p "$OPT_PROMPT"` | Show this prompt. Because readline draws it, the prompt redraws correctly while you edit or search. |
| `-r` | Take backslashes literally. `\n` stays as those two characters. |
| `IFS=` | Keep spaces at the start and end of the line. Indented Python has to arrive intact. |

`read` returns a status:

- **0**: a line was read.
- **130**: interrupted by Ctrl-C (128 + 2).
- **anything else**: usually Ctrl-D (EOF), or a signal such as the
  watcher's SIGUSR1.

Around it:

- **`set +e` … `set -e`** pauses strict mode for the loop. `read` returning
  non-zero is normal here (Ctrl-D does it), and strict mode would end the
  script before the history had been saved.
- **`history -s`** adds the line to history without running it.
- **`>&4`** writes into the typing pipe. If socat has gone, the write
  fails and the loop ends.
- **`sleep 0.05`** is a practical workaround for a **race condition**.
  After a quick command like `pwd`, the reply and the next prompt compete
  to reach the screen first. If the prompt wins, the reply appears after
  it and looks misplaced. Waiting 1/20 s usually lets the reply win. It's
  a **heuristic**: it works most of the time, and a slow network server
  can still lose the race.

  > **New term: race condition.** A bug or glitch that depends on which of
  > two things happens first.
  >
  > **New term: heuristic.** A rule of thumb that usually works but isn't
  > guaranteed.

- **Why check the copier instead of socat?** When the program exits (you
  typed `exit`), socat closes the output pipe at once, so the copier
  reaches EOF and stops. socat itself may stay alive a moment longer. "The
  copier has stopped" is therefore the quicker sign that the session is
  over, and it saves you seeing a dead prompt and typing `exit` twice.

#### Step 8: take it all down

After the loop the script **tears down** everything it set up: it saves,
closes and stops things in a sensible order.

> **New term: teardown.** Undoing setup at the end: closing connections,
> stopping helpers, saving state.

```bash
trap 'exit 130' INT;  trap - USR1          # put the general traps back
history -w "$OPT_HISTFILE" 2>/dev/null || true   # write history to disk
set +o history
exec 4>&-                                   # close the typing pipe → socat should see EOF…
wait "$socat_pid" 2>/dev/null; rc=$?        # …then collect socat's exit status
exec 5>&-                                   # close the output pipe
kill "$cat_pid" "$monitor_pid" 2>/dev/null || true   # stop the helpers
wait "$cat_pid" 2>/dev/null || true
case $rc in 0) … ;; 1) warn … ;; 2) warn … ;; esac   # explain socat's exit status
return $rc
```

The plan: save history, then close the typing pipe so socat gets EOF,
passes it on to the program, and everything shuts down in turn.

Three of these lines don't work quite as intended. Part 3 covers each one;
the short versions are:

- **`exec 4>&-` doesn't produce EOF.** The copier and watcher were started
  after fd 4 was opened, so each has its own copy (Part 0: children inherit
  fds). The pipe stays open.
  → [Bug 1](03-field-notes-bugs-and-fixes.md#bug-1-ctrl-d-hangs-until-the-other-side-hangs-up)
- **`wait …; rc=$?` under strict mode.** If socat failed, the script stops
  at `wait` and never gets to `rc=$?`.
  → [Bug 4](03-field-notes-bugs-and-fixes.md#bug-4-when-socat-fails-socwrap-skips-its-clean-up-and-advice)
- **`trap - USR1`** resets USR1 to its default, which is "stop". A late
  signal from the watcher can then kill socwrap in the middle of shutting
  down.
  → [Bug 6](03-field-notes-bugs-and-fixes.md#bug-6-a-late-sigusr1-can-stop-socwrap-while-it-shuts-down)

### 4.9 Reading the command line

`parse_args()` (P1:625–681) turns what you typed into settings. It uses a
standard tool called **getopt**, which understands both short options
(`-p "x> "`) and long ones (`--prompt "x> "`).

> **New term: getopt.** A tool that tidies up a program's command-line
> options so a script can go through them one at a time.

```bash
getopt --test >/dev/null 2>&1 || getopt_rc=$?
[[ $getopt_rc -ne 4 ]] && warn "util-linux getopt not found …"
```

There are two versions of `getopt`. Only the Linux one (from a package
called util-linux) understands long options, and it answers `--test` with
exit status **4**. That's how the script tells them apart.

```bash
parsed=$(getopt --options "H:n:p:l:dDvVh" \
                --longoptions "history:,histsize:,prompt:,log:,dry-run,detect,no-pty,verbose,version,help" \
                --name socwrap -- "$@")
eval set -- "$parsed"
```

- In `"H:n:p:…"` each letter is a short option. A `:` after a letter means
  it takes a value (`-H FILE`).
- getopt rewrites the command line in a tidy standard order: options
  first, each value separate and quoted, then `--`, then everything else.
- `eval set -- "$parsed"` loads that tidy version back in as the script's
  arguments.

Then a simple loop goes through them. `case "$1" in` checks the current
option and `shift` moves on to the next. Whatever follows `--` becomes
`WRAP_TARGET`, the program to wrap.

### 4.10 `main()`: the running order

```
read the command line
  → asked for --detect?  print the report and stop
  → no program given?    print help and stop
  → asked for --verbose? print extra details to stderr
  → preflight checks
  → build the socat command
  → asked for --dry-run? print the plan and stop
  → run_socat: the real session
```

Both `--detect` and `--dry-run` stop before anything is started, so they're
always safe to try.

---

## 5. PTY or no PTY?

This question confuses people most, so here it is on its own.

```bash
# Looks wrong: bash's own prompt ("bash-5.2$ ") appears beside socwrap's "bash> "
bash phase1/socwrap.sh -p "bash> " -- /bin/bash

# Recommended for shells
bash phase1/socwrap.sh --no-pty -p "bash> " -- /bin/bash --norc --noprofile

# Also works: keep the PTY but give bash an empty prompt
bash phase1/socwrap.sh -p "bash> " -- env PS1='' /bin/bash --norc --noprofile
```

With a PTY, the wrapped bash thinks a person is typing, so it shows its own
prompt (a variable called `PS1`) next to socwrap's. With `--no-pty`, bash
sees a plain pipe, assumes it's reading a script, and shows no prompt.
socwrap's readline does all the editing.

| Wrapping… | Use |
|-----------|-----|
| a shell: `bash`, `sh`, `zsh` | `--no-pty` (or a PTY with `PS1=''`) |
| a program that only prompts on a terminal: `python3`, `sqlite3` | the default (PTY on) |
| a simple line-by-line tool: `cat`, `bc -q`, `ed` | either |

---

## 6. How the project tests itself

The project checks itself with **automated tests**: scripts that run
socwrap in many ways and compare what happens with what should happen.

> **New term: automated test / test suite.** A script that checks the
> program behaves correctly. A **test suite** is a collection of them.

- `lib/test_lib.sh` is a small shared toolkit. `describe` names a group of
  tests, and `assert_eq`, `assert_contains` and friends each check one
  thing.
- Results come out in **TAP** (Test Anything Protocol), a simple
  line-by-line format (`ok 1 - …` / `not ok 2 - …`) that other tools can
  read.
- Each phase has its own suite, and later suites **re-run** the earlier
  ones against the newer script. So Phase 2 can't quietly break a Phase 1
  feature.

```bash
bash lib/test_lib.sh --self-test        # check the toolkit itself
bash phase1/tests/test_phase1.sh        # 51 tests
bash phase1/tests/test_phase1.sh --tap  # TAP output
```

On the reference machine, Phase 1 passes **51 of 51**. Most tests look at
`--dry-run` and `--detect` output. The live-session behaviour is harder to
automate, so it's described as manual steps in `tests/MANUAL_TESTS.md`.
Part 3 shows what that leaves uncovered.

---

## 7. Exercises

1. **See the five processes.** Run
   `bash phase1/socwrap.sh -H /tmp/h -- python3 -q` in one terminal. In a
   second terminal:
   ```bash
   pid=$(pgrep -f 'H /tmp/h -- python3' | head -1)
   ps -o pid,ppid,comm,args --forest -g "$(ps -o sid= -p "$pid" | tr -d ' ')"
   ls -l /proc/$pid/fd | grep deleted
   ```
   Match each line to a box in the picture in §1, and find the two deleted
   named pipes.

2. **Cause a deadlock on purpose.** Copy the script, swap the
   `exec 4>` and `exec 5<` lines, and run the copy. It hangs before showing
   a prompt. Using [step 2](#step-2-make-the-two-named-pipes-in-the-right-order),
   explain why.

3. **Ctrl-C versus Ctrl-D.** Type half a line and press Ctrl-C: the line is
   cleared and the session carries on. Now press Ctrl-D on an empty line.
   Which trap or `read` status explains each?

4. **Watch the race.** Wrap `bash --norc` with `--no-pty` and run `pwd` a
   few times. Then change `sleep 0.05` to `sleep 0` in a copy. How often
   does the output now appear after the prompt?

5. **History limits.** Run with `-H /tmp/myhist -n 3`, type five commands,
   and exit. Look at `/tmp/myhist`. Why are there only three lines?

6. **Double echo.** In a copy, delete `echo=0` from `build_exec_addr` and
   wrap `python3 -q`. Every line now shows twice. Which part of the system
   prints each copy?

---

## 8. What you now know

- socwrap is **two layers**: bash's `read -e` (readline) for typing, and
  socat for transport.
- They're joined by **two named pipes**, opened in a careful order to
  avoid a **deadlock**, then **unlinked**.
- **Five processes** cooperate: the input loop, socat, the wrapped program,
  the copier and the watcher.
- The watcher **polls** socat and sends **SIGUSR1** to wake the input loop
  when it's gone.
- Traps turn Ctrl-C into "clear this line", and history is switched on by
  hand and saved at **teardown**.
- Use **`--no-pty`** for shells and a **PTY** for programs that only prompt
  on a terminal.

**Next: [Part 2, network connections and other modes (Phase 2)](02-phase2-transport-modes.md)**
