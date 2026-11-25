#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO_RAW="https://raw.githubusercontent.com/mohammadoaaakd/hy2-xmplus/main/install.sh"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Please run as root!${NC}"
   exit 1
fi

install_manager_script() {
cat << 'EOF' > /usr/local/bin/hs
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
REPO_RAW="https://raw.githubusercontent.com/mohammadoaaakd/hy2-xmplus/main/install.sh"

get_status() {
    if systemctl is-active --quiet "$1"; then
        echo -e "${GREEN}Active${NC}"
    else
        echo -e "${RED}Stopped${NC}"
    fi
}

get_ssl_cn() {
    if [[ -f /etc/hysteria/server.crt ]]; then
        CN=$(openssl x509 -in /etc/hysteria/server.crt -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,\/]*\).*/\1/p')
        echo -e "${CYAN}${CN:-Unknown}${NC}"
    else
        echo -e "${RED}Not Found${NC}"
    fi
}

get_congestion() {
    if grep -q "ignoreClientBandwidth: true" /etc/hysteria/config.yaml 2>/dev/null; then
        echo -e "${GREEN}BBR (Stable Ping)${NC}"
    else
        echo -e "${YELLOW}Brutal (Max Speed)${NC}"
    fi
}

while true; do
    clear
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}        Hysteria 2 + XMPlus Manager      ${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo -e " Hysteria Core : $(get_status hysteria-server)"
    echo -e " XMPlus Bridge : $(get_status hy2-xmplus-bridge)"
    echo -e " SSL Cert (CN) : $(get_ssl_cn)"
    echo -e " Congestion    : $(get_congestion)"
    echo -e "${CYAN}-----------------------------------------${NC}"
    echo -e " 1) Start Services"
    echo -e " 2) Stop Services"
    echo -e " 3) Restart Services"
    echo -e " 4) Live Bridge Logs (Traffic & Online IP)"
    echo -e " 5) Live Hysteria Core Logs"
    echo -e " 6) Show Online Users & Live Traffic"
    echo -e " 7) Auto Install SSL (Domain Only)"
    echo -e " 8) Toggle BBR / Brutal Mode"
    echo -e " 9) Edit xmplus_bridge.py"
    echo -e "10) Update Hysteria Core & Manager Script"
    echo -e "11) Uninstall Completely (Delete All)"
    echo -e " 0) Exit"
    echo -e "${CYAN}=========================================${NC}"
    read -p "Select an option [0-11]: " opt

    case $opt in
        1)
            systemctl start hy2-xmplus-bridge hysteria-server
            echo -e "${GREEN}Services started.${NC}"
            sleep 1
            ;;
        2)
            systemctl stop hysteria-server hy2-xmplus-bridge
            echo -e "${YELLOW}Services stopped.${NC}"
            sleep 1
            ;;
        3)
            systemctl restart hy2-xmplus-bridge
            sleep 2
            systemctl restart hysteria-server
            echo -e "${GREEN}Services restarted.${NC}"
            sleep 1
            ;;
        4)
            journalctl -u hy2-xmplus-bridge -f -n 30
            ;;
        5)
            journalctl -u hysteria-server -f -n 30
            ;;
        6)
            echo -e "${CYAN}--- Online Users ---${NC}"
            curl -s -H "Authorization: xmplus_hy2_secret_2026" http://127.0.0.1:19090/online | python3 -m json.tool 2>/dev/null || echo "No data"
            echo -e "${CYAN}--- Live Traffic ---${NC}"
            curl -s -H "Authorization: xmplus_hy2_secret_2026" http://127.0.0.1:19090/traffic | python3 -m json.tool 2>/dev/null || echo "No data"
            read -p "Press Enter to continue..."
            ;;
        7)
            read -p "Enter your domain (e.g. dea.data-recivee.ir): " DOMAIN
            if [[ -z "$DOMAIN" ]]; then continue; fi
            apt-get update -qq && apt-get install -y -qq certbot
            ufw allow 80/tcp >/dev/null 2>&1 || true
            certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
            if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
                rm -f /etc/hysteria/server.crt /etc/hysteria/server.key
                cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" /etc/hysteria/server.crt
                cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" /etc/hysteria/server.key
                chown hysteria:hysteria /etc/hysteria/server.crt /etc/hysteria/server.key
                chmod 644 /etc/hysteria/server.crt
                chmod 600 /etc/hysteria/server.key

                mkdir -p /etc/letsencrypt/renewal-hooks/deploy
                cat << HOOK > /etc/letsencrypt/renewal-hooks/deploy/hysteria-copy.sh
