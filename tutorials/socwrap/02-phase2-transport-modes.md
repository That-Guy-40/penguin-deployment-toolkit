# Part 2: Phase 2, network connections and other modes

Phase 1 could only wrap a program running on your own machine. Phase 2
lets socwrap talk to network services, remote logins and locked-down
shells too. The script grows from 730 to 1,156 lines, but the central idea
is simple:

> **The input loop from Part 1 doesn't change. Only the socat address on
> the right-hand side does.**

```
socat  -  EXEC:python3,pty,…          # Phase 1: a local program
socat  -  TCP:host:80,…               # Phase 2: a TCP connection
socat  -  OPENSSL:host:443,…          #          TCP + TLS encryption
socat  -  UDP:host:514,…              #          UDP
socat  -  UNIX-CONNECT:/run/app.sock  #          a Unix socket
socat  -  EXEC:ssh user@host,pty,…    #          an SSH login
socat  -  TCP:router:23,…  + cleaner  #          telnet
socat  -  EXEC:chroot /srv /bin/sh,…  #          a shell inside a chroot
```

**Words from earlier parts used here:** host, port, socket, TCP, UDP, Unix
socket, handshake, connect timeout, TLS, certificate, protocol, CRLF, SSH,
telnet (all [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes));
socat address and address options ([Part 0 §11](00-building-blocks.md#11-socat-the-universal-adapter));
option, array, function, subshell, buffering, flag
([Part 1](01-phase1-core-bridge.md)). The [glossary](GLOSSARY.md) has them
all.

Line numbers look like `P2:402`, meaning line 402 of `phase2/socwrap.sh`.

- [1. Modes: one switch, seven settings](#1-modes-one-switch-seven-settings)
- [2. What changed from Phase 1](#2-what-changed-from-phase-1)
- [3. Reading the command line in two passes](#3-reading-the-command-line-in-two-passes)
- [4. Checks for each mode](#4-checks-for-each-mode)
- [5. Building the address for each mode](#5-building-the-address-for-each-mode)
- [6. Telnet and its hidden control codes](#6-telnet-and-its-hidden-control-codes)
- [7. Choosing the builder, running, and reporting the result](#7-choosing-the-builder-running-and-reporting-the-result)
- [8. `--detect` and `--dry-run` in Phase 2](#8---detect-and---dry-run-in-phase-2)
- [9. Labs: try every mode on one machine](#9-labs-try-every-mode-on-one-machine)
- [10. What you now know](#10-what-you-now-know)

---

## 1. Modes: one switch, seven settings

Phase 2 introduces **modes**. A mode says what kind of thing socwrap is
connecting to. You choose it with an option, and only one is allowed at a
time:

> **New term: mode.** The kind of target socwrap connects to. Stored in the
> variable `OPT_MODE`, which the rest of the script checks to decide what
> to do.

| Mode | Option | Connects to | Good for |
|------|--------|-------------|----------|
| `exec` | `-- CMD` | a program on this machine (Phase 1) | REPLs, shells |
| `tcp` | `-t HOST PORT` | a TCP service | web, email and other text protocols by hand |
| `tcp` + TLS | `--tls -t HOST PORT` | an encrypted TCP service | HTTPS, secure email |
| `udp` | `-u HOST PORT` | a UDP service | logging (syslog), DNS experiments |
| `unix` | `-U PATH` | a Unix socket | local service control sockets |
| `ssh` | `-s USER@HOST` | an SSH login | keeping local history for a remote machine |
| `telnet` | `-T HOST PORT` | a telnet service, with its control codes removed | routers, lab equipment |
| `chroot` | `-c DIR` | a shell inside a chroot (§5.6) | working inside a sealed-off folder tree |

Each mode has its own settings (P2:45–96):

```bash
OPT_MODE="exec"                 # which mode
OPT_HOST=""  OPT_PORT=""        # tcp, udp, telnet
OPT_UNIX_SOCK=""                # unix
OPT_SSH_TARGET="" OPT_SSH_OPTS=""
OPT_CHROOT_DIR="" OPT_CHROOT_SHELL="/bin/sh"
OPT_IAC_SCRUB=1                 # telnet: remove control codes (on by default)
OPT_CRLF=0                      # tcp/udp: turn LF into CRLF (off by default)
OPT_TLS=0 OPT_TLS_VERIFY=1      # tcp: TLS off; if on, check the certificate
OPT_TIMEOUT=10                  # connect timeout, in seconds
```

---

## 2. What changed from Phase 1

| Area | Phase 1 | Phase 2 |
|------|---------|---------|
| Modes | `exec` only | seven (see above) |
| Reading options | `getopt` only | a hand-written **first pass**, then `getopt` (§3) |
| Address building | one function | one **builder** function per mode (§5) |
| Output path | copier (`cat` / `tee`) | the same, plus a **cleaner** for telnet (§6) |
| `--detect` | socat, bash, jq | + TLS support, perl, ssh, and which modes will work |
| Pre-run checks | bash, socat | + checks for each mode (§4) |
| New options | | `-t -u -U -s -T -c`, `--tls`, `--no-tls-verify`, `--timeout`, `--ssh-opts`, `--no-iac-scrub`, `-C/--crlf` |

The big thing that **didn't** change is `run_socat()`, the input loop and
teardown from Part 1. It's nearly identical. The only edit is where the
copier is started, so the telnet cleaner can go in front of it. You can
check this yourself by comparing the two files with indentation ignored:

```bash
diff <(sed 's/^ *//' phase1/socwrap.sh) <(sed 's/^ *//' phase2/socwrap.sh) | less
```

That's the payoff of Phase 1's design: new kinds of connection didn't
require touching the tricky part.

---

## 3. Reading the command line in two passes

`getopt` (Part 1 §4.9) handles options that take **one** value, like
`-p "x> "`. But `-t HOST PORT` takes **two**, which getopt can't do. So
Phase 2 reads the command line twice:

1. **First pass (by hand):** find the mode options, take their values, and
   set them aside.
2. **Second pass (getopt):** handle everything else exactly as in Phase 1.

> **New term: parsing / pass.** *Parsing* means reading text and working
> out its structure. A *pass* is one read-through. "Two-pass parsing" reads
> the input twice, taking something different each time.

The first pass (P2:967–1041), simplified:

```bash
remaining_args=()                          # whatever getopt will see afterwards
args=("$@")                                # all the arguments, as an array
while [[ $i -lt $argc ]]; do
    arg=${args[$i]}; next=${args[$i+1]}; next2=${args[$i+2]}
    case "$arg" in
        -t)  _set_mode tcp
             if [[ "$next" == *":"* ]]; then       # written as  -t host:port
                 OPT_HOST="${next%:*}"; OPT_PORT="${next#*:}"; skip 2
             else                                  # written as  -t host port
                 OPT_HOST="$next";      OPT_PORT="$next2";     skip 3
             fi ;;
        -u)  …same, mode udp…
        -T)  …same, mode telnet…
        -U)  _set_mode unix;   OPT_UNIX_SOCK="$next";  skip 2 ;;
        -s)  _set_mode ssh;    OPT_SSH_TARGET="$next"; skip 2 ;;
        -c)  _set_mode chroot; OPT_CHROOT_DIR="$next"; skip 2 ;;
        --ssh-opts) OPT_SSH_OPTS="$next"; skip 2 ;;
        *)   remaining_args+=("$arg"); skip 1 ;;   # not ours: keep for getopt
    esac
done
set -- "${remaining_args[@]}"              # hand the rest to the second pass
```

Things to notice:

- **Two ways to write host and port.** `-t example.com 80` and
  `-t example.com:80` both work. `${next%:*}` means "everything before the
  **last** colon" and `${next#*:}` means "everything after the **first**
  colon". For `example.com:80` both give the right answer. For an IPv6
  address such as `::1` (the newer style of address, full of colons) they
  don't, so write IPv6 hosts in the two-word form.
- **Only one mode.** `_set_mode` stops with an error if a mode has already
  been chosen, so `-t a 1 -u b 2` is rejected.
- **After both passes** (P2:1113–1119): `--tls` without `-t` is an error,
  and if `--ssh-opts` wasn't given, the `SOCWRAP_SSH_OPTS` environment
  variable is used instead.

The first pass has one real flaw: **it doesn't stop at `--`.** It checks
every word, including the ones meant for the wrapped program. So
`-- bash -c 'echo hi'` is read as "chroot mode, directory `echo hi`". See
[Part 3, bug 2](03-field-notes-bugs-and-fixes.md#bug-2-options-meant-for-the-wrapped-program-get-grabbed-by-socwrap).

---

## 4. Checks for each mode

`preflight()` (P2:318–367) runs Phase 1's checks, then checks the chosen
mode:

| Mode | Stops with an error if… | Just warns if… |
|------|-------------------------|----------------|
| `tcp`, `telnet` | host or port missing; port isn't a number from 1 to 65535; `--tls` used but socat was built without TLS | |
| `udp` | host or port missing; port isn't a number | *(no 1–65535 check)* |
| `unix` | no path given | the socket file doesn't exist **yet** |
| `ssh` | no target; the `ssh` program isn't installed | |
| `chroot` | no directory, or it isn't a directory | you aren't the administrator (root) |
| `exec` | no program after `--` | |

Two of these only warn, deliberately:

- **Unix socket missing:** some services create their socket file only
  when first needed, and you might start socwrap before the service.
- **Chroot without root:** normally only the administrator account,
  **root**, may use chroot. There are special ways round that for testing,
  so socwrap lets you try.

> **New term: root.** The administrator account on Linux, allowed to do
> anything. `sudo` runs one command as root.

---

## 5. Building the address for each mode

Each mode has a **builder**: a function that prints the socat address for
that mode. Part 1's `build_exec_addr` was the first one. Builders are
called with `$( … )` (command substitution), which captures what they
print.

> **New term: builder (function).** A function whose only job is to put
> together a piece of text, here a socat address.

### 5.1 TCP and TLS: `build_tcp_addr` (P2:402)

```bash
if [[ "$OPT_TLS" -eq 1 ]]; then
    addr="OPENSSL:${OPT_HOST}:${OPT_PORT}"       # TCP with TLS encryption
    opts=("connect-timeout=${OPT_TIMEOUT}")
    [[ "$OPT_TLS_VERIFY" -eq 0 ]] && opts+=("verify=0")   # don't check the certificate
else
    addr="TCP:${OPT_HOST}:${OPT_PORT}"           # plain TCP
    opts=("connect-timeout=${OPT_TIMEOUT}")
fi
[[ "$OPT_CRLF" -eq 1 ]] && opts+=("crlf")      # send CRLF line endings
```

What comes out, from real `--dry-run` runs:

```console
$ socwrap.sh --dry-run -t 10.0.0.5:8080 -C
      "TCP:10.0.0.5:8080,connect-timeout=10,crlf"
$ socwrap.sh --dry-run --tls --no-tls-verify -t 10.0.0.5 8443
      "OPENSSL:10.0.0.5:8443,connect-timeout=10,verify=0"
```

In plain words:

- **`connect-timeout=10`**: give up if the TCP handshake takes more than
  10 seconds. After you're connected there's no time limit.
- **`crlf`** (the `-C` option): socat changes each line ending you send
  from LF to **CRLF**, which web and email servers expect. This was checked
  on a real connection: typing `a` then `b` sent exactly
  `a \r \n b \r \n`.
- **`OPENSSL`** is socat's name for a TLS connection. **`verify=0`**
  (`--no-tls-verify`) skips the certificate check. Without it, a server
  using a self-signed certificate is refused with
  `certificate verify failed`. Only skip the check for machines you control
  or test labs.
- TLS isn't a mode of its own. It's a variation of `tcp`, and `--dry-run`
  still says `Mode: tcp`.

### 5.2 UDP: `build_udp_addr` (P2:423)

```
UDP:10.0.0.5:514,connect-timeout=10
```

Each line you type is sent as one UDP message (a **datagram**), and
replies come back the same way. UDP has no handshake, so
`connect-timeout` has nothing to time. And as with postcards, nothing tells
you if nobody is there: you usually just get silence.

> **New term: datagram.** A single, self-contained UDP message.

### 5.3 Unix sockets: `build_unix_addr` (P2:437)

```
UNIX-CONNECT:/run/app.sock
```

Many local services offer a control socket like this: process managers,
Docker, database servers. One limit to know: Linux only allows socket paths
up to 108 characters long. socat reports
`unix socket address 109 characters long, max length is 108` if you go
over.

### 5.4 SSH: `build_ssh_addr` (P2:446)

```bash
ssh_cmd=(ssh)
if [[ -n "$OPT_SSH_OPTS" ]]; then
    extra_opts=($OPT_SSH_OPTS)          # meant to split "-p 2222" into two words
    ssh_cmd+=("${extra_opts[@]}")
fi
ssh_cmd+=("$OPT_SSH_TARGET")
cmd_str=$(printf '%q ' "${ssh_cmd[@]}")
printf '%s,%s' "EXEC:${cmd_str% }" "pty,setsid,echo=0,stderr"
```

```console
$ socwrap.sh --dry-run --ssh-opts "-p 2222" -s admin@10.0.0.1
      "EXEC:ssh -p\ 2222 admin@10.0.0.1,pty,setsid,echo=0,stderr"
```

SSH mode is really **exec mode with `ssh` as the program**. It always uses
a PTY, because `ssh` only asks the remote machine for a proper terminal
session when its own input is a terminal, and password prompts need one
too.

What you get:

- **Local history for a remote machine.** Give each server its own history
  file (`-H ~/.hist_router1`) and ↑ brings back what you typed there last
  week.
- **Two histories.** The remote shell keeps its own history as usual.
  socwrap's is an extra one on your side.
- **Nothing is sent until you press Enter.** That's the nature of a line
  editor: Tab completion happens locally, not on the remote machine, and
  full-screen programs such as `vim` or `top` won't work properly.

Look closely at `-p\ 2222` above. Part 1 §4.1 explained that this script
removed *space* from IFS, so `($OPT_SSH_OPTS)` **doesn't** split
`-p 2222` into two words. Instead, `printf '%q'` puts a backslash before
the space. It still works, but **by accident**: socat splits on spaces
itself and ignores the backslash. (Tested with a stand-in `ssh` that prints
what it receives: `[-p] [2222] [admin@10.0.0.1]`.) One consequence: no
shell is involved, so `~` isn't expanded. Write `$HOME/.ssh/key` rather
than `~/.ssh/key`. More in
[Part 3, bug 3](03-field-notes-bugs-and-fixes.md#bug-3-an-argument-with-a-space-in-it-gets-split-in-two).

Because `pty` is written into this builder, **`--no-pty` has no effect in
SSH mode** (or chroot mode), even though `--help` says it does.

### 5.5 Telnet: `build_telnet_addr` (P2:474)

```bash
build_telnet_addr() { build_tcp_addr; }
```

The connection itself is just TCP. The difference is what happens to the
**output** before you see it, covered in §6.

### 5.6 Chroot: `build_chroot_addr` (P2:482)

**chroot** ("change root") runs a program that sees one folder as the whole
filesystem. If you chroot into `/srv/jail`, the program sees
`/srv/jail/bin/sh` as `/bin/sh` and can't reach anything outside
`/srv/jail`. People call that folder a **chroot jail**. It's used for
repairing broken systems, building software in a clean environment, and
training labs.

> **New term: chroot / chroot jail.** Running a program so a chosen folder
> looks like the top of the whole filesystem to it.

```bash
shell="${OPT_CHROOT_SHELL:-/bin/sh}"
if [[ ${#WRAP_TARGET[@]} -gt 0 ]]; then      # a shell was named after the folder
    shell=$(printf '%q ' "${WRAP_TARGET[@]}"); shell="${shell% }"
fi
cmd_str=$(printf 'chroot %q %s' "$OPT_CHROOT_DIR" "$shell")
printf '%s,%s' "EXEC:${cmd_str}" "pty,setsid,echo=0,stderr"
```

```console
$ sudo socwrap.sh -c /srv/jail                      # runs /bin/sh inside the jail
      "EXEC:chroot /srv/jail /bin/sh,pty,setsid,echo=0,stderr"
$ sudo socwrap.sh -c /srv/jail -- /bin/bash -l      # a different shell, with an option
      "EXEC:chroot /srv/jail /bin/bash -l,pty,setsid,echo=0,stderr"
```

Two practical points:

- The shell is looked for **inside** the jail, so `/srv/jail/bin/sh` and
  everything it needs must be there.
- Put `--` before the shell if you give it options. Without it,
  `-c /srv/jail /bin/bash -l` fails with `option requires an argument --
  'l'`, because socwrap takes `-l` as its own `--log` option.

---

## 6. Telnet and its hidden control codes

### 6.1 What telnet mixes into its text

telnet (from 1969!) sends **control codes** in the middle of normal text.
They let the two ends agree on settings such as "you do the echoing" or
"tell me your terminal type". Agreeing settings like this is called
**negotiation**.

> **New term: negotiation.** Two programs agreeing on settings at the start
> of a conversation.

Each control code starts with a special byte, 255 (written `0xFF` in
**hexadecimal**, the base-16 counting system programmers use for bytes).
That byte is called **IAC**, "Interpret As Command". It means "the next
byte or two are instructions, not text".

> **New term: byte / hexadecimal.** A byte is one unit of data, a number
> from 0 to 255. Hexadecimal writes those numbers with 16 digits (0–9,
> A–F): 255 is `FF` and 251 is `FB`. `0x` in front just means "this is
> hex".
>
> **New term: IAC.** Byte `0xFF`: in telnet, "a command follows".

The common commands:

| Bytes | Meaning in plain words |
|-------|------------------------|
| `FF FB xx` | IAC **WILL** xx: "I'd like to turn on setting xx" |
| `FF FC xx` | IAC **WONT** xx: "I won't use setting xx" |
| `FF FD xx` | IAC **DO** xx: "please turn on setting xx" |
| `FF FE xx` | IAC **DONT** xx: "please don't use setting xx" |
| `FF FA … FF F0` | IAC **SB** … IAC **SE**: a longer message about one setting (**subnegotiation**) |
| `FF F1` to `FF F9` | short two-byte commands (rarely seen) |
| `FF FF` | a real 255 in the text, doubled so it isn't read as a command |

Common settings include `01` (echo), `03` (suppress go-ahead, a fossil you
can ignore) and `18` hex (terminal type). A plain TCP client prints these
bytes as junk such as `���` in front of a router's welcome message.

### 6.2 socwrap's approach: remove them, don't answer them

socwrap doesn't take part in the negotiation. It just **removes** the
codes from the output before you see them. The function `iac_scrub_cmd()`
(P2:511) produces a command that does this. The code calls it a
**scrubber**; we've been calling it the **cleaner**.

> **New term: filter.** A program that reads text in, changes it, and
> writes it out. The telnet cleaner (scrubber) is a filter.

```bash
if [[ "$OPT_IAC_SCRUB" -eq 0 ]]; then printf 'cat'; return; fi   # --no-iac-scrub: no cleaning
if _has_perl; then
    printf '%s' 'perl -pe '"'"'s/\xff[\xfb-\xfe][\x00-\xff]//g; s/\xff[\xf0-\xfa]//g; s/\xff\xff/\xff/g'"'"
else
    printf "sed 's/\\^\\[\\[[0-9;]*[mGKHFABCDJMPST]//g'"            # fallback without perl
    warn "perl not available — IAC scrubbing limited…"
fi
```

The strange `'"'"'` is a bash trick for putting a single quote inside a
single-quoted string. The command it produces is:

```
perl -pe 's/\xff[\xfb-\xfe][\x00-\xff]//g; s/\xff[\xf0-\xfa]//g; s/\xff\xff/\xff/g'
```

**perl** is a programming language that's very good at text work, and it's
installed almost everywhere. `s/PATTERN//g` means "delete every match of
PATTERN". The patterns are **regular expressions**, a mini-language for
describing text: `\xff` means byte FF, and `[\xfb-\xfe]` means any byte
from FB to FE.

> **New term: regular expression (regex).** A pattern that describes text
> to search for, such as "FF followed by any byte from FB to FE".

The three rules, in order:

1. `FF` + (`FB` to `FE`) + any byte: remove WILL, WONT, DO and DONT with
   their setting.
2. `FF` + (`F0` to `FA`): remove the two-byte commands, including the SB
   and SE markers.
3. `FF FF` → `FF`: turn a doubled 255 back into a single one.

The code that starts the copier (P2:713–721) puts this filter in front:

```bash
if [[ "$OPT_MODE" == "telnet" ]]; then
    scrub_cmd=$(iac_scrub_cmd)
    if [[ -n "$OPT_LOG" ]]; then eval "$scrub_cmd" <&5 | "${_tee_cmd[@]}" &
    else                         eval "$scrub_cmd" <&5 &
    fi
fi
```

`eval` means "run this text as a command". It's needed because the
cleaner command is stored as text in a variable. The output path becomes:

```
socat → output pipe → fd 5 → perl cleaner → (tee to log) → your screen
```

### 6.3 How well it works

This was tested against the lab's pretend telnet server
([§9](#9-labs-try-every-mode-on-one-machine)), which sends WILL ECHO, WILL
SUPPRESS-GO-AHEAD and a terminal-type subnegotiation before its welcome
message. The raw bytes, shown as numbers:

```
without cleaning: 377 373 001 377 373 003 377 372 030 001 377 360  W e l c o m e …
with cleaning:                                     030 001          W e l c o m e …
```

(These numbers are **octal**, base 8, as printed by the `od` tool: 377
octal is 255, the IAC byte.)

- ✅ WILL, WONT, DO and DONT are removed completely.
- ⚠️ **Subnegotiation contents slip through.** Rule 2 removes the SB and SE
  markers but not the bytes between them. That's the leftover `030 001`.
- ⚠️ **Rule order.** A real 255 in the text (sent as `FF FF`) followed by a
  byte from FB to FE gets mistaken for a command, and one character is
  lost. It's rare in normal text.
- ⚠️ **It never answers.** socwrap doesn't reply to negotiation at all.
  Most servers carry on regardless, but a strict one might wait.
- ❌ **Prompts that don't end a line are held back.** This is the one you'll
  notice. `perl -p` handles text **one line at a time**, so it waits for a
  line ending before passing anything on. A telnet `login: ` prompt has no
  line ending: the cursor waits just after it. So you don't see the prompt
  until *after* you've typed your username. Measured: through the cleaner,
  the first character of `login: ` appeared **2.00 seconds** late, compared
  with **0.002 seconds** without it. This is a **buffering** problem, the
  same idea as in Part 1. See
  [Part 3, bug 5](03-field-notes-bugs-and-fixes.md#bug-5-telnet-login-prompts-dont-appear-until-you-type)
  for a fix.
- ❌ **Without perl, nothing is cleaned.** The fallback `sed` pattern looks
  for the literal characters `^[[` (not the escape code it was meant to
  match), and nothing in it matches byte 255. Without perl, telnet mode is
  plain TCP, although the warning only says it's "limited".

---

## 7. Choosing the builder, running, and reporting the result

`build_socat_cmd()` (P2:540) picks the builder for the mode:

```bash
case "$OPT_MODE" in
    exec)   remote_addr=$(build_exec_addr "${WRAP_TARGET[@]}") ;;
    tcp)    remote_addr=$(build_tcp_addr) ;;
    udp)    remote_addr=$(build_udp_addr) ;;
    unix)   remote_addr=$(build_unix_addr) ;;
    ssh)    remote_addr=$(build_ssh_addr) ;;
    telnet) remote_addr=$(build_telnet_addr) ;;
    chroot) remote_addr=$(build_chroot_addr) ;;
    *)      die "Unknown mode: $OPT_MODE" ;;
esac
SOCAT_CMD=(socat "-" "$remote_addr")
```

Picking which code to run based on a value like this is called
**dispatch**.

> **New term: dispatch.** Sending work to the right function based on a
> value, here the mode.

So adding a new mode means: write a builder, add a line here, add a check
in preflight, add an option to the first pass, and update the help. The
input loop stays untouched.

Then `run_socat()` runs exactly as in
[Part 1 §4.8](01-phase1-core-bridge.md#48-the-main-event-run_socat). For
network modes, "the other side has gone" means the server closed the
connection. socat sees EOF and stops, the copier stops, the watcher sends
SIGUSR1, and the input loop ends.

Finally, `_interpret_exit()` (P2:647) turns socat's exit status into
advice:

| socat's exit status | Message |
|---------------------|---------|
| 0 | (only with `--verbose`) finished cleanly |
| 1 | `general error (exit 1) — check connection parameters` |
| 2 | `syntax/usage error` |
| 111 | `connection refused — is the target listening?` |
| 130 / 143 | (only with `--verbose`) interrupted |

In practice, when something goes wrong you **never see this advice**, for
two reasons. socat reports "connection refused" as status 1, never 111.
And strict mode stops the script before this function is reached. See
[Part 3, bug 4](03-field-notes-bugs-and-fixes.md#bug-4-when-socat-fails-socwrap-skips-its-clean-up-and-advice).

---

## 8. `--detect` and `--dry-run` in Phase 2

`--detect` now also says which modes should work on this machine:

```console
$ socwrap.sh --detect | jq -c .modes_available
{"exec":true,"tcp":true,"udp":true,"unix":true,"ssh":false,"telnet":true,"chroot":true,"tls_tcp":true}
```

(`ssh` is false here because the test machine has no ssh program
installed.)

`--dry-run` adds a summary for the chosen mode:

```console
$ socwrap.sh --dry-run -T 10.0.0.1 23
  Readline layer (bash read -e):
    …
    IAC scrub   : perl -pe 's/\xff[\xfb-\xfe][\x00-\xff]//g; …'
  socat I/O bridge:
    socat \
      "-" \
      "TCP:10.0.0.1:23,connect-timeout=10"
[socwrap] Mode        : telnet
[socwrap] PTY         : enabled
[socwrap] Timeout     : 10s
[socwrap] Host        : 10.0.0.1
[socwrap] Port        : 23
```

Treat parts of this summary with some care. `PTY: enabled` and `Timeout`
appear for every mode, even where they don't apply: network connections
never use a PTY, and Unix and SSH modes have no timeout. In chroot mode,
`Chroot shell:` always says `/bin/sh`, even if you named another shell.

`--verbose` prints a start-up summary to stderr, followed by the full
`--detect` report.

---

## 9. Labs: try every mode on one machine

The tutorial includes a script that starts small practice servers on your
own machine. They listen on `127.0.0.1` only, so nothing is reachable from
outside, and each one echoes back what you send, labelled with its kind of
connection.

```bash
bash labs/lab-servers.sh start      # start them all
bash labs/lab-servers.sh status     # list what's running
bash labs/lab-servers.sh stop       # stop them and tidy up
```

In the commands below, `socwrap.sh` means `bash phase2/socwrap.sh`. Add
`-H /tmp/lab_history` so the practice doesn't fill your real history file.

| Try | Command | What you should see |
|-----|---------|---------------------|
| TCP | `socwrap.sh -p "tcp> " -t 127.0.0.1 7001` | `tcp: <what you typed>` |
| TCP, host:port | `socwrap.sh -t 127.0.0.1:7001` | the same |
| UDP | `socwrap.sh -p "udp> " -u 127.0.0.1 7002` | `udp: <what you typed>` |
| Unix socket | `socwrap.sh -U /tmp/socwrap-lab/echo.sock` | `unix: <what you typed>` |
| TLS, no check | `socwrap.sh --tls --no-tls-verify -t 127.0.0.1 7003` | `tls: <what you typed>` |
| TLS, with check | `socwrap.sh --tls -t 127.0.0.1 7003` | `certificate verify failed`, because the lab certificate is self-signed |
| Telnet, uncleaned | `socwrap.sh --no-iac-scrub -T 127.0.0.1 7004` | junk characters before `Welcome` |
| Telnet, cleaned | `socwrap.sh -T 127.0.0.1 7004` | a clean welcome. Does `login:` appear before you type? |
| Nobody listening | `socwrap.sh -v -t 127.0.0.1 1` | which socwrap messages are *missing*? |

Further exercises:

1. **See CRLF happen.** In one terminal run
   `socat TCP-LISTEN:7010,reuseaddr SYSTEM:'od -c'` (a server that shows
   every byte it receives). Connect with and without `-C`, type `hi`, and
   leave. Look for `\r`.
2. **Talk to a web server by hand.** `socwrap.sh -C -t example.com 80`,
   then type `GET / HTTP/1.1`, `Host: example.com` and an empty line.
   Press ↑ to send it again.
3. **Two histories over SSH.** Run `socwrap.sh -H /tmp/h_ssh -s you@host`,
   type some commands, exit, then compare `/tmp/h_ssh` with the remote
   `~/.bash_history`.
4. **Find the advice that never appears.** Why can't `_interpret_exit` ever
   print "connection refused"? There are two reasons; both are in Part 3.
5. **Trip up the first pass.** Predict what
   `socwrap.sh --dry-run -- ls -t` will do, then run it.

---

## 10. What you now know

- Phase 2 = Phase 1's unchanged input loop + **seven builders** + one
  output **filter**.
- A **mode** says what to connect to. Picking the builder by mode is
  **dispatch**.
- Mode options take two values, so they need a **first pass** before
  getopt.
- **TCP** gains TLS (`OPENSSL`, `verify=0`), CRLF line endings and a
  connect timeout. **Telnet** is TCP plus the cleaner.
- **SSH** and **chroot** are exec mode with a fixed program and a PTY that
  is always on.
- The telnet cleaner removes **IAC** negotiation codes with a perl
  **regex**. It holds back prompts that don't end a line, and lets
  subnegotiation contents through.

**Next: [Part 3, bugs found along the way and how to fix them](03-field-notes-bugs-and-fixes.md)**
