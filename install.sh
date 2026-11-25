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

setup_multinode_env() {
    # Disable legacy single-node service to avoid port conflicts
    systemctl disable --now hysteria-server 2>/dev/null || true

    # Persistent root override so Hysteria updates never break SSL permissions
    mkdir -p /etc/systemd/system/hysteria-server@.service.d
    cat << 'EOF' > /etc/systemd/system/hysteria-server@.service.d/override.conf
[Service]
User=root
Group=root
EOF
    systemctl daemon-reload

    # Kernel BBR & 16MB UDP buffer optimization
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    grep -q "net.core.rmem_max=16777216" /etc/sysctl.conf || echo "net.core.rmem_max=16777216" >> /etc/sysctl.conf
    grep -q "net.core.wmem_max=16777216" /etc/sysctl.conf || echo "net.core.wmem_max=16777216" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
}

install_manager_script() {
cat << 'EOF' > /usr/local/bin/hs
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
REPO_RAW="https://raw.githubusercontent.com/mohammadoaaakd/hy2-xmplus/main/install.sh"

get_node_ids() {
    python3 -c '
import re
try:
    s = open("/etc/hysteria/xmplus_bridge.py").read()
    m = re.search(r"NODE_IDS\s*=\s*\[([^\]]+)\]", s)
    if m:
        print(" ".join(x.strip() for x in m.group(1).split(",") if x.strip().isdigit()))
except Exception:
    pass
' 2>/dev/null
}

get_node_services() {
    local svcs=""
    for nid in $(get_node_ids); do
        svcs="$svcs hysteria-server@${nid}"
    done
    echo "$svcs"
}

get_status() {
    if systemctl is-active --quiet "$1"; then
        echo -e "${GREEN}Active${NC}"
    else
        echo -e "${RED}Stopped${NC}"
    fi
}

get_nodes_status() {
    local out=""
    local nids=$(get_node_ids)
    if [[ -z "$nids" ]]; then
        echo -e "${RED}No Nodes${NC}"
        return
    fi
    for nid in $nids; do
        if systemctl is-active --quiet "hysteria-server@${nid}"; then
            out+="${GREEN}${nid}:Active${NC} "
        else
            out+="${RED}${nid}:Stopped${NC} "
        fi
    done
    echo -e "$out"
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
    if grep -qE "CONGESTION_BBR\s*=\s*True|ignoreClientBandwidth:\s*true" /etc/hysteria/xmplus_bridge.py 2>/dev/null; then
        echo -e "${GREEN}BBR (Stable Ping)${NC}"
    else
        echo -e "${YELLOW}Brutal (Max Speed)${NC}"
    fi
}

while true; do
    clear
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}   Hysteria 2 + XMPlus Multi-Node v2.1   ${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo -e " Hysteria Nodes: $(get_nodes_status)"
    echo -e " XMPlus Bridge : $(get_status hy2-xmplus-bridge)"
    echo -e " SSL Cert (CN) : $(get_ssl_cn)"
    echo -e " Congestion    : $(get_congestion)"
    echo -e "${CYAN}-----------------------------------------${NC}"
    echo -e " 1) Start Services"
    echo -e " 2) Stop Services"
    echo -e " 3) Restart Services"
    echo -e " 4) Live Bridge Logs (Traffic & Online IP)"
    echo -e " 5) Live Hysteria Nodes Logs"
    echo -e " 6) Show Online Users & Live Traffic"
    echo -e " 7) Auto Install SSL (Domain Only)"
    echo -e " 8) Toggle BBR / Brutal Mode"
    echo -e " 9) Edit xmplus_bridge.py (Add/Edit Nodes)"
    echo -e "10) Update Hysteria Core & Manager Script"
    echo -e "11) Uninstall Completely (Delete All)"
    echo -e " 0) Exit"
    echo -e "${CYAN}=========================================${NC}"
    read -p "Select an option [0-11]: " opt

    NODE_SVCS=$(get_node_services)

    case $opt in
        1)
            systemctl start hy2-xmplus-bridge $NODE_SVCS
            echo -e "${GREEN}Services started.${NC}"
            sleep 1
            ;;
        2)
            systemctl stop $NODE_SVCS hy2-xmplus-bridge
            echo -e "${YELLOW}Services stopped.${NC}"
            sleep 1
            ;;
        3)
            systemctl restart hy2-xmplus-bridge
            sleep 2
            systemctl restart $NODE_SVCS 2>/dev/null || true
            echo -e "${GREEN}Services restarted.${NC}"
            sleep 1
            ;;
        4)
            journalctl -u hy2-xmplus-bridge -f -n 30
            ;;
        5)
            local_args=""
            for s in $NODE_SVCS; do local_args="$local_args -u $s"; done
            if [[ -n "$local_args" ]]; then
                journalctl $local_args -f -n 30
            else
                echo -e "${RED}No nodes configured.${NC}"
                sleep 2
            fi
            ;;
        6)
            idx=0
            for nid in $(get_node_ids); do
                port=$((19090 + idx))
                echo -e "${CYAN}=== Node ${nid} (Stats Port ${port}) ===${NC}"
                echo -e "${YELLOW}-- Online Users --${NC}"
                curl -s -H "Authorization: xmplus_hy2_secret_2026" "http://127.0.0.1:${port}/online" | python3 -m json.tool 2>/dev/null || echo "No data"
                echo -e "${YELLOW}-- Live Traffic --${NC}"
                curl -s -H "Authorization: xmplus_hy2_secret_2026" "http://127.0.0.1:${port}/traffic" | python3 -m json.tool 2>/dev/null || echo "No data"
                idx=$((idx + 1))
            done
            read -p "Press Enter to continue..."
            ;;
        7)
            read -p "Enter your domain (e.g. dns.data-recivee.ir): " DOMAIN
            if [[ -z "$DOMAIN" ]]; then continue; fi
            apt-get update -qq && apt-get install -y -qq certbot
            ufw allow 80/tcp >/dev/null 2>&1 || true
            certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
            if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
                rm -f /etc/hysteria/server.crt /etc/hysteria/server.key
                cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" /etc/hysteria/server.crt
                cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" /etc/hysteria/server.key
                chmod 644 /etc/hysteria/server.crt
                chmod 600 /etc/hysteria/server.key

                mkdir -p /etc/letsencrypt/renewal-hooks/deploy
                cat << HOOK > /etc/letsencrypt/renewal-hooks/deploy/hysteria-copy.sh
