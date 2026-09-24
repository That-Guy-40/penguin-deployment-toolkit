# Part 0: The building blocks

**Start here if words like "stdin", "file descriptor", "pipe", "signal" or
"socket" are new to you, or a bit hazy.** This part assumes only that you've
typed a command into a Linux terminal before.

Each section introduces one or two words, explains them in plain language,
and from then on we use them freely. Every new word is marked like this:

> **New term: example.** A short, plain explanation.

By the end you'll be able to read this sentence and know what every part of
it means:

> *socwrap runs a readline loop in bash, writes each line you type into a
> named pipe that feeds socat's stdin, and a background process copies
> socat's stdout back to your terminal. socat connects to a TCP socket, a
> Unix socket, or a program running on a pseudo-terminal.*

If that already reads easily, skip to [Part 1](01-phase1-core-bridge.md).
The [glossary](GLOSSARY.md) lists every term with a link back to where it's
explained.

- [1. The terminal and the programs inside it](#1-the-terminal-and-the-programs-inside-it)
- [2. Line editing and history: the problem socwrap solves](#2-line-editing-and-history-the-problem-socwrap-solves)
- [3. Processes: programs that are running](#3-processes-programs-that-are-running)
- [4. The three standard streams](#4-the-three-standard-streams)
- [5. File descriptors: numbered connections](#5-file-descriptors-numbered-connections)
- [6. Pipes and named pipes](#6-pipes-and-named-pipes)
- [7. Signals: tapping a process on the shoulder](#7-signals-tapping-a-process-on-the-shoulder)
- [8. Exit status: how a program says how it went](#8-exit-status-how-a-program-says-how-it-went)
- [9. Real terminals and fake ones](#9-real-terminals-and-fake-ones)
- [10. Networks in ten minutes](#10-networks-in-ten-minutes)
- [11. socat: the universal adapter](#11-socat-the-universal-adapter)
- [12. Putting it together](#12-putting-it-together)

---

## 1. The terminal and the programs inside it

When you open a terminal window, you're talking to a program called a
**shell**. On most Linux systems the shell is **bash**. The shell shows a
**prompt** (something like `you@box:~$`), waits for you to type a command,
runs it, and shows the prompt again.

> **New term: shell.** The program that reads your commands and runs them.
> We'll use **bash**, the most common one.
>
> **New term: prompt.** The short text a program shows to say "your turn,
> type something".

bash can also run commands from a file. That file is a **script**. socwrap
is a bash script, `socwrap.sh`.

> **New term: script.** A text file full of shell commands, run from top to
> bottom as if you'd typed them.

Some programs, once started, keep asking you for input until you quit:
`python3`, `sqlite3`, `ftp`. Each one prints its own prompt (`>>>`,
`sqlite>`) and handles one line at a time. These are **interactive**
programs. A program with that kind of question-and-answer loop is often
called a **REPL** (Read, Evaluate, Print, Loop).

> **New term: interactive program / REPL.** A program that shows a prompt,
> reads a line, answers it and repeats.

---

## 2. Line editing and history: the problem socwrap solves

In bash you can press ← and → to move along what you've typed, ↑ to get
back your last command, and **Ctrl-R** to search your past commands. That's
**line editing** and **history**.

Try the same thing in a program that doesn't support it, such as
`nc example.com 80` (a simple network tool) or `cat`, and press ↑. You get
this instead:

```
^[[A
```

The program is handed your raw keystrokes and has no idea that "up arrow"
means "previous command".

Most programs that *do* support editing get it from a shared piece of code
called **readline**. bash uses it. So does python3 when it's built with it.
A reusable piece of code like this is a **library**.

> **New term: readline.** A library that provides line editing, history
> and Ctrl-R search. When we say "a readline prompt" we mean "a prompt
> where the arrow keys and history work".
>
> **New term: history file.** A file where past commands are saved so ↑
> still works the next time you start the program.

**socwrap's whole job:** put a readline prompt in front of programs and
network connections that don't have one.

There's an existing tool for this called `rlwrap`, but it isn't always
installed. socwrap only needs bash and one other tool (socat, section 11).

---

## 3. Processes: programs that are running

A program is a file on disk. When it's running, it's a **process**. Run
`python3` in two windows and you have one program but two processes.

> **New term: process.** A running copy of a program. Each one has a number
> called its **PID** (process ID).

Processes start other processes. When bash runs `ls`, bash is the
**parent** and `ls` is the **child**.

> **New term: parent / child process.** The process that starts another one
> is its parent. The started one is the child.

Normally bash waits for the child to finish before showing the next prompt.
Add `&` to the end of a command and bash starts it and carries on
immediately. The child runs **in the background**.

```bash
sleep 30 &      # starts sleep in the background, you get the prompt back at once
echo $!         # $! holds the PID of the last background process
```

> **New term: background process.** A child that runs alongside its parent
> instead of making the parent wait. Started with `&`.

socwrap uses several background processes at once. Part 1 draws a map of
them.

---

## 4. The three standard streams

Every process starts with three connections already open:

| Name | Short name | Usually connected to | Used for |
|------|-----------|----------------------|----------|
| standard input | **stdin** | your keyboard | what the program reads |
| standard output | **stdout** | your screen | normal output |
| standard error | **stderr** | your screen | error and status messages |

> **New term: stdin / stdout / stderr.** The three standard streams: one in,
> two out. Keeping errors separate means you can save a program's real
> output to a file and still see its errors on screen.

The shell can reconnect these streams before starting a program. That's
**redirection**:

```bash
sort < names.txt          # stdin comes from a file instead of the keyboard
ls > listing.txt          # stdout goes into a file instead of the screen
ls /nope 2> errors.txt    # stderr (stream number 2, see below) goes into a file
```

> **New term: redirection.** Using `<`, `>` or `2>` to change where a
> program's streams go.

---

## 5. File descriptors: numbered connections

Inside a process, each open connection (a file, the keyboard, a network
connection) is known by a small number. stdin is **0**, stdout is **1** and
stderr is **2**. That's why `2>` means "redirect stream 2", which is stderr.

> **New term: file descriptor (fd).** The number a process uses for one of
> its open connections. fd 0, 1 and 2 are the standard streams. New ones
> get 3, 4, 5 and so on.

bash lets a script open extra file descriptors that stay open for the rest
of the script:

```bash
exec 4> out.txt     # open out.txt for writing, as fd 4
echo hello >&4      # write to fd 4
exec 4>&-           # close fd 4
```

socwrap uses exactly this: fd 4 carries what you type and fd 5 carries
what comes back.

One rule matters a lot later, so here it is now:

> **Key fact: children inherit file descriptors.** When a process starts a
> child, the child gets a *copy* of every fd the parent has open. Closing
> fd 4 in the parent does **not** close the child's copy.

It's like a spare key: if you hand your neighbour a copy and then throw
yours away, the door can still be opened. This fact is behind
[bug 1 in Part 3](03-field-notes-bugs-and-fixes.md#bug-1-ctrl-d-hangs-until-the-other-side-hangs-up).

---

## 6. Pipes and named pipes

### Pipes

`ls | sort` sends `ls`'s stdout straight into `sort`'s stdin. The `|` sets
up a **pipe**: a one-way channel between two processes, with a writing end
and a reading end.

> **New term: pipe.** A one-way channel. One process writes into one end,
> another reads from the other end.

### End of input

How does `sort` know `ls` has finished? When **every** writer has closed
its end of the pipe, the reader gets **end of file**, usually written
**EOF**. It's the pipe's way of saying "nothing more is coming".

> **New term: EOF (end of file).** The signal to a reader that no more data
> will arrive. For a pipe, it happens only when *all* writing ends are
> closed.

You can send EOF from the keyboard by pressing **Ctrl-D** at the start of a
line. That's how you leave `python3` or `cat` politely.

Put this together with the "children inherit fds" fact from section 5: if
some child still has a copy of the writing end open, the reader **never**
gets EOF. Remember that for Part 3.

### Named pipes

An ordinary `|` pipe only works between commands on the same line. A
**named pipe** is a pipe that also has a name in the filesystem, so
unrelated processes can find it by path:

```bash
mkfifo /tmp/mypipe
cat /tmp/mypipe &          # reader waits…
echo hi > /tmp/mypipe      # …until a writer shows up. Prints "hi".
```

> **New term: named pipe, also called a FIFO** ("first in, first out").
> A pipe you can open by filename. Created with `mkfifo`.

Two things about named pipes matter for socwrap:

1. **Opening one waits.** Opening for reading waits until someone opens it
   for writing, and the other way round. Like a phone call, both people
   have to pick up.
2. **Once open, the name isn't needed.** You can delete the file and the
   pipe keeps working for the processes that already have it open.

---

## 7. Signals: tapping a process on the shoulder

A **signal** is a tiny message sent to a process. It carries no data, just
"this happened". Common ones:

| Signal | Number | Sent when | Normal effect |
|--------|--------|-----------|---------------|
| SIGINT | 2 | you press **Ctrl-C** | stop |
| SIGTERM | 15 | someone runs `kill PID` | stop |
| SIGHUP | 1 | the terminal window closes | stop |
| SIGUSR1 | 10 | only when a program chooses to send it | stop |

> **New term: signal.** A short notification sent to a process. Most
> signals stop the process unless it has arranged to handle them.
>
> **New term: SIGUSR1.** A "user-defined" signal with no built-in meaning.
> Programs use it to send each other their own messages. socwrap uses it to
> mean "the other side has gone away".

A bash script can choose what to do when a signal arrives, using `trap`:

```bash
trap 'echo "you pressed Ctrl-C"' INT    # run this instead of stopping
trap '' INT                             # ignore Ctrl-C entirely
trap - INT                              # go back to the default (stop)
```

> **New term: trap.** A bash instruction saying "when this signal arrives,
> run this code". A **default action** is what happens with no trap:
> usually the process stops.

Be careful with the last two lines. `trap ''` means **ignore** and
`trap -` means **back to the default**, which for most signals means
*stop*. Mixing them up is
[bug 6 in Part 3](03-field-notes-bugs-and-fixes.md#bug-6-a-late-sigusr1-can-stop-socwrap-while-it-shuts-down).

bash also has a special trap called **EXIT**. Its code runs whenever the
script ends, for any reason. It's the natural place for tidying up.

---

## 8. Exit status: how a program says how it went

Every process ends with a number, its **exit status**. `0` means success.
Anything else means something went wrong. `$?` holds the status of the last
command:

```bash
ls /;     echo $?   # 0
ls /nope; echo $?   # 2
```

> **New term: exit status (or exit code).** A number from 0 to 255 that a
> process leaves behind when it ends. 0 means OK.

When a process is stopped by a signal, the shell reports **128 plus the
signal number**. Ctrl-C (signal 2) gives 130, and SIGUSR1 (signal 10) gives
138. You'll see both numbers in the code.

The parent can **wait** for a child to end and collect its exit status:

```bash
sleep 2 &
wait $!        # pauses until sleep ends; $? is now sleep's exit status
```

> **New term: wait / reaping.** A parent collecting a finished child's exit
> status. Programmers call this "reaping" the child.

---

## 9. Real terminals and fake ones

A program can ask "is my stdin a real terminal, meaning a person is
typing?" Many programs behave differently depending on the answer:

- `python3` only shows its `>>>` prompt when talking to a terminal.
- bash only shows its own prompt when talking to a terminal.
- `ls` prints in columns for a terminal and one name per line for a pipe.

So if you connect a program to a pipe (as socwrap does), it may go quiet
and stop showing its prompt. The fix is a fake terminal.

> **New term: PTY (pseudo-terminal).** A fake terminal made in software. To
> the program it looks exactly like a real one, but the other end is
> another program instead of a person.

Terminals also have **echo**: when you type a letter, the terminal shows it
back to you. That's why you can see what you're typing, and why password
prompts turn echo off. If readline has already displayed your line and a
PTY echoes it again, you see everything twice. socwrap turns PTY echo off
to avoid that.

> **New term: echo.** The terminal showing you the characters you type.

---

## 10. Networks in ten minutes

socwrap Phase 2 connects to things over the network, so here are those
words.

**Host and port.** A **host** is a machine, named like `example.com` or
numbered like `192.168.1.1`. `127.0.0.1` always means "this machine". A
**port** is a numbered door on that host (1 to 65535), and each service
listens behind its own door: web on 80, SSH on 22, telnet on 23.

> **New term: host, port.** A host is a machine and a port is a numbered
> service on it. Written together as `host:port`, as in `example.com:80`.

**Socket.** Programs talk over the network through a **socket**, which
behaves a lot like the file descriptors from section 5: you write to it
and read from it.

> **New term: socket.** One end of a network conversation, used like a
> file descriptor.

There are different kinds of connection:

| Kind | Everyday comparison | Key property |
|------|---------------------|--------------|
| **TCP** | a phone call | You "dial" first (the **handshake**), then talk both ways. Nothing is lost and the order is kept. If nobody answers, you get **connection refused**. |
| **UDP** | posting postcards | No dialling. Each message (a **datagram**) is sent on its own. It might get lost, and nobody tells you if nobody is there. |
| **Unix socket** | an intercom between rooms of the same house | Like TCP, but only between programs on the same machine. Its address is a file path such as `/run/app.sock`. |

> **New term: TCP, UDP, Unix socket.** Three kinds of connection:
> dependable phone call, fire-and-forget postcard, same-machine intercom.
>
> **New term: handshake.** The short exchange at the start of a TCP
> connection. A **connect timeout** is how long you wait for it before
> giving up.

**TLS.** Plain TCP travels in the clear, so anyone on the path could read
it. **TLS** wraps the connection in encryption (it's the "S" in HTTPS).
The server proves who it is with a **certificate**, a digital ID card that
your side checks: **certificate verification**. A **self-signed**
certificate is one the server made for itself. That's fine in a test lab,
but your side will refuse it unless you tell it not to check.

> **New term: TLS, certificate, verification.** Encryption for a
> connection; the server's ID card; checking that ID card.

**Protocols and line endings.** A **protocol** is the agreed set of rules
for a conversation. For example, HTTP says "send `GET /page`, then
headers, then a blank line". Many older protocols (HTTP, email's SMTP,
POP3, IMAP) are **line-based**: you send a line of text and get lines back.
That's what makes a readline prompt useful for them. They expect each line
to end with two invisible characters, **carriage return + line feed**,
written **CRLF** or `\r\n`. Linux normally ends lines with just a line
feed, **LF** or `\n`.

> **New term: protocol.** The rules of a conversation.
>
> **New term: CRLF vs LF.** Two ways to end a line. Network protocols often
> want CRLF (`\r\n`), while Linux uses LF (`\n`).

**SSH and telnet.** Both let you log in to a remote machine's shell.
**SSH** is modern and encrypted. **telnet** is old, unencrypted, and still
found on routers and lab equipment. telnet mixes invisible control codes
into its text, which Part 2 explains when we need them.

---

## 11. socat: the universal adapter

**socat** is a command-line tool that connects any two things and copies
data between them in both directions. Think of a travel adapter with two
sockets: whatever goes in one side comes out the other.

Each side is described by an **address**, which is a string saying what
to connect to:

| socat address | Means |
|---------------|-------|
| `-` | socat's own stdin and stdout |
| `TCP:example.com:80` | a TCP connection to example.com, port 80 |
| `UDP:10.0.0.5:514` | UDP to 10.0.0.5, port 514 |
| `UNIX-CONNECT:/run/app.sock` | a Unix socket |
| `OPENSSL:example.com:443` | TCP with TLS on top |
| `EXEC:python3` | start `python3` and talk to its stdin and stdout |

> **New term: socat address.** A string that tells socat what one side of
> the connection is. Extra settings go after commas, like
> `TCP:host:80,connect-timeout=10`. These are **address options**.

So:

```bash
socat - TCP:example.com:80
```

means "connect my keyboard and screen to example.com port 80". That's
already a working network client, but with no arrow keys or history.

socat does have a built-in readline address, but it has a quirk (the
prompt doesn't appear until you press a key) and many systems install
socat without it. socwrap doesn't use it. It builds its own readline layer
instead.

---

## 12. Putting it together

Here's the sentence from the top again. Every word in it now has a
meaning:

> *socwrap runs a **readline** loop in **bash**, writes each line you type
> into a **named pipe** that feeds **socat**'s **stdin**, and a
> **background process** copies socat's **stdout** back to your
> **terminal**. socat connects to a **TCP socket**, a **Unix socket**, or a
> program running on a **pseudo-terminal**.*

Or in picture form:

```
 you type ──► [ bash + readline ] ──named pipe──► [ socat ] ──► the program or server
                                                       │
 your screen ◄── [ copier ] ◄───── named pipe ◄────────┘
```

Part 1 opens that picture up and walks through the code that builds it.

**Next: [Part 1, the core bridge (Phase 1)](01-phase1-core-bridge.md)**
