# socwrap deep dive: phases 1 and 2

`socwrap` gives any line-by-line program the comforts you're used to in
bash: arrow keys to edit what you're typing, ↑ to bring back earlier
commands, Ctrl-R to search them, and a history that's still there next
time. It works for a local program (`python3`, `sqlite3`), a network
service, a remote login or a locked-down shell. It needs only bash and a
tool called socat.

This tutorial explains how the first two phases work, down to individual
lines of code. **You don't need to know the jargon beforehand.** Each
technical word is explained in plain language the first time it appears,
and after that it's used freely, so the vocabulary grows as you go.

## The route

| Part | File | What you'll learn | New words (examples) |
|------|------|-------------------|----------------------|
| 0 | [00-building-blocks.md](00-building-blocks.md) | The ideas everything else depends on, explained with everyday comparisons | process, stdin/stdout, file descriptor, pipe, signal, PTY, TCP/UDP, socat |
| 1 | [01-phase1-core-bridge.md](01-phase1-core-bridge.md) | Phase 1, line by line: how bash and socat are joined, the five cooperating processes, and how it all shuts down | strict mode, subshell, deadlock, polling, race condition, teardown |
| 2 | [02-phase2-transport-modes.md](02-phase2-transport-modes.md) | Phase 2: connecting to TCP, TLS, UDP, Unix sockets, SSH, telnet and chroot, all without touching Phase 1's core | mode, dispatch, datagram, chroot, IAC, negotiation, regex |
| 3 | [03-field-notes-bugs-and-fixes.md](03-field-notes-bugs-and-fixes.md) | Six real bugs found while writing this, each with a way to reproduce it, a tested fix, and the lesson behind it | reproduce, patch, errno, regression test |
| | [GLOSSARY.md](GLOSSARY.md) | Every term, in alphabetical order, linked back to where it's explained | |
| | [labs/](labs/) | `lab-servers.sh`: practice servers (TCP, UDP, Unix, TLS, pretend telnet) on your own machine | |
| | [patches/](patches/) | The Part 3 fixes, ready to apply with `git apply` | |

**Where to start:**

- New to Linux internals? Start at **Part 0** and go in order.
- Comfortable with processes, pipes and file descriptors? Skim Part 0's
  headings, then start at **Part 1**.
- Just want the bugs? Go to **Part 3**. It links back to the explanations
  it relies on.

## What you need

- A Linux machine (or a Linux virtual machine or container).
- `bash` version 4 or later: check with `bash --version`.
- `socat`: install it with your package manager (`sudo apt install socat`
  on Debian or Ubuntu).
- Optional but used in the labs: `jq`, `perl`, `openssl`.

```bash
git clone https://github.com/That-Guy-40/socwrap
cd socwrap
bash phase1/socwrap.sh --detect        # checks your machine is ready
```

## Notes on accuracy

- Line numbers such as `P1:367` (Phase 1, line 367) refer to socwrap commit
  `08ec3b73579967faf2fae75f2f09318226f916e9`. If the code has moved on,
  search for the function name instead.
- Every output shown was captured from a real run (bash 5.2.21, socat
  1.8.0.0, Linux).

## The short version

bash has a built-in command, `read -e`, that reads a line using readline,
the same editing engine bash itself uses. socwrap runs that in a loop. Each
line you finish is written into a **named pipe** leading to **socat**, and
socat passes it on to the program or server. Replies come back through a
second named pipe, and a small background helper copies them to your
screen. Another helper notices when the other side goes away and wakes up
the loop.

Phase 2 keeps all of that exactly as it was and only changes what socat
connects to.

If some of those words were unfamiliar, that's what Part 0 is for.