#!/bin/bash
cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" /etc/hysteria/server.crt
cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" /etc/hysteria/server.key
chmod 644 /etc/hysteria/server.crt
chmod 600 /etc/hysteria/server.key
systemctl restart 'hysteria-server@*' 2>/dev/null || true
HOOK
                chmod +x /etc/letsencrypt/renewal-hooks/deploy/hysteria-copy.sh
                systemctl restart $NODE_SVCS 2>/dev/null || true
                echo -e "${GREEN}SSL installed and auto-renew hook configured for $DOMAIN!${NC}"
            else
                echo -e "${RED}Failed to obtain SSL certificate! Check port 80 and DNS.${NC}"
            fi
            read -p "Press Enter to continue..."
            ;;
        8)
            if grep -qE "CONGESTION_BBR\s*=\s*True" /etc/hysteria/xmplus_bridge.py; then
                sed -i 's/CONGESTION_BBR\s*=\s*True/CONGESTION_BBR     = False/g' /etc/hysteria/xmplus_bridge.py
                echo -e "${YELLOW}Switched to Brutal Mode.${NC}"
            elif grep -qE "CONGESTION_BBR\s*=\s*False" /etc/hysteria/xmplus_bridge.py; then
                sed -i 's/CONGESTION_BBR\s*=\s*False/CONGESTION_BBR     = True/g' /etc/hysteria/xmplus_bridge.py
                echo -e "${GREEN}Switched to BBR Mode.${NC}"
            elif grep -q "ignoreClientBandwidth: true" /etc/hysteria/xmplus_bridge.py; then
                sed -i 's/ignoreClientBandwidth: true/ignoreClientBandwidth: false/g' /etc/hysteria/xmplus_bridge.py
                echo -e "${YELLOW}Switched to Brutal Mode.${NC}"
            else
                sed -i 's/ignoreClientBandwidth: false/ignoreClientBandwidth: true/g' /etc/hysteria/xmplus_bridge.py
                echo -e "${GREEN}Switched to BBR Mode.${NC}"
            fi
            systemctl restart hy2-xmplus-bridge
            sleep 3
            echo -e "${GREEN}Applied to all nodes.${NC}"
            read -p "Press Enter to continue..."
            ;;
        9)
            nano /etc/hysteria/xmplus_bridge.py
            systemctl restart hy2-xmplus-bridge
            sleep 3
            echo -e "${GREEN}Bridge restarted with updated config.${NC}"
            sleep 1
            ;;
        10)
            echo -e "${CYAN}Updating Hysteria 2 Core...${NC}"
            bash <(curl -fsSL https://get.hy2.sh/)
            echo -e "${CYAN}Updating hs Manager Script...${NC}"
            curl -fsSL "$REPO_RAW" -o /tmp/hy2_install_update.sh
            bash /tmp/hy2_install_update.sh --update-only
            rm -f /tmp/hy2_install_update.sh
            systemctl restart hy2-xmplus-bridge
            sleep 2
            systemctl restart $(get_node_services) 2>/dev/null || true
            echo -e "${GREEN}Update completed without losing your config!${NC}"
            read -p "Press Enter to continue..."
            exec /usr/local/bin/hs
            ;;
        11)
            read -p "Are you sure you want to completely remove Hysteria 2 & Bridge? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                systemctl stop $NODE_SVCS hysteria-server hy2-xmplus-bridge 2>/dev/null || true
                systemctl disable $NODE_SVCS hysteria-server hy2-xmplus-bridge 2>/dev/null || true
                rm -f /etc/systemd/system/hy2-xmplus-bridge.service
                rm -f /etc/systemd/system/hysteria-server.service
                rm -f /etc/systemd/system/hysteria-server@.service
                rm -rf /etc/systemd/system/hysteria-server@.service.d
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
    setup_multinode_env
    install_manager_script
    exit 0
