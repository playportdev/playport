#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run as root, once: the workstation side of driving the phone away from home
# (docs/DEVICE.md, "Away from home"). Forwarding on, ICMP redirects off on the LAN
# interface, jit-reflect.nft installed, and Arch's /etc/nftables.conf given the
# forward accept line and the include (backup: /etc/nftables.conf.bak). Idempotent.
#   sudo tools/net/install-workstation.sh [LAN_IF]   (default: the default route's)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
IF=${1:-$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')}
[ -n "$IF" ] || { echo "no LAN interface: pass it" >&2; exit 2; }
grep -q 'chain forward' /etc/nftables.conf && grep -A3 'chain forward' /etc/nftables.conf | grep -q 'policy drop' ||
    { echo "/etc/nftables.conf has no forward chain with policy drop: add one first (DEVICE.md)" >&2; exit 2; }
cat > /etc/sysctl.d/90-playport-jit-reflect.conf <<X
net.ipv4.ip_forward = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.$IF.send_redirects = 0
X
sysctl --system > /dev/null
install -Dm644 "$HERE/jit-reflect.nft" /etc/nftables.d/playport-jit-reflect.nft
[ -f /etc/nftables.conf.bak ] || cp /etc/nftables.conf /etc/nftables.conf.bak
grep -q 'ct original ip daddr 10.7.0.1 accept' /etc/nftables.conf ||
    sed -i '/chain forward {/,/}/ s|^\(\s*\)policy drop$|&\n\1ct status dnat ct original ip daddr 10.7.0.1 accept comment "Playport: JIT reflection for the phone on WireGuard"|' /etc/nftables.conf
grep -q 'playport-jit-reflect.nft' /etc/nftables.conf ||
    printf '\ninclude "/etc/nftables.d/playport-jit-reflect.nft"\n' >> /etc/nftables.conf
nft -c -f /etc/nftables.conf
systemctl enable nftables
systemctl restart nftables   # Arch's unit has no reload
sysctl net.ipv4.ip_forward "net.ipv4.conf.$IF.send_redirects"
nft list chain inet filter forward
nft list table ip playport_jit_reflect
