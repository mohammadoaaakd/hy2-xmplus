#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default Settings (Edit after install via 'xr' -> Option 6)
API_HOST="https://panel.gameping.top"
API_KEY="YOUR_API_KEY_HERE"
NODE_ID=0

clear
echo -e "${CYAN}===========================================${NC}"
echo -e "${CYAN}   Xray (VLESS REALITY) + XMPlus Installer ${NC}"
echo -e "${CYAN}===========================================${NC}"

echo -e "\n${YELLOW}[1/4] Installing dependencies & latest Xray-core...${NC}"
apt update -y && apt install -y curl python3 nano
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
mkdir -p /etc/xray-xmplus /usr/local/etc/xray

echo -e "\n${YELLOW}[2/4] Creating XMPlus Xray Bridge script...${NC}"
cat << EOF > /etc/xray-xmplus/bridge.py
import json, time, subprocess, urllib.request, re

API_HOST = "${API_HOST}"
API_KEY  = "${API_KEY}"
NODE_ID  = ${NODE_ID}
XRAY_CFG = "/usr/local/etc/xray/config.json"
API_ADDR = "127.0.0.1:10085"

last_hash = None

def api_get(path):
    url = f"{API_HOST}{path}?key={API_KEY}"
    req = urllib.request.Request(url, headers={"User-Agent": "XMPlus-Xray/2.0"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode())

def api_post(path, payload):
    url = f"{API_HOST}{path}?key={API_KEY}"
    req = urllib.request.Request(
        url,
        data=json.dumps({"data": payload}).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "XMPlus-Xray/2.0"},
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return resp.status

def sync_config():
    global last_hash
    try:
        srv_data = api_get(f"/api/v2/query/server/{NODE_ID}").get("server", {})
        usr_data = api_get(f"/api/v2/query/users/{NODE_ID}").get("users", [])
    except Exception as e:
        print(f"[Sync Error] {e}", flush=True)
        return

    port = int(srv_data.get("listeningport") or 443)
    listen_ip = srv_data.get("listenip") or "0.0.0.0"
    sec = srv_data.get("securitySettings") or {}
    net = srv_data.get("networkSettings") or {}
    flow = net.get("flow") or ""

    clients = []
    for u in usr_data:
        uid = u.get("uuid") or u.get("passwd")
        if uid:
            c = {"id": uid, "email": str(u.get("id"))}
            if flow:
                c["flow"] = flow
            clients.append(c)

    reality_settings = {
        "show": bool(sec.get("show", False)),
        "dest": sec.get("dest", "www.google.com:443"),
        "xver": int(sec.get("proxyprotocol") or 0),
        "serverNames": sec.get("serverNames") or ["www.google.com"],
        "privateKey": sec.get("privatekey") or sec.get("privateKey") or "",
        "shortIds": sec.get("shortids") or sec.get("shortIds") or [""]
    }

    config = {
        "log": {"loglevel": "warning"},
        "api": {"tag": "api", "services": ["StatsService"]},
        "stats": {},
        "policy": {
            "levels": {
                "0": {
                    "statsUserUplink": True,
                    "statsUserDownlink": True,
                    "statsUserOnline": True
                }
            },
            "system": {"statsInboundUplink": False, "statsInboundDownlink": False}
        },
        "inbounds": [
            {
                "tag": "api",
                "listen": "127.0.0.1",
                "port": 10085,
                "protocol": "dokodemo-door",
                "settings": {"address": "127.0.0.1"}
            },
            {
                "tag": "vless-in",
                "listen": listen_ip,
                "port": port,
                "protocol": "vless",
                "settings": {
                    "clients": clients,
                    "decryption": "none"
                },
                "streamSettings": {
                    "network": srv_data.get("network") or "tcp",
                    "security": "reality",
                    "realitySettings": reality_settings,
                    "tcpSettings": {
                        "acceptProxyProtocol": bool(net.get("acceptProxyProtocol", False)),
                        "header": net.get("header") or {"type": "none"}
                    }
                },
                "sniffing": {
                    "enabled": bool(srv_data.get("sniffing", True)),
                    "destOverride": ["http", "tls", "quic"]
                }
            }
        ],
        "outbounds": [
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"}
        ],
        "routing": {
            "rules": [
                {"inboundTag": ["api"], "outboundTag": "api", "type": "field"}
            ]
        }
    }

    cfg_str = json.dumps(config, indent=2, sort_keys=True)
    if cfg_str != last_hash:
        with open(XRAY_CFG, "w") as f:
            f.write(cfg_str)
        subprocess.run(["systemctl", "restart", "xray"])
        last_hash = cfg_str
        print(f"[Config] Applied port={port}, users={len(clients)}", flush=True)

def report_stats():
    try:
        out = subprocess.check_output(
            ["/usr/local/bin/xray", "api", "statsquery", f"--server={API_ADDR}", "-reset"],
            stderr=subprocess.DEVNULL
        ).decode()
        stats = json.loads(out).get("stat", [])
    except Exception:
        return

    traffic = {}
    for item in stats:
        name = item.get("name", "")
        val = int(item.get("value", 0))
        if val <= 0:
            continue
        m = re.match(r"user>>>(\d+)>>>traffic>>>(uplink|downlink)", name)
        if m:
            uid, direction = int(m.group(1)), m.group(2)
            traffic.setdefault(uid, {"u": 0, "d": 0})
            if direction == "uplink":
                traffic[uid]["u"] += val
            else:
                traffic[uid]["d"] += val

    if traffic:
        payload = [{"userid": uid, "u": v["u"], "d": v["d"]} for uid, v in traffic.items()]
        try:
            status = api_post(f"/api/v2/query/users/traffic/{NODE_ID}", payload)
            print(f"[Traffic] Reported {len(payload)} users (HTTP {status}).", flush=True)
        except Exception as e:
            print(f"[Traffic Error] {e}", flush=True)

    online_payload = []
    for uid in traffic.keys():
        try:
            out_ip = subprocess.check_output(
                ["/usr/local/bin/xray", "api", "statsonlineiplist", f"--server={API_ADDR}", f"--email={uid}"],
                stderr=subprocess.DEVNULL
            ).decode()
            ips = json.loads(out_ip).get("ips", {})
            for ip in ips.keys():
                online_payload.append({"userid": uid, "ip": ip})
        except Exception:
            continue

    if online_payload:
        try:
            status = api_post(f"/api/v2/query/users/online/{NODE_ID}", online_payload)
            print(f"[OnlineIP] Reported {len(online_payload)} IPs (HTTP {status}).", flush=True)
        except Exception as e:
            print(f"[OnlineIP Error] {e}", flush=True)

if __name__ == "__main__":
    while True:
        sync_config()
        time.sleep(60)
        report_stats()
EOF

echo -e "\n${YELLOW}[3/4] Creating systemd service...${NC}"
cat << 'EOF' > /etc/systemd/system/xray-xmplus-bridge.service
[Unit]
Description=XMPlus Bridge for Xray VLESS REALITY
After=network.target

[Service]
ExecStart=/usr/bin/python3 /etc/xray-xmplus/bridge.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray-xmplus-bridge xray

echo -e "\n${YELLOW}[4/4] Installing 'xr' management menu...${NC}"
cat << 'EOF' > /usr/local/bin/xr
#!/bin/bash
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
BRIDGE_FILE="/etc/xray-xmplus/bridge.py"

check_status() { systemctl is-active --quiet "$1" && echo -e "${GREEN}Active${NC}" || echo -e "${RED}Stopped${NC}"; }

while true; do
    clear
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}    Xray (VLESS REALITY) + XMPlus        ${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo -e " Xray Core     : $(check_status xray)"
    echo -e " XMPlus Bridge : $(check_status xray-xmplus-bridge)"
    echo -e "${CYAN}-----------------------------------------${NC}"
    echo -e " ${GREEN}1)${NC} Start Services"
    echo -e " ${RED}2)${NC} Stop Services"
    echo -e " ${YELLOW}3)${NC} Restart Services"
    echo -e " ${CYAN}4)${NC} Live Bridge Logs (Sync, Traffic & IP)"
    echo -e " ${CYAN}5)${NC} Live Xray Core Logs"
    echo -e " ${CYAN}6)${NC} Edit bridge.py (API_KEY & NODE_ID)"
    echo -e " ${GREEN}7)${NC} Update Xray Core to Latest"
    echo -e " ${RED}0)${NC} Exit"
    echo -e "${CYAN}=========================================${NC}"
    read -p "Select an option [0-7]: " choice
    case $choice in
        1) systemctl start xray xray-xmplus-bridge; sleep 1 ;;
        2) systemctl stop xray xray-xmplus-bridge; sleep 1 ;;
        3) systemctl restart xray xray-xmplus-bridge; sleep 1 ;;
        4) journalctl -u xray-xmplus-bridge -f --no-pager ;;
        5) journalctl -u xray -f --no-pager ;;
        6) nano "$BRIDGE_FILE" ;;
        7) bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; systemctl restart xray; read -p "Press Enter..." ;;
        0) exit 0 ;;
    esac
done
EOF
chmod +x /usr/local/bin/xr

echo -e "\n${GREEN}===========================================${NC}"
echo -e "${GREEN} Installation Complete!${NC}"
echo -e "${YELLOW} Next steps:${NC}"
echo -e " 1. Type 'xr' and press 6 to set API_KEY & NODE_ID"
echo -e " 2. Press 3 to restart services"
echo -e "${GREEN}===========================================${NC}"
