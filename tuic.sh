sudo apt update && sudo apt upgrade -y  && sudo apt install nano net-tools uuid-runtime wget htop jq -y

mkdir tuic && cd tuic

wget -O tuic-server https://github.com/EAimTY/tuic/releases/download/tuic-server-1.0.0/tuic-server-1.0.0-x86_64-unknown-linux-gnu && chmod 755 tuic-server

openssl ecparam -genkey -name prime256v1 -out ca.key
openssl req -new -x509 -days 36500 -key ca.key -out ca.crt  -subj "/CN=bing.com"

uuidgen # run per needed user, save these

cat <<EOF | jq . > config.json
{
  "server": "[::]:5858",
  "users": {
    "6d2c3208-0daa-4d80-9626-f6322858f85a": "user1pass",
    "006d2a41-384f-4a88-87e8-c8e2df7bd20c": "user2pass"
  },
  "certificate": "/root/tuic/ca.crt",
  "private_key": "/root/tuic/ca.key",
  "congestion_control": "bbr",
  "alpn": ["h3", "spdy/3.1"],
  "udp_relay_ipv6": true,
  "zero_rtt_handshake": false,
  "dual_stack": true,
  "auth_timeout": "3s",
  "task_negotiation_timeout": "3s",
  "max_idle_time": "10s",
  "max_external_packet_size": 1500,
  "send_window": 16777216,
  "receive_window": 8388608,
  "gc_interval": "3s",
  "gc_lifetime": "15s",
 "log_level": "warn"
}
EOF

# ./tuic-server -c config.json ## checking server running, then closing

cat <<EOF > /etc/systemd/system/tuic.service
[Unit]
Description=tuic service
Documentation=by iSegaro
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/root/tuic/tuic-server -c /root/tuic/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tuic
systemctl start tuic
systemctl status tuic