#!/bin/bash
cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" /etc/hysteria/server.crt
cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" /etc/hysteria/server.key
chown hysteria:hysteria /etc/hysteria/server.crt /etc/hysteria/server.key
chmod 644 /etc/hysteria/server.crt
chmod 600 /etc/hysteria/server.key
systemctl restart hysteria-server
HOOK
                chmod +x /etc/letsencrypt/renewal-hooks/deploy/hysteria-copy.sh
                systemctl restart hysteria-server
                echo -e "${GREEN}SSL installed and auto-renew hook configured for $DOMAIN!${NC}"
            else
                echo -e "${RED}Failed to obtain SSL certificate! Check port 80 and DNS.${NC}"
            fi
            read -p "Press Enter to continue..."
            ;;
        8)
            if grep -q "ignoreClientBandwidth: true" /etc/hysteria/xmplus_bridge.py; then
                sed -i 's/ignoreClientBandwidth: true/ignoreClientBandwidth: false/g' /etc/hysteria/xmplus_bridge.py
                echo -e "${YELLOW}Switched to Brutal Mode.${NC}"
            else
                sed -i 's/ignoreClientBandwidth: false/ignoreClientBandwidth: true/g' /etc/hysteria/xmplus_bridge.py
                echo -e "${GREEN}Switched to BBR Mode.${NC}"
            fi
            rm -f /etc/hysteria/config.yaml
            systemctl restart hy2-xmplus-bridge
            sleep 3
            systemctl restart hysteria-server
            read -p "Press Enter to continue..."
            ;;
        9)
            nano /etc/hysteria/xmplus_bridge.py
            rm -f /etc/hysteria/config.yaml
            systemctl restart hy2-xmplus-bridge
            sleep 3
            systemctl restart hysteria-server
            ;;
        10)
            echo -e "${CYAN}Updating Hysteria 2 Core...${NC}"
            bash <(curl -fsSL https://get.hy2.sh/)
            echo -e "${CYAN}Updating hs Manager Script...${NC}"
            curl -fsSL "$REPO_RAW" -o /tmp/hy2_install_update.sh
            bash /tmp/hy2_install_update.sh --update-only
            rm -f /tmp/hy2_install_update.sh
            systemctl restart hy2-xmplus-bridge hysteria-server
            echo -e "${GREEN}Update completed without losing your config!${NC}"
            read -p "Press Enter to continue..."
            exec /usr/local/bin/hs
            ;;
        11)
            read -p "Are you sure you want to completely remove Hysteria 2 & Bridge? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                systemctl stop hysteria-server hy2-xmplus-bridge 2>/dev/null || true
                systemctl disable hysteria-server hy2-xmplus-bridge 2>/dev/null || true
                rm -f /etc/systemd/system/hy2-xmplus-bridge.service
                rm -f /etc/systemd/system/hysteria-server.service
                rm -f /etc/systemd/system/hysteria-server@.service
                rm -rf /etc/hysteria
                rm -f /usr/local/bin/hysteria /usr/local/bin/hs
                rm -f /etc/letsencrypt/renewal-hooks/deploy/hysteria-copy.sh
                systemctl daemon-reload
                echo -e "${GREEN}Uninstalled completely!${NC}"
                exit 0
            fi
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option!${NC}"
            sleep 1
            ;;
    esac
done
EOF
chmod +x /usr/local/bin/hs
}

if [[ "$1" == "--update-only" ]]; then
    install_manager_script
    exit 0
fi

echo -e "${CYAN}=== Hysteria 2 + XMPlus Auto Installer ===${NC}"
read -p "Enter XMPlus API Host (e.g. https://i.gameping.top): " API_HOST
read -p "Enter XMPlus API Key: " API_KEY
read -p "Enter Node ID: " NODE_ID
read -p "Enter Salamander Obfs Password [default: GamePingHy2Obfs2026]: " OBFS_PASS
OBFS_PASS=${OBFS_PASS:-GamePingHy2Obfs2026}

apt-get update -qq
apt-get install -y -qq curl python3 openssl ufw

