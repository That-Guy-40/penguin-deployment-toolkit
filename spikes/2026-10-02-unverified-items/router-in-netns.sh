#!/bin/bash
# A stand-in for "the LAN's own DHCP server": a second dnsmasq in its own
# network namespace, joined to br0 by a veth pair. It hands out addresses and
# nothing else (no boot file, no next-server).
set -e
cd "$(dirname "$0")/.."
ip link add veth-r type veth peer name veth-r-ns
ip link set veth-r master br0
ip link set veth-r up
setsid unshare -n sleep infinity >/dev/null 2>&1 &
RPID=$!
sleep 0.5
echo $RPID > run/router-ns.pid
ip link set veth-r-ns netns $RPID
nsenter -t $RPID -n ip link set lo up
nsenter -t $RPID -n ip addr add 10.42.0.254/24 dev veth-r-ns
nsenter -t $RPID -n ip link set veth-r-ns up
setsid nsenter -t $RPID -n dnsmasq --no-daemon --conf-file=/dev/null --port=0 --interface=veth-r-ns --bind-interfaces \
    --dhcp-authoritative --dhcp-range=10.42.0.100,10.42.0.150,1h --dhcp-option=3,10.42.0.254 \
    --dhcp-leasefile=run/router.leases --log-dhcp --log-facility=run/router-dnsmasq.log > run/router.out 2>&1 &
echo $! > run/router-dnsmasq.pid
sleep 0.5
kill -0 $(cat run/router-dnsmasq.pid) && echo "router dnsmasq up in its own netns (10.42.0.254), pid $(cat run/router-dnsmasq.pid)"
