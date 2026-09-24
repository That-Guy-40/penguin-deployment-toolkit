# Glossary

Every term this tutorial introduces, with a plain-language meaning and a
link to where it's first explained. The tutorial introduces them in
order ([Part 0](00-building-blocks.md) → [1](01-phase1-core-bridge.md) →
[2](02-phase2-transport-modes.md) → [3](03-field-notes-bugs-and-fixes.md)),
so later parts assume the earlier words.

| Term | Plain meaning | Introduced in |
|------|---------------|---------------|
| `--` | "My options end here; the rest belongs to the program I'm running." | [Part 1 §2](01-phase1-core-bridge.md#2-trying-it-before-reading-it) |
| address (socat) | A string telling socat what one side of the connection is, like `TCP:host:80`. | [Part 0 §11](00-building-blocks.md#11-socat-the-universal-adapter) |
| address option | An extra setting after a comma in a socat address, like `,connect-timeout=10`. | [Part 0 §11](00-building-blocks.md#11-socat-the-universal-adapter) |
| array | A variable holding a list of values in numbered slots. | [Part 1 §4.2](01-phase1-core-bridge.md#42-settings-and-where-they-come-from) |
| automated test / test suite | A script that checks a program behaves correctly; a suite is a collection of them. | [Part 1 §6](01-phase1-core-bridge.md#6-how-the-project-tests-itself) |
| background process | A child that runs alongside its parent instead of making it wait. Started with `&`. | [Part 0 §3](00-building-blocks.md#3-processes-programs-that-are-running) |
| bash | The most common shell on Linux. socwrap is written in it. | [Part 0 §1](00-building-blocks.md#1-the-terminal-and-the-programs-inside-it) |
| buffering / line buffering | Collecting data before passing it on. Line buffering passes on each complete line. | [Part 1 §4.8, step 3](01-phase1-core-bridge.md#step-3-start-the-copier) |
| builder (function) | A function whose only job is to put together a piece of text, here a socat address. | [Part 2 §5](02-phase2-transport-modes.md#5-building-the-address-for-each-mode) |
| byte | One unit of data: a number from 0 to 255. | [Part 2 §6.1](02-phase2-transport-modes.md#61-what-telnet-mixes-into-its-text) |
| certificate | A server's digital ID card, used by TLS. | [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes) |
| certificate verification | Checking a server's certificate is genuine. `--no-tls-verify` skips it. | [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes) |
| child process | A process started by another process (its parent). | [Part 0 §3](00-building-blocks.md#3-processes-programs-that-are-running) |
| chroot / chroot jail | Running a program so one folder looks like the whole filesystem to it. | [Part 2 §5.6](02-phase2-transport-modes.md#56-chroot-build_chroot_addr-p2482) |
| command substitution | `$(cmd)`: run cmd and capture what it prints. | [Part 1 §4.6](01-phase1-core-bridge.md#46-writing-the-socat-address) |
| connect timeout | How long to wait for a connection's handshake before giving up. | [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes) |
| copier | socwrap's background `cat` (or `tee`) that copies output to your screen. | [Part 1 §1](01-phase1-core-bridge.md#1-the-idea-in-one-picture) |
| CRLF / LF | Two ways to end a line: `\r\n` (network protocols) and `\n` (Linux). | [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes) |
| datagram | One self-contained UDP message. | [Part 2 §5.2](02-phase2-transport-modes.md#52-udp-build_udp_addr-p2423) |
| deadlock | Two processes each waiting for the other, so neither moves. | [Part 1 §4.8, step 2](01-phase1-core-bridge.md#step-2-make-the-two-named-pipes-in-the-right-order) |
| default action (signal) | What a signal does when no trap is set: usually stop the process. | [Part 0 §7](00-building-blocks.md#7-signals-tapping-a-process-on-the-shoulder) |
| dispatch | Choosing which function to run based on a value, here the mode. | [Part 2 §7](02-phase2-transport-modes.md#7-choosing-the-builder-running-and-reporting-the-result) |
| dry run | Show the plan without carrying it out (`--dry-run`). | [Part 1 §4.7](01-phase1-core-bridge.md#47-showing-the-plan-without-running-it---dry-run) |
| echo | The terminal showing you the characters you type. | [Part 0 §9](00-building-blocks.md#9-real-terminals-and-fake-ones) |
| environment variable | A named setting passed from a shell to the programs it starts. | [Part 1 §4.2](01-phase1-core-bridge.md#42-settings-and-where-they-come-from) |
| EOF (end of file) | The signal to a reader that nothing more is coming. Ctrl-D sends it from the keyboard. | [Part 0 §6](00-building-blocks.md#6-pipes-and-named-pipes) |
| errno | The kernel's error number for a failure (111 = connection refused). Not the same as an exit status. | [Part 3, bug 4](03-field-notes-bugs-and-fixes.md#bug-4-when-socat-fails-socwrap-skips-its-clean-up-and-advice) |
| eval | "Run this text as a command." | [Part 2 §6.2](02-phase2-transport-modes.md#62-socwraps-approach-remove-them-dont-answer-them) |
| EXIT trap | Code bash runs whenever a script ends, for any reason. | [Part 0 §7](00-building-blocks.md#7-signals-tapping-a-process-on-the-shoulder) |
| exit status (exit code) | The number a process leaves when it ends. 0 = OK; 128+N = stopped by signal N. | [Part 0 §8](00-building-blocks.md#8-exit-status-how-a-program-says-how-it-went) |
| FIFO | Another name for a named pipe ("first in, first out"). | [Part 0 §6](00-building-blocks.md#6-pipes-and-named-pipes) |
| file descriptor (fd) | The number a process uses for one open connection. 0, 1 and 2 are stdin, stdout and stderr. | [Part 0 §5](00-building-blocks.md#5-file-descriptors-numbered-connections) |
| filter | A program that reads text, changes it and writes it out. | [Part 2 §6.2](02-phase2-transport-modes.md#62-socwraps-approach-remove-them-dont-answer-them) |
| flag (variable) | A variable used as an on/off marker. | [Part 1 §4.8, step 6](01-phase1-core-bridge.md#step-6-change-what-ctrl-c-does-while-you-type) |
| function | A named block of code inside a script, used like a small command. | [Part 1 §3](01-phase1-core-bridge.md#3-how-the-script-is-organised) |
| getopt | A tool that tidies up command-line options so a script can go through them. | [Part 1 §4.9](01-phase1-core-bridge.md#49-reading-the-command-line) |
| handshake | The short exchange that opens a TCP connection. | [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes) |
| heuristic | A rule of thumb that usually works but isn't guaranteed. | [Part 1 §4.8, step 7](01-phase1-core-bridge.md#step-7-the-input-loop) |
| hexadecimal (hex) | Counting in base 16 (0–9, A–F). 255 is `FF`. `0x` marks a hex number. | [Part 2 §6.1](02-phase2-transport-modes.md#61-what-telnet-mixes-into-its-text) |
| history / history file | Remembered past commands, saved to a file so ↑ works next time. | [Part 0 §2](00-building-blocks.md#2-line-editing-and-history-the-problem-socwrap-solves) |
| host | A machine on the network, like `example.com` or `127.0.0.1` (this machine). | [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes) |
| IAC | Byte `0xFF`: in telnet, "a command follows". | [Part 2 §6.1](02-phase2-transport-modes.md#61-what-telnet-mixes-into-its-text) |
| IFS / word splitting | bash cutting a value into words; IFS lists the characters it cuts on. | [Part 1 §4.1](01-phase1-core-bridge.md#41-safety-settings-at-the-top) |
| inheritance (of fds) | A child gets a copy of every file descriptor its parent has open. | [Part 0 §5](00-building-blocks.md#5-file-descriptors-numbered-connections) |
| input loop | socwrap's `while read -e` loop: prompt, edit, send, repeat. | [Part 1 §4.8, step 7](01-phase1-core-bridge.md#step-7-the-input-loop) |
| interactive program / REPL | A program that prompts, reads a line, answers, and repeats. | [Part 0 §1](00-building-blocks.md#1-the-terminal-and-the-programs-inside-it) |
| JSON | A common text format for structured data: `{"ready": true}`. | [Part 1 §4.5](01-phase1-core-bridge.md#45-checking-the-machine---detect) |
| layer | One part of a system with one job. socwrap has a readline layer and a transport layer. | [Part 1 §1](01-phase1-core-bridge.md#1-the-idea-in-one-picture) |
| library | A reusable piece of code shared by many programs. | [Part 0 §2](00-building-blocks.md#2-line-editing-and-history-the-problem-socwrap-solves) |
| mode | The kind of target socwrap connects to (exec, tcp, udp, …). | [Part 2 §1](02-phase2-transport-modes.md#1-modes-one-switch-seven-settings) |
| named pipe | A pipe with a filename, so unrelated processes can open it. Opening one waits for the other end. | [Part 0 §6](00-building-blocks.md#6-pipes-and-named-pipes) |
| negotiation | Two programs agreeing on settings at the start of a conversation. | [Part 2 §6.1](02-phase2-transport-modes.md#61-what-telnet-mixes-into-its-text) |
| octal | Counting in base 8. The `od` tool shows bytes this way: 377 octal = 255. | [Part 2 §6.3](02-phase2-transport-modes.md#63-how-well-it-works) |
| option (flag) | A command-line setting, like `-p "x> "` or `--detect`. | [Part 1 §2](01-phase1-core-bridge.md#2-trying-it-before-reading-it) |
| parent process | The process that started another one. | [Part 0 §3](00-building-blocks.md#3-processes-programs-that-are-running) |
| parsing / pass | Reading text to work out its structure; a pass is one read-through. | [Part 2 §3](02-phase2-transport-modes.md#3-reading-the-command-line-in-two-passes) |
| patch (diff) | A list of lines to remove (`-`) and add (`+`) to change a program. | [Part 3](03-field-notes-bugs-and-fixes.md) |
| perl | A programming language that's especially good at text processing. | [Part 2 §6.2](02-phase2-transport-modes.md#62-socwraps-approach-remove-them-dont-answer-them) |
| PID | A process's ID number. | [Part 0 §3](00-building-blocks.md#3-processes-programs-that-are-running) |
| pipe | A one-way channel: one process writes in, another reads out. `a \| b`. | [Part 0 §6](00-building-blocks.md#6-pipes-and-named-pipes) |
| polling | Checking again and again whether something has changed. | [Part 1 §4.8, step 4](01-phase1-core-bridge.md#step-4-start-the-watcher) |
| port | A numbered service on a host (web = 80, SSH = 22, telnet = 23). | [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes) |
| preflight | The checks socwrap makes just before running. | [Part 1 §4.5](01-phase1-core-bridge.md#45-checking-the-machine---detect) |
| `/proc` | A folder Linux fills with live information about every process. | [Part 1 §4.8, step 2](01-phase1-core-bridge.md#step-2-make-the-two-named-pipes-in-the-right-order) |
| process | A running copy of a program. | [Part 0 §3](00-building-blocks.md#3-processes-programs-that-are-running) |
| prompt | The text a program shows to say "your turn". | [Part 0 §1](00-building-blocks.md#1-the-terminal-and-the-programs-inside-it) |
| protocol | The agreed rules of a conversation between programs (HTTP, SMTP, telnet…). | [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes) |
| PTY (pseudo-terminal) | A fake terminal made in software, so a program behaves as if a person is typing. | [Part 0 §9](00-building-blocks.md#9-real-terminals-and-fake-ones) |
| race condition | A glitch that depends on which of two things happens first. | [Part 1 §4.8, step 7](01-phase1-core-bridge.md#step-7-the-input-loop) |
| readline | The library that provides line editing, history and Ctrl-R search. bash's `read -e` uses it. | [Part 0 §2](00-building-blocks.md#2-line-editing-and-history-the-problem-socwrap-solves) |
| reaping / wait | A parent collecting a finished child's exit status. | [Part 0 §8](00-building-blocks.md#8-exit-status-how-a-program-says-how-it-went) |
| redirection | Using `<`, `>` or `2>` to change where a program's streams go. | [Part 0 §4](00-building-blocks.md#4-the-three-standard-streams) |
| regression test | A test that reproduces a fixed bug, so it's caught if the bug returns. | [Part 3, smaller issues](03-field-notes-bugs-and-fixes.md#smaller-issues) |
| regular expression (regex) | A pattern describing text to search for. | [Part 2 §6.2](02-phase2-transport-modes.md#62-socwraps-approach-remove-them-dont-answer-them) |
| reproduce / reproduction | Making a bug happen on purpose, reliably. | [Part 3](03-field-notes-bugs-and-fixes.md) |
| root | The administrator account on Linux. | [Part 2 §4](02-phase2-transport-modes.md#4-checks-for-each-mode) |
| script | A text file of shell commands, run top to bottom. | [Part 0 §1](00-building-blocks.md#1-the-terminal-and-the-programs-inside-it) |
| scrubber (cleaner) | socwrap's telnet filter that removes IAC control codes. | [Part 2 §6.2](02-phase2-transport-modes.md#62-socwraps-approach-remove-them-dont-answer-them) |
| self-signed certificate | A certificate a server made for itself. Fine in labs, refused unless you skip verification. | [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes) |
| session | A group of processes sharing one terminal. socat's `setsid` starts a new one. | [Part 1 §4.6](01-phase1-core-bridge.md#46-writing-the-socat-address) |
| shell | The program that reads and runs your commands. | [Part 0 §1](00-building-blocks.md#1-the-terminal-and-the-programs-inside-it) |
| signal | A tiny notification sent to a process (SIGINT from Ctrl-C, SIGTERM from `kill`, …). | [Part 0 §7](00-building-blocks.md#7-signals-tapping-a-process-on-the-shoulder) |
| SIGUSR1 | A signal with no built-in meaning. socwrap uses it to mean "the other side is gone". | [Part 0 §7](00-building-blocks.md#7-signals-tapping-a-process-on-the-shoulder) |
| socat | A tool that connects any two things and copies data both ways. | [Part 0 §11](00-building-blocks.md#11-socat-the-universal-adapter) |
| socket | One end of a network conversation, used like a file descriptor. | [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes) |
| SSH | Encrypted remote login. | [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes) |
| stdin / stdout / stderr | The three standard streams: input, normal output, error output. | [Part 0 §4](00-building-blocks.md#4-the-three-standard-streams) |
| strict mode | `set -euo pipefail`: make bash stop at the first sign of trouble. | [Part 1 §4.1](01-phase1-core-bridge.md#41-safety-settings-at-the-top) |
| `stty` | The tool that reads and changes terminal settings. | [Part 1 §4.4](01-phase1-core-bridge.md#44-tidying-up-on-the-way-out) |
| subnegotiation | A longer telnet message about one setting, between IAC SB and IAC SE. | [Part 2 §6.1](02-phase2-transport-modes.md#61-what-telnet-mixes-into-its-text) |
| subshell | A throwaway copy of the shell. Changes made inside it don't reach the main script. | [Part 1 §4.6](01-phase1-core-bridge.md#46-writing-the-socat-address) |
| TAP | Test Anything Protocol: a simple `ok` / `not ok` line format for test results. | [Part 1 §6](01-phase1-core-bridge.md#6-how-the-project-tests-itself) |
| TCP | A dependable two-way connection, like a phone call. | [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes) |
| teardown | Undoing setup at the end: saving, closing, stopping helpers. | [Part 1 §4.8, step 8](01-phase1-core-bridge.md#step-8-take-it-all-down) |
| telnet | An old, unencrypted remote-login protocol with control codes mixed into its text. | [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes) |
| TLS | Encryption for a connection: the "S" in HTTPS. | [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes) |
| trap | A bash instruction: "when this signal arrives, run this". `trap ''` ignores; `trap -` restores the default. | [Part 0 §7](00-building-blocks.md#7-signals-tapping-a-process-on-the-shoulder) |
| UDP | Fire-and-forget messages, like postcards. | [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes) |
| Unix socket | A connection between programs on the same machine, addressed by a file path. | [Part 0 §10](00-building-blocks.md#10-networks-in-ten-minutes) |
| unlink | Remove a file's name. Programs that already have it open can keep using it. | [Part 1 §4.8, step 2](01-phase1-core-bridge.md#step-2-make-the-two-named-pipes-in-the-right-order) |
| watcher (monitor) | socwrap's background helper that notices when socat stops and sends SIGUSR1. | [Part 1 §4.8, step 4](01-phase1-core-bridge.md#step-4-start-the-watcher) |
| wrap / wrapped program | Running a program with socwrap in front of it; the program you're really talking to. | [Part 1 §1](01-phase1-core-bridge.md#1-the-idea-in-one-picture) |
