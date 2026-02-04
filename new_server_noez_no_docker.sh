#!/bin/bash
# set -e

echo "[+] Creating users"
useradd -m amene || true
echo "amene:amene2828" | chpasswd

echo "[+] Updating system"
apt-get update
apt-get install -y \
  ca-certificates curl gnupg unzip htop make sudo \
  iptables-persistent

systemctl enable systemd-networkd-wait-online.service

# Disable systemd-resolved safely
if systemctl is-active --quiet systemd-resolved; then
    systemctl disable --now systemd-resolved
fi

if [ -L /etc/resolv.conf ] || [ -f /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
fi
echo "nameserver 127.0.0.1" > /etc/resolv.conf
chattr +i /etc/resolv.conf || echo "[!] Warning: failed to lock /etc/resolv.conf"


echo "[+] Installing Unbound"
apt-get install -y unbound

echo "[+] Configuring Unbound (lightweight, VPS-safe)"
mkdir -p /etc/unbound/unbound.conf.d
cat >/etc/unbound/unbound.conf.d/sshuttle.conf <<EOF
server:
  interface: 127.0.0.1
  access-control: 127.0.0.0/8 allow

  do-ip4: yes
  do-ip6: no
  do-udp: yes
  do-tcp: yes

  edns-buffer-size: 1232
  prefetch: yes
  cache-min-ttl: 300
  cache-max-ttl: 86400

  msg-cache-size: 8m
  rrset-cache-size: 16m

  so-rcvbuf: 1m
  so-sndbuf: 1m

  hide-identity: yes
  hide-version: yes
EOF

# Ensure Unbound starts after network is fully online
mkdir -p /etc/systemd/system/unbound.service.d
cat >/etc/systemd/system/unbound.service.d/override.conf <<EOF
[Unit]
After=network-online.target
Wants=network-online.target
EOF

systemctl daemon-reexec
systemctl enable --now unbound || echo "[!] Warning: failed to enable/start Unbound"

echo "[+] Enabling fq"
cat >/etc/sysctl.d/99-sshuttle.conf <<EOF
net.core.default_qdisc = fq
EOF

# echo "[+] Enabling BBR + fq"
# cat >/etc/sysctl.d/99-sshuttle.conf <<EOF
# net.core.default_qdisc = fq
# net.ipv4.tcp_congestion_control = bbr
# EOF

echo "[+] Disabling IPv6"
cat >/etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

sysctl --system

echo "[+] Adding TCP MSS clamping"
iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
  -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
  -j TCPMSS --clamp-mss-to-pmtu

netfilter-persistent save

echo "[+] Basic SSH tuning"
sed -i 's/^#\?TCPKeepAlive.*/TCPKeepAlive yes/' /etc/ssh/sshd_config
sed -i 's/^#\?ClientAliveInterval.*/ClientAliveInterval 30/' /etc/ssh/sshd_config
sed -i 's/^#\?ClientAliveCountMax.*/ClientAliveCountMax 3/' /etc/ssh/sshd_config
sed -i 's/^#\?Compression.*/Compression no/' /etc/ssh/sshd_config
sed -i 's/^#\?UseDNS.*/UseDNS no/' /etc/ssh/sshd_config || echo "UseDNS no" >> /etc/ssh/sshd_config

sed -i 's/^#\?Ciphers.*/Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com/' /etc/ssh/sshd_config || \
echo "Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com" >> /etc/ssh/sshd_config

systemctl restart ssh

echo "[+] Disabling unnecessary services (safe on small VPS)"
systemctl disable --now snapd 2>/dev/null || true
systemctl disable --now unattended-upgrades 2>/dev/null || true

echo "[✓] Server setup complete"
