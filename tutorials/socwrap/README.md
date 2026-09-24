# socwrap deep dive: phases 1 and 2

`socwrap` puts a readline prompt (line editing, arrow-key history, Ctrl-R,
history saved to disk) in front of anything interactive: a local REPL, a raw
TCP socket, a UDP service, a Unix socket, an SSH session, a telnet box or a
chroot shell. It has no `rlwrap` dependency and does not need a socat built
with readline.

This tutorial follows the code of the first two phases:

| Part | File | You will learn |
|------|------|----------------|
| 1 | [01-phase1-core-bridge.md](01-phase1-core-bridge.md) | The two-layer architecture: FIFOs, the five processes, the `read -e` loop, signals, history and teardown |
| 2 | [02-phase2-transport-modes.md](02-phase2-transport-modes.md) | How phase 2 adds TCP, TLS, UDP, Unix, SSH, Telnet and chroot without changing the core loop: two-pass argument parsing, address builders and the telnet IAC scrubber |
| 3 | [03-field-notes-bugs-and-fixes.md](03-field-notes-bugs-and-fixes.md) | Six bugs and a list of smaller issues found while writing parts 1 and 2, each with a reproduction; tested patches for the six |
| Labs | [labs/](labs/) | `lab-servers.sh`: throwaway local TCP, UDP, Unix, TLS and fake-telnet servers to point socwrap at |
| Patches | [patches/](patches/) | `git apply`-ready fixes for the bugs in part 3 (core fixes, plus an optional argv-quoting fix) |

## Before you start

**Source version.** Line numbers refer to socwrap commit
`08ec3b73579967faf2fae75f2f09318226f916e9` (`phase1/socwrap.sh`, 730 lines;
`phase2/socwrap.sh`, 1,156 lines). If the file has changed since, search for
the function name.

**What you need.**

```bash
bash --version | head -1        # 4.0 or later
socat -V | head -2              # any recent build; readline support not needed
getopt --test; echo $?          # must print 4 (util-linux getopt)
command -v jq perl openssl      # optional, but the labs use them
```

**Getting the code.**

```bash
git clone https://github.com/That-Guy-40/socwrap
cd socwrap
bash phase1/socwrap.sh --detect
```

**Conventions.** `P1` means `phase1/socwrap.sh` and `P2` means
`phase2/socwrap.sh`. `P1:367` means line 367 of the phase 1 script.
Everything shown as output was captured from real runs (bash 5.2.21, socat
1.8.0.0, Linux x86_64).

## The one-paragraph version

bash's `read -e` builtin is GNU readline, so a plain `while read -e` loop gets
editing, history and Ctrl-R for free. The script starts `socat - <TARGET>` in
the background, with its stdin and stdout connected to two named pipes. Each
line you type is written into the first pipe. A background `cat` copies the
second pipe to your terminal. A small monitor process sends `SIGUSR1` when
socat dies, which breaks the loop. Phase 2 keeps that loop exactly as it is.
It only changes the `<TARGET>` string (`TCP:…`, `OPENSSL:…`, `UDP:…`,
`UNIX-CONNECT:…`, `EXEC:ssh …`, `EXEC:chroot …`) and, for telnet, puts a
filter between the output pipe and your screen.
