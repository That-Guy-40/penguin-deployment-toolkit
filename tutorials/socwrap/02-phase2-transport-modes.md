# Part 2: Phase 2, transport modes

Phase 2 takes the phase 1 bridge onto the network. The script grows from
730 to 1,156 lines, but the idea is simple:

> **The readline loop doesn't change. Only the right-hand socat address does.**

```
socat  -  EXEC:python3,pty,…          # phase 1
socat  -  TCP:host:80,…               # phase 2, tcp
socat  -  OPENSSL:host:443,…          # phase 2, tls
socat  -  UDP:host:514,…              # phase 2, udp
socat  -  UNIX-CONNECT:/run/app.sock  # phase 2, unix
socat  -  EXEC:ssh user@host,pty,…    # phase 2, ssh
socat  -  TCP:router:23,…  + scrubber # phase 2, telnet
socat  -  EXEC:chroot /srv /bin/sh,…  # phase 2, chroot
```

If you haven't read [Part 1](01-phase1-core-bridge.md), read it first.
Everything about FIFOs, the monitor, traps and history carries over
unchanged.

- [1. What changed, at a glance](#1-what-changed-at-a-glance)
- [2. New runtime state](#2-new-runtime-state)
- [3. Two-pass argument parsing](#3-two-pass-argument-parsing)
- [4. Mode-aware preflight](#4-mode-aware-preflight)
- [5. The address builders](#5-the-address-builders)
- [6. The telnet IAC scrubber](#6-the-telnet-iac-scrubber)
- [7. Dispatch, run and exit codes](#7-dispatch-run-and-exit-codes)
- [8. Detect, dry-run and the banner](#8-detect-dry-run-and-the-banner)
- [9. Labs](#9-labs)
- [10. Recap](#10-recap)

---

## 1. What changed, at a glance

| Area | Phase 1 | Phase 2 |
|------|---------|---------|
| Modes | `exec` | `exec`, `tcp` (+TLS), `udp`, `unix`, `ssh`, `telnet`, `chroot` |
| Argument parsing | `getopt` only | a hand-written **pre-pass** for multi-value mode flags, then `getopt` |
| Address building | `build_exec_addr` | one builder per mode, chosen by `build_socat_cmd` |
| Output path | `cat` or `tee` | the same, plus a **telnet IAC scrubber** in front |
| Detection | socat, readline, PTY, jq, rlwrap | + OpenSSL, perl, xxd, ssh, and a `modes_available` map |
| Preflight | bash and socat | + checks per mode (host, port, socket, directory, ssh) |
| Exit reporting | inline `case` | `_interpret_exit()` |
| New flags | | `-t -u -U -s -T -c`, `--tls`, `--no-tls-verify`, `--timeout`, `--ssh-opts`, `--no-iac-scrub`, `-C/--crlf` |

A useful way to see what *didn't* change is to diff the two scripts with
indentation ignored:

```bash
diff <(sed 's/^ *//' phase1/socwrap.sh) <(sed 's/^ *//' phase2/socwrap.sh) | less
```

`run_socat()` is almost identical. The only change is the output forwarder
block (P2:704–728).

---

## 2. New runtime state

P2:45–96 adds one variable group per mode:

```bash
OPT_MODE="exec"                 # exec | tcp | udp | unix | ssh | telnet | chroot
OPT_HOST=""  OPT_PORT=""        # tcp / udp / telnet
OPT_UNIX_SOCK=""                # unix
OPT_SSH_TARGET="" OPT_SSH_OPTS=""
OPT_CHROOT_DIR="" OPT_CHROOT_SHELL="$DEFAULT_SHELL"   # /bin/sh
OPT_IAC_SCRUB=1                 # telnet: scrubbing on by default
OPT_CRLF=0                      # tcp/udp: LF → CRLF
OPT_TLS=0 OPT_TLS_VERIFY=1      # tcp: TLS off; verify on when TLS is used
OPT_TIMEOUT=10                  # connect timeout in seconds
```

`OPT_MODE` is the single switch the rest of the script branches on.

---

## 3. Two-pass argument parsing

`getopt` handles options that take **one** value. `-t HOST PORT` takes two.
Phase 2 handles this with a hand-written first pass (P2:967–1041) that pulls
the mode flags out before `getopt` sees anything:

```bash
local -a remaining_args=()
local -a args=("$@")
while [[ $i -lt $argc ]]; do
    arg="${args[$i]}"; next="${args[$((i+1))]:-}"; next2="${args[$((i+2))]:-}"
    case "$arg" in
        -t)  _set_mode tcp
             if [[ "$next" == *":"* ]]; then       # -t host:port
                 OPT_HOST="${next%:*}"; OPT_PORT="${next#*:}"; i=$((i+2))
             else                                  # -t host port
                 OPT_HOST="$next";      OPT_PORT="$next2";     i=$((i+3))
             fi ;;
        -u)  … same, mode udp …
        -T)  … same, mode telnet …
        -U)  _set_mode unix;   OPT_UNIX_SOCK="$next";  i=$((i+2)) ;;
        -s)  _set_mode ssh;    OPT_SSH_TARGET="$next"; i=$((i+2)) ;;
        -c)  _set_mode chroot; OPT_CHROOT_DIR="$next"; i=$((i+2)) ;;
        --ssh-opts) OPT_SSH_OPTS="$next"; i=$((i+2)) ;;
        *)   remaining_args+=("$arg"); i=$((i+1)) ;;
    esac
done
set -- "${remaining_args[@]}"
```

Then the second pass is the familiar phase 1 `getopt` loop over whatever is
left.

Details worth knowing:

- **Both `host port` and `host:port` work.** `${next%:*}` removes the
  *shortest* suffix matching `:*`, so it cuts at the **last** colon, and
  `${next#*:}` removes the shortest prefix, so it cuts at the **first**
  colon. That's fine for `example.com:80`. An IPv6 literal such as
  `::1:80` gives host `::1` and port `:1:80`, which then fails the numeric
  check. Use the two-word form, and brackets aren't handled at all.
- **One mode only.** `_set_mode` (P2:954) `die`s if a mode is already set,
  so `-t a 1 -u b 2` is rejected. It's defined *inside* `parse_args`, but
  bash functions are always global, so once `parse_args` has run it exists
  everywhere. Harmless, but good to know.
- **`--ssh-opts` appears twice**, in the pre-pass and in `getopt`'s long
  options. The pre-pass consumes it first, so the `getopt` branch is
  unreachable unless you write `--ssh-opts=VALUE`.
- **After parsing** (P2:1113–1119): `--tls` without `-t` is an error, and
  `SOCWRAP_SSH_OPTS` fills in `OPT_SSH_OPTS` when the flag wasn't given.

The pre-pass has one serious flaw: **it doesn't stop at `--`.** It scans
every argument, including the wrapped command's own arguments, so
`-- bash -c 'echo hi'` turns into chroot mode. See
[Part 3, bug 2](03-field-notes-bugs-and-fixes.md#bug-2-mode-flags-are-stolen-from-the-wrapped-command).

---

## 4. Mode-aware preflight

`preflight()` (P2:318–367) keeps the phase 1 checks and adds a `case` on
`OPT_MODE`:

| Mode | Hard failures (`die`) | Soft warnings |
|------|-----------------------|---------------|
| `tcp`, `telnet` | missing host or port; port not numeric or outside 1–65535; `--tls` without OpenSSL in socat | |
| `udp` | missing host or port; port not numeric | *(no range check)* |
| `unix` | missing path | socket doesn't exist **yet** |
| `ssh` | missing target; no `ssh` on PATH | |
| `chroot` | missing directory or not a directory | not running as root |
| `exec` | no command after `--` | |

Two choices stand out:

- **Unix: warn, don't fail.** Some daemons create their socket lazily, and
  you might start socwrap before the service.
- **Chroot: warn, don't fail, when not root.** This allows testing with
  `fakechroot` or with `CAP_SYS_CHROOT` granted to a non-root user.

---

## 5. The address builders

Each builder prints a single socat address string on stdout. The dispatcher
captures it with `$( … )`.

### 5.1 TCP and TLS: `build_tcp_addr` (P2:402)

```bash
if [[ "$OPT_TLS" -eq 1 ]]; then
    addr="OPENSSL:${OPT_HOST}:${OPT_PORT}"
    opts=("connect-timeout=${OPT_TIMEOUT}")
    [[ "$OPT_TLS_VERIFY" -eq 0 ]] && opts+=("verify=0")
else
    addr="TCP:${OPT_HOST}:${OPT_PORT}"
    opts=("connect-timeout=${OPT_TIMEOUT}")
fi
[[ "$OPT_CRLF" -eq 1 ]] && opts+=("crlf")
```

```console
$ socwrap.sh --dry-run -t 10.0.0.5:8080 -C
      "TCP:10.0.0.5:8080,connect-timeout=10,crlf"
$ socwrap.sh --dry-run --tls --no-tls-verify -t 10.0.0.5 8443
      "OPENSSL:10.0.0.5:8443,connect-timeout=10,verify=0"
```

- **`connect-timeout`** only limits the TCP handshake. Once connected, the
  session has no time limit.
- **`crlf`** on the network address makes socat turn each outgoing LF into
  CRLF. That's what HTTP, SMTP, POP3, IMAP and most IETF line protocols
  expect. It was checked on the wire: typing `a` and `b` sent the bytes
  `a \r \n b \r \n`.
- **`verify=0`** turns off certificate checking. Without it, a self-signed
  server fails with
  `SSL_connect(): … certificate verify failed`. Only use it on hosts you
  control or labs.
- There's no separate "tls" mode. TLS is a variation of `tcp`, and `--dry-run`
  still reports `Mode: tcp`.

### 5.2 UDP: `build_udp_addr` (P2:423)

```
UDP:10.0.0.5:514,connect-timeout=10
```

socat's `UDP:` address gives a *connected* datagram socket: every line you
type becomes one datagram to the target, and replies come back through the
same socket. UDP has no handshake, so `connect-timeout` has nothing to do,
and a target that isn't listening usually looks like silence rather than an
error. On Linux a closed port can produce an ICMP "port unreachable", which
makes the next read fail with "connection refused".

### 5.3 Unix sockets: `build_unix_addr` (P2:437)

```
UNIX-CONNECT:/run/app.sock
```

Useful for supervisord, the Docker API socket (`-C` helps for HTTP), local
Redis or anything else that speaks a line protocol over a stream socket.
Remember that the kernel limits socket paths to 108 bytes (socat reports
`unix socket address 109 characters long, max length is 108`).

### 5.4 SSH: `build_ssh_addr` (P2:446)

```bash
local -a ssh_cmd=(ssh)
if [[ -n "$OPT_SSH_OPTS" ]]; then
    local -a extra_opts=($OPT_SSH_OPTS)    # deliberate word-split …
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

SSH mode is **EXEC mode with ssh as the command**. The PTY matters here:
`ssh` only asks the server for a remote PTY when its own stdin is a
terminal, and password and host-key prompts need a terminal too.

What the user sees:

- **Local readline and history.** The same up-arrow history works across
  every session to that host (`-H ~/.hist_router1`).
- **Two layers of history.** The remote shell keeps its own, and socwrap's
  sits in front of it.
- **Nothing is sent until you press Enter.** Tab completion goes to *local*
  readline, not the remote shell, and full-screen programs (`vim`, `top`)
  won't work properly. It's a line-mode tool.

Look at the `-p\ 2222` in the output. `IFS=$'\n\t'` has no space in it, so
the "deliberate word-split" doesn't split, and `%q` escapes the space
instead. It still works, **by accident**: socat's EXEC splits on spaces
itself and ignores the backslash. (A fake `ssh` that prints its argv
received `[-p] [2222] [admin@10.0.0.1]`.) Because no shell is involved,
`--ssh-opts "-i ~/.ssh/key"` passes a literal `~`, so use `$HOME` instead.
More in
[Part 3, bug 3](03-field-notes-bugs-and-fixes.md#bug-3-arguments-containing-spaces-are-split-by-socat).

The PTY options are hard-coded, so **`--no-pty` is ignored in SSH mode**
(and in chroot mode), even though `--help` says it applies to both. See
[Part 3, bug 6](03-field-notes-bugs-and-fixes.md#smaller-issues).

### 5.5 Telnet: `build_telnet_addr` (P2:474)

```bash
build_telnet_addr() { build_tcp_addr; }
```

On the wire, telnet mode is exactly TCP mode. The difference is on the
**output side** ([§6](#6-the-telnet-iac-scrubber)). `--tls` and `-C` work
here too, because it calls the same builder.

### 5.6 Chroot: `build_chroot_addr` (P2:482)

```bash
local shell="${OPT_CHROOT_SHELL:-$DEFAULT_SHELL}"      # /bin/sh
if [[ ${#WRAP_TARGET[@]} -gt 0 ]]; then                # extra args override
    shell=$(printf '%q ' "${WRAP_TARGET[@]}"); shell="${shell% }"
fi
cmd_str=$(printf 'chroot %q %s' "$OPT_CHROOT_DIR" "$shell")
printf '%s,%s' "EXEC:${cmd_str}" "pty,setsid,echo=0,stderr"
```

```console
$ sudo socwrap.sh -c /srv/jail                      # /bin/sh inside the jail
      "EXEC:chroot /srv/jail /bin/sh,pty,setsid,echo=0,stderr"
$ sudo socwrap.sh -c /srv/jail -- /bin/bash -l      # use -- before shell flags
      "EXEC:chroot /srv/jail /bin/bash -l,pty,setsid,echo=0,stderr"
```

The shell path is looked up **inside** the jail, so `/srv/jail/bin/sh` must
exist along with the libraries it needs. A shell argument that begins with
a dash must come after `--`. Otherwise `getopt` treats it as one of
socwrap's own options: `-c /srv/jail /bin/bash -l` fails with
`option requires an argument -- 'l'`, because `-l` is `--log`.

---

## 6. The telnet IAC scrubber

### 6.1 A 60-second telnet primer

Telnet (RFC 854) sends control commands in the same byte stream as the data.
Every command starts with **IAC** (Interpret As Command), which is byte
`0xFF`:

| Bytes | Meaning |
|-------|---------|
| `FF FB xx` | IAC **WILL** option. "I'd like to enable option xx" |
| `FF FC xx` | IAC **WONT** option |
| `FF FD xx` | IAC **DO** option. "Please enable option xx" |
| `FF FE xx` | IAC **DONT** option |
| `FF FA … FF F0` | IAC **SB** … IAC **SE**: subnegotiation with a payload |
| `FF F1`–`FF F9` | two-byte commands (NOP, Data Mark, Break, IP, AO, AYT, EC, EL, GA) |
| `FF FF` | a literal `0xFF` data byte |

Common options include `01` ECHO, `03` SUPPRESS-GO-AHEAD, `18` (hex)
TERMINAL-TYPE and `1F` NAWS (window size). A raw TCP client shows these
bytes as junk, like `���` at the start of a router banner.

### 6.2 socwrap's approach: strip, don't negotiate

`iac_scrub_cmd()` (P2:511) returns a **string** holding a filter command:

```bash
if [[ "$OPT_IAC_SCRUB" -eq 0 ]]; then printf 'cat'; return; fi
if _has_perl; then
    printf '%s' 'perl -pe '"'"'s/\xff[\xfb-\xfe][\x00-\xff]//g; s/\xff[\xf0-\xfa]//g; s/\xff\xff/\xff/g'"'"
else
    printf "sed 's/\\^\\[\\[[0-9;]*[mGKHFABCDJMPST]//g'"
    warn "perl not available — IAC scrubbing limited…"
fi
```

The `'"'"'` sequences are the usual way to put a single quote inside a
single-quoted bash string: close the quote, add a double-quoted `'`, then
reopen. What comes out is:

```
perl -pe 's/\xff[\xfb-\xfe][\x00-\xff]//g; s/\xff[\xf0-\xfa]//g; s/\xff\xff/\xff/g'
```

The three substitutions, in order:

1. `\xff[\xfb-\xfe][\x00-\xff]` removes the 3-byte WILL/WONT/DO/DONT
   commands.
2. `\xff[\xf0-\xfa]` removes the 2-byte commands, including the IAC SB and
   IAC SE markers.
3. `\xff\xff` becomes `\xff`, turning an escaped IAC back into a literal
   byte.

The forwarder in `run_socat` (P2:713–721) then runs it with `eval`, because
it's a command stored in a string:

```bash
if [[ "$OPT_MODE" == "telnet" ]]; then
    scrub_cmd=$(iac_scrub_cmd)
    if [[ -n "$OPT_LOG" ]]; then eval "$scrub_cmd" <&5 | "${_tee_cmd[@]}" &
    else                         eval "$scrub_cmd" <&5 &
    fi
fi
```

The pipeline becomes:

```
socat stdout → out_pipe → fd 5 → perl scrubber → [tee log] → terminal
```

### 6.3 What it does and doesn't handle

These results come from the lab's fake telnet server, which sends
`IAC WILL ECHO`, `IAC WILL SGA` and `IAC SB TTYPE SEND IAC SE`:

```
raw   (--no-iac-scrub): 377 373 001 377 373 003 377 372 030 001 377 360  W e l c o m e …
scrubbed             :                                      030 001      W e l c o m e …
```

- ✅ WILL/WONT/DO/DONT are removed completely.
- ⚠️ **Subnegotiation payloads leak.** Rule 2 removes `IAC SB` and `IAC SE`
  but leaves the bytes between them (`030 001`, meaning TTYPE SEND).
- ⚠️ **Order of the rules.** Rule 1 runs before rule 3. A literal `0xFF`
  followed by `FB`–`FE` gets misread as a command, and the next byte is
  lost. (`X FF FF FB Y` came out as `X FF`.) Rare in text, possible in
  binary.
- ⚠️ **It never answers.** socwrap sends nothing back, not even `WONT` or
  `DONT`. Most servers carry on anyway. A strict one might wait for replies.
- ❌ **Prompts without a newline are held back.** `perl -p` works one line at
  a time, so `login: ` (no `\n`) doesn't appear until the *next* newline
  comes, which is after you've typed your username without seeing a prompt.
  Measured: the first byte of `login: ` reached the screen **2.00 s** late
  through the scrubber, against **0.002 s** through `cat`. This is the most
  noticeable telnet problem in phase 2. See
  [Part 3, bug 5](03-field-notes-bugs-and-fixes.md#bug-5-telnet-prompts-without-a-newline-are-held-back),
  which includes a streaming replacement.
- ❌ **The sed fallback doesn't remove IAC at all.** `\^\[\[` in that sed
  pattern matches the literal text `^[[`, not the ESC byte, and nothing in
  it matches `0xFF`. Without perl, telnet mode is effectively raw TCP.

---

## 7. Dispatch, run and exit codes

`build_socat_cmd()` (P2:540) is a simple `case`:

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

Adding a mode means writing one builder, one `case` arm, one preflight arm,
one pre-pass flag and some help text. `run_socat` stays the same, which is
the payoff from the phase 1 design.

`run_socat()` works exactly as described in
[Part 1 §3.8](01-phase1-core-bridge.md#38-run_socat-the-heart-of-socwrap).
In network modes, "the other side exits" means the server closed the
connection. socat sees EOF and exits, `cat` exits, the monitor sends
`SIGUSR1`, and the loop ends.

`_interpret_exit()` (P2:647) turns socat's exit status into advice:

| rc | Message |
|----|---------|
| 0 | (debug) clean exit |
| 1 | `general error (exit 1) — check connection parameters` |
| 2 | `syntax/usage error` |
| 111 | `connection refused — is the target listening?` |
| 130 / 143 | (debug) interrupted or terminated |

In practice this table never runs for failures. socat reports a refused
connection as exit **1** (never 111), and under `set -e` a non-zero `wait`
ends the script before `_interpret_exit` is called. See
[Part 3, bug 4](03-field-notes-bugs-and-fixes.md#bug-4-socat-errors-skip-teardown-and-the-exit-code-explanation).

---

## 8. Detect, dry-run and the banner

`--detect` now reports TLS support and which modes are available:

```console
$ socwrap.sh --detect | jq -c .modes_available
{"exec":true,"tcp":true,"udp":true,"unix":true,"ssh":false,"telnet":true,"chroot":true,"tls_tcp":true}
```

(`ssh` is false on the reference machine because no ssh client is
installed.)

`--dry-run` adds a per-mode summary:

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

Read the dry-run output with care. `PTY: enabled` and `Timeout` are shown
for every mode, including those where they mean nothing (no PTY is used for
network addresses, and there's no timeout for unix or ssh). For chroot,
`Chroot shell:` always shows `/bin/sh`, even when you've given a different
shell.

`print_banner()` (P2:820) is the `--verbose` start-up summary on stderr,
followed by the full detection JSON.

---

## 9. Labs

Start the throwaway servers (they listen on 127.0.0.1 only):

```bash
bash labs/lab-servers.sh start
```

| Lab | Command | You should see |
|-----|---------|----------------|
| TCP | `socwrap.sh -p "tcp> " -t 127.0.0.1 7001` | `tcp: <your line>` |
| TCP, host:port form | `socwrap.sh -t 127.0.0.1:7001` | same |
| UDP | `socwrap.sh -p "udp> " -u 127.0.0.1 7002` | `udp: <your line>` |
| Unix | `socwrap.sh -U /tmp/socwrap-lab/echo.sock` | `unix: <your line>` |
| TLS, no verify | `socwrap.sh --tls --no-tls-verify -t 127.0.0.1 7003` | `tls: <your line>` |
| TLS, verify | `socwrap.sh --tls -t 127.0.0.1 7003` | `certificate verify failed` |
| Telnet, raw | `socwrap.sh --no-iac-scrub -T 127.0.0.1 7004` | junk bytes before `Welcome` |
| Telnet, scrubbed | `socwrap.sh -T 127.0.0.1 7004` | clean banner. Does `login:` appear before you type? |
| Refused | `socwrap.sh -v -t 127.0.0.1 1` | watch which messages are *missing* |

(Use `bash phase2/socwrap.sh` for `socwrap.sh`, and add
`-H /tmp/lab_history` so the lab doesn't fill your real history file.)

Stretch exercises:

1. **See the CRLF.** Run `socat TCP-LISTEN:7010,reuseaddr SYSTEM:'od -c'` in
   one terminal. Connect with and without `-C`, type `hi` and quit.
2. **Talk HTTP by hand.** `socwrap.sh -C -t example.com 80`, then type
   `GET / HTTP/1.1`, `Host: example.com` and an empty line. Press ↑ to repeat
   the request.
3. **Look at the two history layers in SSH.** Run
   `socwrap.sh -H /tmp/h_ssh -s you@host`, run commands, exit, then compare
   `/tmp/h_ssh` with the remote `~/.bash_history`.
4. **Find the dead code.** Why can't `_interpret_exit` ever print
   "connection refused"? (Two reasons. See [Part 3](03-field-notes-bugs-and-fixes.md).)
5. **Break the pre-pass.** Predict what
   `socwrap.sh --dry-run -- ls -t` does, then run it.

Clean up with `bash labs/lab-servers.sh stop`.

---

## 10. Recap

- Phase 2 = phase 1's loop + **seven address builders** + one output
  filter.
- The mode flags need a **hand-written pre-pass** because `getopt` can't
  take two values for one flag.
- `tcp` gains TLS (`OPENSSL:`, `verify=0`), CRLF translation and a connect
  timeout. `telnet` is `tcp` plus the scrubber.
- `ssh` and `chroot` are EXEC with a fixed command and a PTY that is always
  on.
- The IAC scrubber is a perl one-liner. It removes negotiation well, but
  holds back prompts without a newline and lets subnegotiation payloads
  through.

Continue to **[Part 3: field notes, bugs and fixes](03-field-notes-bugs-and-fixes.md)**.
