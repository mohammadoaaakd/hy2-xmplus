#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default Settings (Edit after install via 'hs' -> Option 9)
API_HOST="https://panel.gameping.top"
API_KEY="YOUR_API_KEY_HERE"
NODE_ID=0
STATS_SECRET="xmplus_hy2_secret_2026"

clear
echo -e "${CYAN}===========================================${NC}"
echo -e "${CYAN}   Hysteria 2 + XMPlus One-Click Installer ${NC}"
echo -e "${CYAN}===========================================${NC}"

echo -e "\n${YELLOW}[1/4] Installing dependencies & Hysteria 2...${NC}"
apt update -y && apt install -y curl python3 certbot nano
bash <(curl -fsSL https://get.hy2.sh/)
mkdir -p /etc/hysteria

echo -e "\n${YELLOW}[2/4] Creating XMPlus Bridge script...${NC}"
cat << EOF > /etc/hysteria/xmplus_bridge.py
import json, time, threading, subprocess, urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler

API_HOST     = "${API_HOST}"
API_KEY      = "${API_KEY}"
NODE_ID      = ${NODE_ID}
STATS_URL    = "http://127.0.0.1:19090/traffic?clear=1"
STATS_SECRET = "${STATS_SECRET}"
AUTH_PORT    = 18080

users_by_uuid = {}
online_ips = {}
users_lock = threading.Lock()
last_config_state = None

def sync_server_config():
    global last_config_state
    url = f"{API_HOST}/api/v2/query/server/{NODE_ID}?key={API_KEY}"
    req = urllib.request.Request(url, headers={"User-Agent": "XMPlus-Hy2/2.0"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
            srv = data.get("server", {})
            listen_port = int(srv.get("listeningport") or 2093)
            state = (listen_port,)
            if state != last_config_state:
                cfg = f"""listen: :{listen_port}
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
auth:
  type: http
  http:
    url: http://127.0.0.1:{AUTH_PORT}/auth
ignoreClientBandwidth: true
trafficStats:
  listen: 127.0.0.1:19090
  secret: {STATS_SECRET}
"""
                with open("/etc/hysteria/config.yaml", "w") as f:
                    f.write(cfg)
                subprocess.run(["systemctl", "restart", "hysteria-server"])
                last_config_state = state
                print(f"[Config] Applied port={listen_port}", flush=True)
    except Exception as e:
        print(f"[Config Error] {e}", flush=True)

def fetch_users():
    global users_by_uuid
    url = f"{API_HOST}/api/v2/query/users/{NODE_ID}?key={API_KEY}"
    req = urllib.request.Request(url, headers={"User-Agent": "XMPlus-Hy2/2.0"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
            new_map = {}
            for u in data.get("users", []):
                uuid = u.get("uuid") or u.get("passwd")
                if uuid:
                    new_map[uuid] = {"id": u.get("id"), "email": u.get("email", "")}
            with users_lock:
                users_by_uuid = new_map
            print(f"[Sync] Loaded {len(new_map)} users.", flush=True)
    except Exception as e:
        print(f"[Sync Error] {e}", flush=True)

def report_traffic():
    try:
        req = urllib.request.Request(STATS_URL, headers={"Authorization": STATS_SECRET})
        with urllib.request.urlopen(req, timeout=5) as resp:
            stats = json.loads(resp.read().decode())
    except Exception:
        return
    payload = []
    for uid_str, st in stats.items():
        tx, rx = int(st.get("tx", 0)), int(st.get("rx", 0))
        if tx == 0 and rx == 0:
            continue
        try:
            payload.append({"userid": int(uid_str), "u": tx, "d": rx})
        except ValueError:
            continue
    if not payload:
        return
    url = f"{API_HOST}/api/v2/query/users/traffic/{NODE_ID}?key={API_KEY}"
    req = urllib.request.Request(url, data=json.dumps({"data": payload}).encode(), headers={"Content-Type": "application/json", "User-Agent": "XMPlus-Hy2/2.0"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            print(f"[Traffic] Reported {len(payload)} users (HTTP {resp.status}).", flush=True)
    except Exception as e:
        print(f"[Traffic Error] {e}", flush=True)

def report_online_ips():
    try:
        req = urllib.request.Request("http://127.0.0.1:19090/online", headers={"Authorization": STATS_SECRET})
        with urllib.request.urlopen(req, timeout=5) as resp:
            online_users = json.loads(resp.read().decode())
    except Exception:
        return
    payload = []
    for uid_str, count in online_users.items():
        if int(count) > 0 and uid_str in online_ips:
            try:
                payload.append({"userid": int(uid_str), "ip": online_ips[uid_str]})
            except ValueError:
                continue
    if not payload:
        return
    url = f"{API_HOST}/api/v2/query/users/online/{NODE_ID}?key={API_KEY}"
    req = urllib.request.Request(url, data=json.dumps({"data": payload}).encode(), headers={"Content-Type": "application/json", "User-Agent": "XMPlus-Hy2/2.0"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            print(f"[OnlineIP] Reported {len(payload)} IPs (HTTP {resp.status}).", flush=True)
    except Exception as e:
        print(f"[OnlineIP Error] {e}", flush=True)

def background_loop():
    while True:
        sync_server_config()
        fetch_users()
        report_traffic()
        report_online_ips()
        time.sleep(60)

class AuthHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            body_data = json.loads(self.rfile.read(length).decode())
            auth_uuid = body_data.get("auth", "")
            client_addr = body_data.get("addr", "")
        except Exception:
            auth_uuid, client_addr = "", ""
        with users_lock:
            user = users_by_uuid.get(auth_uuid)
        if user:
            ip_only = client_addr.rsplit(":", 1)[0].strip("[]") if client_addr else ""
            if ip_only:
                online_ips[str(user["id"])] = ip_only
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"ok": True, "id": str(user["id"])}).encode())
        else:
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":false}')
    def log_message(self, format, *args):
        pass

if __name__ == "__main__":
    sync_server_config()
    fetch_users()
    threading.Thread(target=background_loop, daemon=True).start()
    HTTPServer(("127.0.0.1", AUTH_PORT), AuthHandler).serve_forever()
EOF

echo -e "\n${YELLOW}[3/4] Creating systemd service...${NC}"
cat << 'EOF' > /etc/systemd/system/hy2-xmplus-bridge.service
[Unit]
Description=XMPlus Bridge for Hysteria 2
After=network.target

[Service]
ExecStart=/usr/bin/python3 /etc/hysteria/xmplus_bridge.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hy2-xmplus-bridge hysteria-server

echo -e "\n${YELLOW}[4/4] Installing 'hs' management menu...${NC}"
cat << 'EOF' > /usr/local/bin/hs
#!/bin/bash
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
STATS_SECRET="xmplus_hy2_secret_2026"
BRIDGE_FILE="/etc/hysteria/xmplus_bridge.py"
CONFIG_FILE="/etc/hysteria/config.yaml"

check_status() { systemctl is-active --quiet "$1" && echo -e "${GREEN}Active${NC}" || echo -e "${RED}Stopped${NC}"; }
get_bbr_mode() { grep -q "ignoreClientBandwidth: true" "$CONFIG_FILE" 2>/dev/null && echo -e "${GREEN}BBR (Stable Ping)${NC}" || echo -e "${YELLOW}Brutal (Max Speed)${NC}"; }

while true; do
    clear
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}      Hysteria 2 + XMPlus Manager        ${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo -e " Hysteria Core : $(check_status hysteria-server)"
    echo -e " XMPlus Bridge : $(check_status hy2-xmplus-bridge)"
    echo -e " Congestion    : $(get_bbr_mode)"
    echo -e "${CYAN}-----------------------------------------${NC}"
    echo -e " ${GREEN}1)${NC} Start Services"
    echo -e " ${RED}2)${NC} Stop Services"
    echo -e " ${YELLOW}3)${NC} Restart Services"
    echo -e " ${CYAN}4)${NC} Live Bridge Logs (Traffic & Online IP)"
    echo -e " ${CYAN}5)${NC} Live Hysteria Core Logs"
    echo -e " ${CYAN}6)${NC} Show Online Users & Live Traffic"
    echo -e " ${GREEN}7)${NC} Auto Install SSL (Domain Only)"
    echo -e " ${YELLOW}8)${NC} Toggle BBR / Brutal Mode"
    echo -e " ${CYAN}9)${NC} Edit xmplus_bridge.py"
    echo -e " ${RED}0)${NC} Exit"
    echo -e "${CYAN}=========================================${NC}"
    read -p "Select an option [0-9]: " choice
    case $choice in
        1) systemctl start hysteria-server hy2-xmplus-bridge; sleep 1 ;;
        2) systemctl stop hysteria-server hy2-xmplus-bridge; sleep 1 ;;
        3) systemctl restart hysteria-server hy2-xmplus-bridge; sleep 1 ;;
        4) journalctl -u hy2-xmplus-bridge -f --no-pager ;;
        5) journalctl -u hysteria-server -f --no-pager ;;
        6)
            echo -e "${CYAN}--- Online Users ---${NC}"
            curl -s -H "Authorization: $STATS_SECRET" http://127.0.0.1:19090/online; echo -e "\n"
            echo -e "${CYAN}--- Live Traffic ---${NC}"
            curl -s -H "Authorization: $STATS_SECRET" http://127.0.0.1:19090/traffic; echo ""
            read -p "Press Enter to return..."
            ;;
        7)
            read -p "Enter domain: " domain
            [[ -z "$domain" ]] && continue
            certbot certonly --standalone -d "$domain" --agree-tos --register-unsafely-without-email --non-interactive
            if [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]; then
                ln -sf "/etc/letsencrypt/live/$domain/fullchain.pem" /etc/hysteria/server.crt
                ln -sf "/etc/letsencrypt/live/$domain/privkey.pem" /etc/hysteria/server.key
                mkdir -p /etc/letsencrypt/renewal-hooks/deploy
                echo -e '#!/bin/bash\nsystemctl restart hysteria-server' > /etc/letsencrypt/renewal-hooks/deploy/restart-hy2.sh
                chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-hy2.sh
                systemctl restart hysteria-server
                echo -e "${GREEN}SSL Installed!${NC}"
            else
                echo -e "${RED}SSL Failed!${NC}"
            fi
            read -p "Press Enter to return..."
            ;;
        8)
            if grep -q "ignoreClientBandwidth: true" "$CONFIG_FILE" 2>/dev/null; then
                sed -i '/ignoreClientBandwidth:/d' "$CONFIG_FILE" "$BRIDGE_FILE"
            else
                echo -e "\nignoreClientBandwidth: true" >> "$CONFIG_FILE"
                python3 -c 'import re; p="/etc/hysteria/xmplus_bridge.py"; s=open(p).read(); s=re.sub(r"([ \t]*)trafficStats:", r"\1ignoreClientBandwidth: true\n\1trafficStats:", s, count=1) if "ignoreClientBandwidth" not in s else s; open(p,"w").write(s)'
            fi
            systemctl restart hysteria-server hy2-xmplus-bridge; sleep 1
            ;;
        9) nano "$BRIDGE_FILE" ;;
        0) exit 0 ;;
    esac
done
EOF
chmod +x /usr/local/bin/hs

echo -e "\n${GREEN}===========================================${NC}"
echo -e "${GREEN} Installation Complete!${NC}"
echo -e "${YELLOW} Next steps:${NC}"
echo -e " 1. Type 'hs' and press 9 to set API_KEY & NODE_ID"
echo -e " 2. Press 7 to install SSL for your domain"
echo -e " 3. Press 3 to restart services"
echo -e "${GREEN}===========================================${NC}"
