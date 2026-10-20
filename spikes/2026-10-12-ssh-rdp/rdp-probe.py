#!/usr/bin/env python3
"""rdp-probe.py <host> <port> - the first exchange of the RDP protocol only:
an X.224 Connection Request offering TLS and CredSSP(NLA); the server's
Connection Confirm says which it selected. Proves there is an RDP listener
and that it insists on NLA; proves nothing about credentials (that is
xfreerdp /auth-only's job)."""
import socket, struct, sys
host, port = sys.argv[1], int(sys.argv[2])
# TPKT + X.224 CR + rdpNegReq(requestedProtocols = TLS|CredSSP = 0x3)
neg = struct.pack("<BBHI", 1, 0, 8, 0x3)
x224 = bytes([len(neg) + 6, 0xE0, 0, 0, 0, 0, 0]) + neg
pkt = struct.pack(">BBH", 3, 0, 4 + len(x224)) + x224
try:
    s = socket.create_connection((host, port), timeout=10)
except OSError as e:
    print(f"no connection: {e}"); sys.exit(2)
s.sendall(pkt)
try:
    resp = s.recv(64)
except TimeoutError:
    print("connected but no RDP answer in 10 s (the guest port is closed: QEMU's hostfwd accepts regardless)"); sys.exit(2)
finally:
    s.close()
if len(resp) < 11 or resp[0] != 3:
    print(f"not RDP: {resp!r}"); sys.exit(3)
typ = resp[11] if len(resp) > 11 else None
if typ == 2:
    proto = struct.unpack_from("<I", resp, 15)[0]
    print({0: "standard RDP security", 1: "TLS", 2: "CredSSP (NLA)", 3: "TLS+CredSSP", 8: "RDSTLS"}.get(proto, f"protocol {proto}"), "selected by the server")
    sys.exit(0)
if typ == 3:
    print("server refused the negotiation (rdpNegFailure)", resp[15] if len(resp) > 15 else "")
    sys.exit(1)
print("X.224 Connection Confirm without a negotiation response:", resp.hex()); sys.exit(0)