echo -e "${CYAN}Installing Hysteria 2 Core...${NC}"
bash <(curl -fsSL https://get.hy2.sh/)

mkdir -p /etc/hysteria
if [[ ! -f /etc/hysteria/server.crt ]]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
        -subj "/CN=bing.com" -days 3650 2>/dev/null
    chown hysteria:hysteria /etc/hysteria/server.crt /etc/hysteria/server.key
    chmod 644 /etc/hysteria/server.crt
    chmod 600 /etc/hysteria/server.key
fi

cat << EOF > /etc/hysteria/xmplus_bridge.py
import json, time, threading, subprocess, urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler

API_HOST     = "${API_HOST}"
API_KEY      = "${API_KEY}"
NODE_ID      = ${NODE_ID}
OBFS_PASS    = "${OBFS_PASS}"
STATS_URL    = "http://127.0.0.1:19090/traffic?clear=1"
STATS_SECRET = "xmplus_hy2_secret_2026"
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
            listen_port = int(srv.get("listeningport") or 2053)
            state = (listen_port,)
            if state != last_config_state:
                obfs_block = ""
                if OBFS_PASS:
                    obfs_block = f"""obfs:
  type: salamander
  salamander:
    password: {OBFS_PASS}
"""
                cfg = f"""listen: :{listen_port}
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
{obfs_block}auth:
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
                subprocess.run(["chown", "hysteria:hysteria", "/etc/hysteria/config.yaml"], check=False)
                subprocess.run(["ufw", "allow", f"{listen_port}/udp"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                subprocess.run(["systemctl", "restart", "hysteria-server"], check=False)
                last_config_state = state
                print(f"[Config] Applied port={listen_port}", flush=True)
    except Exception as e:
        print(f"[Config Error] {e}", flush=True)

def sync_users():
    url = f"{API_HOST}/api/v2/query/users/{NODE_ID}?key={API_KEY}"
    req = urllib.request.Request(url, headers={"User-Agent": "XMPlus-Hy2/2.0"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
            new_map = {}
            for u in data.get("users", []):
                uuid = u.get("uuid")
                if uuid:
                    new_map[uuid] = u.get("id")
            with users_lock:
                users_by_uuid.clear()
                users_by_uuid.update(new_map)
            print(f"[Sync] Loaded {len(new_map)} users.", flush=True)
    except Exception as e:
        print(f"[Sync Error] {e}", flush=True)

def report_traffic():
    try:
        req = urllib.request.Request(STATS_URL, headers={"Authorization": STATS_SECRET})
        with urllib.request.urlopen(req, timeout=5) as resp:
            stats = json.loads(resp.read().decode())
        payload = []
        with users_lock:
            for uid_str, val in stats.items():
                tx = val.get("tx", 0)
                rx = val.get("rx", 0)
                if tx > 0 or rx > 0:
                    payload.append({"id": int(uid_str), "u": tx, "d": rx})
        if payload:
            url = f"{API_HOST}/api/v2/query/users/traffic/{NODE_ID}?key={API_KEY}"
            body = json.dumps({"data": payload}).encode()
            r = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json", "User-Agent": "XMPlus-Hy2/2.0"}, method="POST")
            urllib.request.urlopen(r, timeout=10).read()
    except Exception as e:
        print(f"[Traffic Error] {e}", flush=True)

class AuthHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args): pass
    def do_POST(self):
        if self.path == "/auth":
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length).decode())
            auth_key = body.get("auth", "")
            with users_lock:
                uid = users_by_uuid.get(auth_key)
            if uid is not None:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"ok": True, "id": str(uid)}).encode())
            else:
                self.send_response(403)
                self.end_headers()

def bg_loop():
    while True:
        sync_server_config()
        sync_users()
        report_traffic()
        time.sleep(60)

if __name__ == "__main__":
    threading.Thread(target=bg_loop, daemon=True).start()
    HTTPServer(("127.0.0.1", AUTH_PORT), AuthHandler).serve_forever()
EOF

chown -R hysteria:hysteria /etc/hysteria

cat << 'EOF' > /etc/systemd/system/hy2-xmplus-bridge.service
[Unit]
Description=XMPlus Bridge for Hysteria 2
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /etc/hysteria/xmplus_bridge.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

install_manager_script
systemctl daemon-reload
systemctl enable hy2-xmplus-bridge hysteria-server
systemctl restart hy2-xmplus-bridge
sleep 3
systemctl restart hysteria-server

echo -e "${GREEN}Installation complete! Type 'hs' to open the manager.${NC}"
