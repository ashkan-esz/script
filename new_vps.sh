#!/bin/bash
# set -e

echo "[+] Creating user -> gang:Gang!@#123 "
useradd -m gang || true
echo "gang:Gang!@#123" | chpasswd

echo "[+] Updating system"
apt-get update
apt-get install -y \
  ca-certificates curl gnupg unzip htop make sudo \
  iptables-persistent

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

sysctl --system || true

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

echo "[+] Installing master dns vpn: 953c72f45cc7518051016382586d7a87 --> encrypt_key.txt"
echo '953c72f45cc7518051016382586d7a87' > /root/encrypt_key.txt

echo "[+] Installing master dns vpn: adding server_config.toml"
curl -Ls https://raw.githubusercontent.com/ashkan-esz/script/main/master_dns_g69_server_config.toml -o /root/server_config.toml

echo "[+] Installing master dns vpn script (c.g69.lol)"
bash <(curl -Ls https://raw.githubusercontent.com/masterking32/MasterDnsVPN/main/server_linux_install.sh) --version v2026.04.05.191930-7757d2d

echo "[+] Installing new_vps_xray.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || {
  echo "[!] Could not determine the directory containing new_vps.sh" >&2
  exit 1
}
XRAY_INSTALLER="$SCRIPT_DIR/new_vps_xray.sh"
if [[ ! -f $XRAY_INSTALLER ]]; then
  echo "[!] Missing local Xray installer: $XRAY_INSTALLER" >&2
  echo "    Keep new_vps.sh and new_vps_xray.sh in the same directory." >&2
  exit 1
fi
bash "$XRAY_INSTALLER"


echo "[+] Configuring SSH reverse tunneling..."
SSHD_CONFIG="/etc/ssh/sshd_config"
# Backup
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup.$(date +%Y%m%d-%H%M%S)"

# Enable TCP forwarding
if grep -qE '^[#[:space:]]*AllowTcpForwarding' "$SSHD_CONFIG"; then
    sed -i 's/^[#[:space:]]*AllowTcpForwarding.*/AllowTcpForwarding yes/' "$SSHD_CONFIG"
else
    echo "AllowTcpForwarding yes" >> "$SSHD_CONFIG"
fi

# Allow reverse tunnel ports to bind publicly
if grep -qE '^[#[:space:]]*GatewayPorts' "$SSHD_CONFIG"; then
    sed -i 's/^[#[:space:]]*GatewayPorts.*/GatewayPorts yes/' "$SSHD_CONFIG"
else
    echo "GatewayPorts yes" >> "$SSHD_CONFIG"
fi

# Validate SSH configuration before restarting
echo "[+] Checking SSH configuration..."
sshd -t

echo "==> Restarting SSH..."
systemctl restart ssh

# Configure UFW if installed/enabled
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    echo "==> Opening TCP port $PORT in UFW..."
    ufw allow "$PORT/tcp"
fi

echo "[✓] Server setup complete"

echo "[+] Better to change the password"
