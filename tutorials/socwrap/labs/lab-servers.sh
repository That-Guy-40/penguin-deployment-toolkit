#!/usr/bin/env bash
# lab-servers.sh — throwaway local targets for the socwrap phase 2 labs.
#
#   bash lab-servers.sh start    # start every server in the background
#   bash lab-servers.sh status   # show what is listening
#   bash lab-servers.sh stop     # kill them and remove the lab directory
#
# Every server listens on 127.0.0.1 only and echoes what you send, prefixed
# with its transport name so you can tell them apart:
#
#   tcp     127.0.0.1:7001          "tcp: <line>"
#   udp     127.0.0.1:7002          "udp: <line>"
#   unix    $LAB_DIR/echo.sock      "unix: <line>"
#   tls     127.0.0.1:7003          "tls: <line>"   (self-signed cert)
#   telnet  127.0.0.1:7004          sends IAC WILL ECHO + IAC WILL SGA +
#                                   IAC SB TTYPE SEND IAC SE, then "login: "
#                                   with NO newline, then echoes lines
#
# Requires: socat; openssl for the TLS server (skipped if missing).
set -euo pipefail

LAB_DIR="${LAB_DIR:-/tmp/socwrap-lab}"
PIDFILE="$LAB_DIR/pids"

_echo_loop() {   # $1 = label; used as the per-connection handler
    printf 'while IFS= read -r l; do printf "%%s: %%s\\n" %q "$l"; done' "$1"
}

start() {
    command -v socat >/dev/null || { echo "socat not found" >&2; exit 1; }
    mkdir -p "$LAB_DIR"
    : > "$PIDFILE"

    # The per-connection handlers are written to files so that no quoting or
    # backslashes have to survive socat's own address parser.
    for proto in tcp udp unix tls; do
        printf '#!/usr/bin/env bash\n%s\n' "$(_echo_loop "$proto")" > "$LAB_DIR/echo-$proto.sh"
        chmod +x "$LAB_DIR/echo-$proto.sh"
    done

    cat > "$LAB_DIR/telnetd.sh" <<'EOF'
#!/usr/bin/env bash
# IAC WILL ECHO, IAC WILL SGA, IAC SB TTYPE SEND IAC SE, then a prompt with no newline
printf '\xff\xfb\x01\xff\xfb\x03\xff\xfa\x18\x01\xff\xf0'
printf 'Welcome to lab-router\r\nlogin: '
while IFS= read -r l; do printf 'router: %s\r\n' "${l%$'\r'}"; done
EOF
    chmod +x "$LAB_DIR/telnetd.sh"

    socat TCP-LISTEN:7001,bind=127.0.0.1,reuseaddr,fork EXEC:"$LAB_DIR/echo-tcp.sh" &
    echo $! >> "$PIDFILE"
    socat UDP-RECVFROM:7002,bind=127.0.0.1,reuseaddr,fork EXEC:"$LAB_DIR/echo-udp.sh" &
    echo $! >> "$PIDFILE"
    rm -f "$LAB_DIR/echo.sock"
    socat UNIX-LISTEN:"$LAB_DIR/echo.sock",fork EXEC:"$LAB_DIR/echo-unix.sh" &
    echo $! >> "$PIDFILE"
    socat TCP-LISTEN:7004,bind=127.0.0.1,reuseaddr,fork EXEC:"$LAB_DIR/telnetd.sh" &
    echo $! >> "$PIDFILE"

    if command -v openssl >/dev/null; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
            -keyout "$LAB_DIR/key.pem" -out "$LAB_DIR/cert.pem" 2>/dev/null
        cat "$LAB_DIR/key.pem" "$LAB_DIR/cert.pem" > "$LAB_DIR/server.pem"
        socat OPENSSL-LISTEN:7003,bind=127.0.0.1,reuseaddr,fork,cert="$LAB_DIR/server.pem",verify=0 \
            EXEC:"$LAB_DIR/echo-tls.sh" &
        echo $! >> "$PIDFILE"
    else
        echo "openssl not found; skipping the TLS server" >&2
    fi

    sleep 0.3
    status
}

status() {
    if [[ ! -s "$PIDFILE" ]]; then echo "no lab servers running"; return; fi
    while read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
            printf '%-7s %s\n' "$pid" "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-90)"
        fi
    done < "$PIDFILE"
}

stop() {
    [[ -f "$PIDFILE" ]] && while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$PIDFILE"
    rm -rf "$LAB_DIR"
    echo "lab servers stopped"
}

case "${1:-}" in
    start)  start ;;
    status) status ;;
    stop)   stop ;;
    *)      echo "usage: $0 start|status|stop" >&2; exit 2 ;;
esac