fi

echo -e "${CYAN}=== Hysteria 2 + XMPlus Multi-Node Installer (v2.1) ===${NC}"
read -p "Enter XMPlus API Host (e.g. https://panel.gameping.top): " API_HOST
read -p "Enter XMPlus API Key: " API_KEY
read -p "Enter Node IDs separated by comma (e.g. 47,96): " NODE_IDS_INPUT
read -p "Enter Salamander Obfs Password [default: GamePingHy2Obfs2026]: " OBFS_PASS
OBFS_PASS=${OBFS_PASS:-GamePingHy2Obfs2026}

# Clean comma-separated node IDs
NODE_IDS_CLEAN=$(echo "$NODE_IDS_INPUT" | tr -d ' ')

apt-get update -qq
apt-get install -y -qq curl python3 openssl ufw

echo -e "${CYAN}Installing Hysteria 2 Core...${NC}"
bash <(curl -fsSL https://get.hy2.sh/)

setup_multinode_env

mkdir -p /etc/hysteria
if [[ ! -f /etc/hysteria/server.crt ]]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
        -subj "/CN=bing.com" -days 3650 2>/dev/null
    chmod 644 /etc/hysteria/server.crt
    chmod 600 /etc/hysteria/server.key
fi

cat << EOF > /etc/hysteria/xmplus_bridge.py
import json
import time
import subprocess
import threading
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler

API_HOST           = "${API_HOST}"
API_KEY            = "${API_KEY}"
NODE_IDS           = [${NODE_IDS_CLEAN}]
OBFS_PASS          = "${OBFS_PASS}"
STATS_SECRET       = "xmplus_hy2_secret_2026"
BASE_AUTH_PORT     = 18080
BASE_STATS_PORT    = 19090
CONGESTION_BBR     = True
APPLY_RATE_LOCALLY = False

nodes_state = {}
for idx, nid in enumerate(NODE_IDS):
    nodes_state[nid] = {
        "auth_port": BASE_AUTH_PORT + idx,
        "stats_port": BASE_STATS_PORT + idx,
        "users_by_uuid": {},
        "online_ips": {},
        "lock": threading.Lock(),
        "last_config": None,
        "rate": 1.0,
    }


def sync_server_config(nid):
    st = nodes_state[nid]
    url = f"{API_HOST}/api/v2/query/server/{nid}?key={API_KEY}"
    req = urllib.request.Request(url, headers={"User-Agent": "XMPlus-Hy2/2.1"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
            srv = data.get("server", {})
            listen_port = int(srv.get("listeningport") or 2093)
            sec = srv.get("securitySettings") or {}
            snames = sec.get("serverNames") or []
            sni = snames[0] if snames else (sec.get("serverName") or "bing.com")
            try:
                r = float(srv.get("rate", 1))
                st["rate"] = r if r > 0 else 1.0
            except Exception:
                st["rate"] = 1.0

            bbr_val = "true" if CONGESTION_BBR else "false"
            cfg_state = (listen_port, sni, bbr_val)
            if cfg_state != st["last_config"]:
                print(f"[Node {nid}] Applying config: port={listen_port}, sni={sni}, rate={st['rate']}, bbr={bbr_val}", flush=True)
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

{obfs_block}
auth:
  type: http
  http:
    url: http://127.0.0.1:{st['auth_port']}/auth
    insecure: true

ignoreClientBandwidth: {bbr_val}
trafficStats:
  listen: 127.0.0.1:{st['stats_port']}
  secret: {STATS_SECRET}

masquerade:
  type: proxy
  proxy:
    url: https://{sni}
    rewriteHost: true
"""
                with open(f"/etc/hysteria/{nid}.yaml", "w") as f:
                    f.write(cfg)
                subprocess.run(["ufw", "allow", f"{listen_port}/udp"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                subprocess.run(["systemctl", "enable", "--now", f"hysteria-server@{nid}"], check=False)
                subprocess.run(["systemctl", "restart", f"hysteria-server@{nid}"], check=False)
                st["last_config"] = cfg_state
                print(f"[Node {nid}] hysteria-server@{nid} restarted.", flush=True)
    except Exception as e:
        print(f"[Node {nid} Config Error] {e}", flush=True)


def fetch_users(nid):
    st = nodes_state[nid]
    url = f"{API_HOST}/api/v2/query/users/{nid}?key={API_KEY}"
    req = urllib.request.Request(url, headers={"User-Agent": "XMPlus-Hy2/2.1"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
            new_map = {}
            for u in data.get("users", []):
                uuid = u.get("uuid")
                if uuid:
                    new_map[uuid] = {
                        "id": u.get("id"),
                        "email": u.get("email", ""),
                        "iplimit": int(u.get("iplimit") or 0),
                    }
            with st["lock"]:
                st["users_by_uuid"] = new_map
            print(f"[Node {nid}] Loaded {len(new_map)} users (rate={st['rate']}).", flush=True)
    except Exception as e:
        print(f"[Node {nid} Sync Error] {e}", flush=True)


def report_traffic(nid):
    st = nodes_state[nid]
    stats_url = f"http://127.0.0.1:{st['stats_port']}/traffic?clear=1"
    try:
        req = urllib.request.Request(stats_url, headers={"Authorization": STATS_SECRET})
        with urllib.request.urlopen(req, timeout=5) as resp:
            stats = json.loads(resp.read().decode())
    except Exception:
        return

    mult = st["rate"] if APPLY_RATE_LOCALLY else 1.0
    payload = []
    for uid_str, item in stats.items():
        tx, rx = int(item.get("tx", 0)), int(item.get("rx", 0))
        if tx == 0 and rx == 0:
            continue
        try:
            payload.append({
                "userid": int(uid_str),
                "u": int(round(tx * mult)),
                "d": int(round(rx * mult)),
            })
        except ValueError:
            continue

    if not payload:
        return

    url = f"{API_HOST}/api/v2/query/users/traffic/{nid}?key={API_KEY}"
    req = urllib.request.Request(
        url,
        data=json.dumps({"data": payload}).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "XMPlus-Hy2/2.1"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            print(f"[Node {nid}] Traffic reported for {len(payload)} users (HTTP {resp.status}).", flush=True)
    except Exception as e:
        print(f"[Node {nid} Traffic Error] {e}", flush=True)


def report_online_ips(nid):
    st = nodes_state[nid]
    online_url = f"http://127.0.0.1:{st['stats_port']}/online"
    try:
        req = urllib.request.Request(online_url, headers={"Authorization": STATS_SECRET})
        with urllib.request.urlopen(req, timeout=5) as resp:
            online_users = json.loads(resp.read().decode())
    except Exception:
        return

    payload = []
    with st["lock"]:
        for uid_str in list(st["online_ips"].keys()):
            if int(online_users.get(uid_str, 0)) == 0:
                del st["online_ips"][uid_str]

        for uid_str, count in online_users.items():
            if int(count) > 0 and uid_str in st["online_ips"]:
                for ip in st["online_ips"][uid_str]:
                    try:
                        payload.append({"userid": int(uid_str), "ip": ip})
                    except ValueError:
                        continue

    if not payload:
        return

    url = f"{API_HOST}/api/v2/query/users/online/{nid}?key={API_KEY}"
    req = urllib.request.Request(
        url,
        data=json.dumps({"data": payload}).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "XMPlus-Hy2/2.1"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            print(f"[Node {nid}] OnlineIP reported {len(payload)} IPs (HTTP {resp.status}).", flush=True)
    except Exception as e:
        print(f"[Node {nid} OnlineIP Error] {e}", flush=True)


def make_auth_handler(nid):
    st = nodes_state[nid]

    class AuthHandler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            try:
                body_data = json.loads(self.rfile.read(length).decode())
                auth_uuid = body_data.get("auth", "")
                client_addr = body_data.get("addr", "")
            except Exception:
                auth_uuid = ""
                client_addr = ""

            allowed = False
            uid_str = ""
            with st["lock"]:
                user = st["users_by_uuid"].get(auth_uuid)
                if user:
                    uid_str = str(user["id"])
                    iplimit = user.get("iplimit", 0)
                    ip_only = client_addr.rsplit(":", 1)[0].strip("[]") if client_addr else ""
                    active_ips = st["online_ips"].setdefault(uid_str, set())

                    if iplimit > 0 and ip_only and (ip_only not in active_ips) and (len(active_ips) >= iplimit):
                        print(f"[Node {nid}] IP limit reached for user {uid_str} ({len(active_ips)}/{iplimit}), blocked {ip_only}", flush=True)
                        allowed = False
                    else:
                        if ip_only:
                            active_ips.add(ip_only)
                        allowed = True

            if allowed:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"ok": True, "id": uid_str}).encode())
            else:
                self.send_response(401)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"ok":false}')

        def log_message(self, format, *args):
            pass

    return AuthHandler


def background_loop():
    while True:
        for nid in NODE_IDS:
            sync_server_config(nid)
            fetch_users(nid)
            report_traffic(nid)
            report_online_ips(nid)
        time.sleep(60)


if __name__ == "__main__":
    for nid in NODE_IDS:
        sync_server_config(nid)
        fetch_users(nid)
        port = nodes_state[nid]["auth_port"]
        srv = HTTPServer(("127.0.0.1", port), make_auth_handler(nid))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        print(f"[Node {nid}] Auth listening on 127.0.0.1:{port}", flush=True)

    background_loop()
EOF

cat << 'EOF' > /etc/systemd/system/hy2-xmplus-bridge.service
[Unit]
Description=XMPlus Bridge for Hysteria 2 (Multi-Node)
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
systemctl enable --now hy2-xmplus-bridge
sleep 3

echo -e "${GREEN}Multi-Node Installation complete! Type 'hs' to open the manager.${NC}"
