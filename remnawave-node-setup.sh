#!/usr/bin/env bash
#
# Combined Remnawave node setup script.
#
# Merges:
#   - https://github.com/herbalsomml/remnawave-guide   (manual guide -> automated: firewall, ICMP block,
#     nginx, certbot, remnanode docker-compose)
#   - https://github.com/juhnsooqa/servers              (fail2ban.sh, roscom.sh folded in directly;
#     node-accelerator and cascademod (=vladimir-kartamyshev/remnawave-reverse-proxy-pro) are unrelated
#     third-party installers and are only offered as optional external steps, not inlined)
#
# Run as root on a fresh Ubuntu/Debian VPS that will act as a Remnawave node.
#
#   sudo bash remnawave-node-setup.sh            # interactive menu
#   sudo bash remnawave-node-setup.sh full       # firewall + icmp + nginx + ssl + docker + remnanode
#   sudo bash remnawave-node-setup.sh fail2ban
#   sudo bash remnawave-node-setup.sh roscom
#   sudo bash remnawave-node-setup.sh psiphon         # Psiphon-выход для xray (psiphon/, из Chara-Freedom/vps-psiphon)
#
# После первого запуска на сервере есть команда `allinone` (всегда тянет свежую версию с GitHub).
#   sudo bash remnawave-node-setup.sh accelerator     # optional, 3rd-party
#   sudo bash remnawave-node-setup.sh reverse-proxy   # optional, 3rd-party

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }

STATE_FILE="/root/.remnanode-setup.env"
NODE_DIR="/opt/remnanode"
REPO_RAW="https://raw.githubusercontent.com/juhnsooqa/allinone/main"
PANEL_STATE="/root/.remnawave-panel.env"
CLI_PATH="/usr/local/bin/allinone"

require_root() {
    if [ "$EUID" -ne 0 ]; then
        err "Запустите скрипт с правами root (sudo)."
        exit 1
    fi
}

ask() { # ask "prompt" varname [default] - третий аргумент, даже пустой, делает ответ необязательным
    local prompt="$1" __var="$2" default="${3:-}" reply
    if [ $# -ge 3 ]; then
        [ -n "$default" ] && prompt="$prompt [$default]"
        read -rp "$prompt: " reply
        reply="${reply:-$default}"
    else
        read -rp "$prompt: " reply
        while [ -z "$reply" ]; do
            read -rp "$prompt (обязательно): " reply
        done
    fi
    printf -v "$__var" '%s' "$reply"
}

load_common_vars() {
    [ -f "$STATE_FILE" ] && source "$STATE_FILE"
    if [ -z "${DOMAIN:-}" ]; then
        ask "Домен ноды (например node1.example.com)" DOMAIN
    fi
    if [ -z "${EMAIL:-}" ]; then
        ask "Email для Let's Encrypt (пусто = без email)" EMAIL ""
    fi
    if [ -z "${SECRET_KEY:-}" ]; then
        SECRET_KEY="$(panel_secret_key)" && [ -n "$SECRET_KEY" ] && log "SECRET_KEY получен из панели по API."
    fi
    if [ -z "${SECRET_KEY:-}" ]; then
        ask "SECRET_KEY ноды из панели Remnawave" SECRET_KEY
    fi
    if [ -z "${NODE_PORT:-}" ]; then
        ask "Порт ноды (NODE_PORT, панель ходит на него)" NODE_PORT "2222"
    fi
    cat > "$STATE_FILE" <<EOF
DOMAIN="$DOMAIN"
EMAIL="$EMAIL"
SECRET_KEY="$SECRET_KEY"
NODE_PORT="$NODE_PORT"
EOF
    chmod 600 "$STATE_FILE"
}

### ---------------------------------------------------------------------
### 1. Firewall (remnawave-guide)
### ---------------------------------------------------------------------
setup_firewall() {
    load_common_vars
    log "Установка и настройка UFW..."
    apt update -y && apt install -y ufw
    ufw allow OpenSSH
    ufw allow "${NODE_PORT}/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 9443/tcp
    ufw allow 44443/tcp
    ufw allow 44444/tcp
    ufw --force disable
    ufw --force enable
    log "UFW настроен и включён."
}

block_icmp() {
    log "Блокировка ICMP-запросов..."
    local f=/etc/ufw/before.rules
    cp "$f" "${f}.bak.$(date +%s)"

    local t
    for t in destination-unreachable time-exceeded parameter-problem echo-request source-quench; do
        sed -i "s/-A ufw-before-input -p icmp --icmp-type ${t} -j ACCEPT/-A ufw-before-input -p icmp --icmp-type ${t} -j DROP/" "$f"
    done
    for t in destination-unreachable time-exceeded parameter-problem echo-request; do
        sed -i "s/-A ufw-before-forward -p icmp --icmp-type ${t} -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type ${t} -j DROP/" "$f"
    done

    ufw --force disable
    ufw --force enable
    log "ICMP заблокирован (бэкап правил: ${f}.bak.*)."
}

### ---------------------------------------------------------------------
### 2. nginx + заглушка + SSL (remnawave-guide)
### ---------------------------------------------------------------------
install_nginx() {
    log "Установка nginx mainline (nginx.org)..."
    apt update -y
    apt install -y curl gnupg2 ca-certificates lsb-release ubuntu-keyring
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/ubuntu $(lsb_release -cs) nginx" \
        | tee /etc/apt/sources.list.d/nginx.list >/dev/null
    printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' \
        | tee /etc/apt/preferences.d/99nginx >/dev/null
    apt update -y
    apt install -y nginx
    systemctl enable --now nginx
    log "nginx установлен."
}

create_stub() {
    log "Создание страницы-заглушки..."
    mkdir -p /var/www/html/
    cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html>
    <head>
        <title>All good!</title>
    </head>
    <body>
        <h1>All good!</h1>
    </body>
</html>
EOF
}

issue_ssl() {
    load_common_vars
    log "Выпуск SSL-сертификата для ${DOMAIN}..."
    apt update -y
    apt install -y certbot python3-certbot-nginx

    local email_args=(--register-unsafely-without-email)
    [ -n "$EMAIL" ] && email_args=(--email "$EMAIL")

    # Старый xray.conf со ссылкой на несуществующий сертификат валит `nginx -t` внутри certbot.
    # configure_nginx всё равно перепишет его после выпуска.
    rm -f /etc/nginx/conf.d/xray.conf

    # certonly: только выпуск, SSL-конфиг пишет configure_nginx
    if ! certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos "${email_args[@]}"; then
        warn "certbot не смог выпустить сертификат автоматически."
        warn "Проверьте, что A-запись $DOMAIN указывает на этот сервер, затем выполните вручную:"
        warn "  certbot --nginx -d $DOMAIN"
        return 1
    fi
    log "Сертификат выпущен."
}

configure_nginx() {
    load_common_vars
    log "Запись /etc/nginx/conf.d/xray.conf..."
    cat > /etc/nginx/conf.d/xray.conf <<EOF
server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /xhttppath/ {
        proxy_pass http://unix:/dev/shm/xrxh.socket;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

server {
    listen 9443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /var/www/html;
    index index.html;
}

server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
    nginx -t && systemctl restart nginx
    log "nginx настроен и перезапущен."
}

### ---------------------------------------------------------------------
### 3. Docker + remnanode (remnawave-guide)
### ---------------------------------------------------------------------
install_docker() {
    if command -v docker &>/dev/null; then
        log "Docker уже установлен, пропускаю."
        return 0
    fi
    log "Установка Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
}

setup_remnanode() {
    load_common_vars
    log "Установка remnanode в ${NODE_DIR}..."
    mkdir -p "$NODE_DIR"

    cat > "${NODE_DIR}/.env" <<EOF
NODE_PORT=${NODE_PORT}
SECRET_KEY=${SECRET_KEY}
EOF

    wget -qO "${NODE_DIR}/geoip.dat"   https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
    wget -qO "${NODE_DIR}/geosite.dat" https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat

    # NB: важно смонтировать именно /dev/shm целиком (а не только .env/.dat) -
    # xhttp-инбаунд слушает unix-сокет в /dev/shm внутри контейнера, и без этого
    # монтирования nginx на хосте не увидит сокет (502 Bad Gateway).
    cat > "${NODE_DIR}/docker-compose.yml" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    volumes:
      - /dev/shm:/dev/shm
      - ${NODE_DIR}/geoip.dat:/opt/remnanode/geoip.dat
      - ${NODE_DIR}/geosite.dat:/opt/remnanode/geosite.dat
    env_file:
      - ${NODE_DIR}/.env
EOF

    (cd "$NODE_DIR" && docker compose up -d)
    log "remnanode запущен. Логи: docker compose -f ${NODE_DIR}/docker-compose.yml logs -f"

    write_panel_reference_files
}

# Справочные JSON для панели Remnawave (профиль ноды + xHTTP host extra).
# Reality-ключи панель генерирует сама - сюда они не подставляются.
write_panel_reference_files() {
    load_common_vars
    mkdir -p "$NODE_DIR"

    # Если стоит vps-psiphon - добавляем его SOCKS-аутбаунд и правило (только TCP: UDP psiphon не умеет).
    local psi_out="" psi_rule="" psi_bind psi_port
    if [ -r /etc/default/vps-psiphon ]; then
        read -r psi_bind psi_port < <(. /etc/default/vps-psiphon; echo "${BIND:-172.17.0.1} ${SOCKS_PORT:-1080}")
        psi_out=",
    { \"tag\": \"psiphon-out\", \"protocol\": \"socks\", \"settings\": { \"address\": \"${psi_bind}\", \"port\": ${psi_port} } }"
        psi_rule="
      { \"type\": \"field\", \"network\": \"tcp\", \"domain\": [\"geosite:openai\", \"geosite:google-gemini\"], \"outboundTag\": \"psiphon-out\" },"
    fi

    cat > "${NODE_DIR}/panel-profile.reference.json" <<EOF
{
  "log": { "loglevel": "info" },
  "dns": {
    "servers": [
      { "address": "94.140.14.14", "domains": ["geosite:geolocation-!cn"] },
      { "address": "94.140.15.15", "domains": ["geosite:geolocation-!cn"] }
    ]
  },
  "inbounds": [
    {
      "tag": "NODE_TCP",
      "port": 44443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "sniffing": { "enabled": true, "routeOnly": false, "destOverride": ["http","tls","quic","fakedns"], "metadataOnly": false },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "tcpSettings": { "header": { "type": "none" }, "acceptProxyProtocol": false },
        "realitySettings": {
          "dest": "9443", "show": false, "xver": 0, "spiderX": "/",
          "shortIds": [""],
          "publicKey": "<ПУБЛИЧНЫЙ КЛЮЧ ИЗ ПАНЕЛИ>",
          "privateKey": "<ПРИВАТНЫЙ КЛЮЧ ИЗ ПАНЕЛИ>",
          "serverNames": ["${DOMAIN}"]
        }
      }
    },
    {
      "tag": "NODE_GRPC",
      "port": 44444,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "sniffing": { "enabled": true, "routeOnly": false, "destOverride": ["http","tls","quic","fakedns"], "metadataOnly": false },
      "streamSettings": {
        "network": "grpc",
        "security": "reality",
        "tcpSettings": { "header": { "type": "none" }, "acceptProxyProtocol": false },
        "realitySettings": {
          "dest": "9443", "show": false, "xver": 0, "spiderX": "/",
          "shortIds": [""],
          "publicKey": "<ПУБЛИЧНЫЙ КЛЮЧ ИЗ ПАНЕЛИ>",
          "privateKey": "<ПРИВАТНЫЙ КЛЮЧ ИЗ ПАНЕЛИ>",
          "serverNames": ["${DOMAIN}"]
        }
      }
    },
    {
      "tag": "NODE_XHTTP",
      "listen": "/dev/shm/xrxh.socket,0666",
      "protocol": "vless",
      "settings": { "clients": [], "fallbacks": [], "decryption": "none" },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "mode": "auto",
          "path": "/xhttppath/",
          "extra": {
            "noSSEHeader": true,
            "xPaddingBytes": "100-1000",
            "scMaxBufferedPosts": 30,
            "scMaxEachPostBytes": 1000000,
            "scStreamUpServerSecs": "20-80"
          }
        }
      }
    }
  ],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom" },
    { "tag": "BLOCK", "protocol": "blackhole" }${psi_out}
  ],
  "routing": {
    "rules": [${psi_rule}
      { "ip": ["ext:geoip.dat:ru"], "type": "field", "outboundTag": "DIRECT" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK" }
    ],
    "domainStrategy": "IPIfNonMatch"
  }
}
EOF

    cat > "${NODE_DIR}/panel-xhttp-host-extra.reference.json" <<EOF
{
  "xmux": {
    "cMaxReuseTimes": 0,
    "maxConcurrency": "16-32",
    "maxConnections": 0,
    "hKeepAlivePeriod": 0,
    "hMaxRequestTimes": "600-900",
    "hMaxReusableSecs": "1800-3000"
  },
  "noGRPCHeader": false,
  "xPaddingBytes": "100-1000",
  "downloadSettings": {
    "port": 443,
    "address": "${DOMAIN}",
    "network": "xhttp",
    "security": "tls",
    "tlsSettings": {
      "alpn": ["h2", "http/1.1"],
      "show": false,
      "serverName": "${DOMAIN}",
      "fingerprint": "chrome",
      "allowInsecure": false
    },
    "xhttpSettings": { "path": "/xhttppath/" }
  },
  "scMaxEachPostBytes": 1000000,
  "scMinPostsIntervalMs": 30,
  "scStreamUpServerSecs": "20-80"
}
EOF
    write_routing_reference_files

    cat > "${NODE_DIR}/panel-hosts.txt" <<EOF
Хосты в панели Remnawave (Хосты -> Создать). Для каждого выберите свой инбаунд и ноду.

[TCP]   инбаунд NODE_TCP
  Основные:    Адрес ${DOMAIN}   Порт 44443
  Расширенные: SNI ${DOMAIN}, "Переопределить SNI из адреса" ВКЛ, остальное пусто/по умолчанию

[XHTTP] инбаунд NODE_XHTTP
  Основные:    Адрес ${DOMAIN}   Порт 443
  Расширенные: SNI ${DOMAIN}, "Переопределить SNI из адреса" ВЫКЛ
               Хост ${DOMAIN}   Путь /xhttppath/
               Security Layer TLS   ALPN h2,http/1.1   Отпечаток chrome
  Xray Json & Raw -> xHTTP: содержимое panel-xhttp-host-extra.reference.json

[gRPC]  инбаунд NODE_GRPC
  Основные:    Адрес ${DOMAIN}   Порт 44444
  Расширенные: как у TCP (SNI ${DOMAIN}, переопределение SNI ВКЛ)
EOF
    cat "${NODE_DIR}/panel-hosts.txt"
    log "Справочные JSON для панели сохранены в ${NODE_DIR}/panel-*.reference.json, настройки хостов - ${NODE_DIR}/panel-hosts.txt"
    warn "Вставьте их вручную в настройки хостов/профиля Remnawave — путь и Host там уже проставлены на ${DOMAIN}."
    warn "ВАЖНО: в клиентской ссылке path обязан ТОЧНО совпадать (включая слеш на конце) с path на ноде: /xhttppath/"
}

# Связка нод (docs.rw/learn/server-routing) и балансер (docs.rw/learn/xray-json-advanced).
# Ноды уже заведены в панели, поэтому это куски для ВСТАВКИ в их существующие профили,
# а не новые профили: инбаунд-мост дописывается выходной ноде, outbound с правилами - входной.
write_routing_reference_files() {
    local bridge_port="${BRIDGE_PORT:-9999}"

    # Выходная нода: дописать этот объект в "inbounds" её профиля.
    # clients панель заполняет сама из сервисного юзера, пароль руками сюда не вписывается.
    cat > "${NODE_DIR}/panel-bridge-inbound.reference.json" <<EOF
{
  "tag": "BRIDGE_IN",
  "port": ${bridge_port},
  "listen": "0.0.0.0",
  "protocol": "shadowsocks",
  "settings": { "clients": [], "network": "tcp,udp" },
  "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
}
EOF

    # Входная нода: outbound дописать в её "outbounds", rules - в начало её "routing.rules".
    # Порядок правил важен: xray идёт сверху вниз, последнее правило - catch-all в мост.
    cat > "${NODE_DIR}/panel-entry-routing.reference.json" <<EOF
{
  "outbound": {
    "tag": "SS_OUTBOUND_TO_EXIT",
    "protocol": "shadowsocks",
    "settings": {
      "servers": [
        {
          "address": "<АДРЕС ВЫХОДНОЙ НОДЫ>",
          "port": ${bridge_port},
          "password": "<SS Password сервисного юзера: Users -> More Actions -> Detailed Info>",
          "level": 0,
          "method": "chacha20-ietf-poly1305"
        }
      ]
    }
  },
  "rules": [
    { "type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK" },
    { "type": "field", "domain": ["geosite:private"], "outboundTag": "BLOCK" },
    { "type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK" },
    { "type": "field", "ip": ["geoip:ru"], "outboundTag": "DIRECT" },
    { "type": "field", "domain": ["geosite:category-ru"], "outboundTag": "DIRECT" },
    { "type": "field", "inboundTag": ["<ТЕГ ИНБАУНДА ВХОДНОЙ НОДЫ>"], "outboundTag": "SS_OUTBOUND_TO_EXIT" }
  ]
}
EOF

    # Балансер - это клиентский конфиг: шаблон подписки (Advanced -> Xray JSON template)
    # на виртуальном хосте. Блок remnawave панель вырежет, подставив вместо него outbound'ы хостов.
    cat > "${NODE_DIR}/panel-balancer-template.reference.json" <<'EOF'
{
  "remnawave": {
    "injectHosts": [
      {
        "selector": { "type": "uuids", "values": ["<UUID СКРЫТОГО ХОСТА 1>", "<UUID СКРЫТОГО ХОСТА 2>"] },
        "selectFrom": "HIDDEN",
        "tagPrefix": "proxy"
      }
    ]
  },
  "log": { "loglevel": "warning" },
  "dns": { "servers": ["https://dns.google/dns-query"], "queryStrategy": "UseIPv4" },
  "inbounds": [],
  "burstObservatory": {
    "pingConfig": {
      "timeout": "3s",
      "interval": "1m",
      "sampling": 1,
      "destination": "https://connectivitycheck.gstatic.com/generate_204",
      "connectivity": ""
    },
    "subjectSelector": ["proxy"]
  },
  "routing": {
    "balancers": [
      {
        "tag": "balancer",
        "selector": ["proxy"],
        "strategy": {
          "type": "leastLoad",
          "settings": { "maxRTT": "1s", "expected": 2, "baselines": ["1s"], "tolerance": 0.01 }
        },
        "fallbackTag": "direct"
      }
    ],
    "rules": [
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "direct" },
      { "type": "field", "network": "tcp,udp", "balancerTag": "balancer" }
    ]
  },
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ]
}
EOF
    log "Связка нод и балансер: panel-bridge-inbound / panel-entry-routing / panel-balancer-template (.reference.json)"
    log "Куски дописываются в УЖЕ существующие профили нод: инбаунд - выходной, outbound+правила - входной."
    warn "Если эта нода будет выходной в связке - откройте порт моста: ufw allow ${bridge_port}/tcp (адрес для входной ноды: ${DOMAIN:-домен этой ноды})"
}

### ---------------------------------------------------------------------
### 4. fail2ban (juhnsooqa/servers: fail2ban.sh)
### ---------------------------------------------------------------------
install_fail2ban() {
    log "Установка fail2ban..."
    apt update -y
    apt install -y fail2ban
    systemctl enable fail2ban
    systemctl start fail2ban
    sleep 2

    log "Запись /etc/fail2ban/jail.local..."
    tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[DEFAULT]
# Добавьте сюда свои доверенные IP/подсети!
ignoreip = 127.0.0.1/8 ::1

bantime  = 3h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 2h
EOF

    systemctl restart fail2ban
    sleep 3

    if systemctl is-active --quiet fail2ban; then
        log "fail2ban успешно запущен."
        fail2ban-client status sshd 2>/dev/null || warn "jail sshd ещё активируется..."
    else
        err "fail2ban не запущен, смотрите: systemctl status fail2ban"
    fi
}

### ---------------------------------------------------------------------
### 5. roscom.dat автообновление (juhnsooqa/servers: roscom.sh)
### ---------------------------------------------------------------------
setup_roscom() {
    local work_dir="$NODE_DIR"
    if [ ! -f "${work_dir}/docker-compose.yml" ]; then
        warn "Не найден ${work_dir}/docker-compose.yml."
        ask "Укажите директорию с docker-compose.yml ноды" work_dir "$NODE_DIR"
    fi

    local roscom_file="${work_dir}/roscom.dat"
    local compose_file="${work_dir}/docker-compose.yml"
    local update_script="${work_dir}/update_roscom.sh"
    local container_name="remnanode"
    local download_url="https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat"

    log "[1/4] Скачивание roscom.dat..."
    wget -q -O "$roscom_file" "$download_url" || { err "Не удалось скачать roscom.dat"; return 1; }

    log "[2/4] Проверка монтирования в docker-compose.yml..."
    if grep -q "roscom.dat" "$compose_file"; then
        warn "Монтирование roscom.dat уже настроено."
    else
        cp "$compose_file" "${compose_file}.bak.$(date +%s)"
        # Добавляем volume строкой, без переписывания всего YAML - надёжнее, чем через yaml-парсер,
        # т.к. не меняет форматирование остального файла.
        sed -i "/remnanode:/,/volumes:/ s#\(volumes:\)#\1\n      - ${roscom_file}:/usr/local/share/xray/roscom.dat#" "$compose_file"
        if grep -q "roscom.dat" "$compose_file"; then
            log "Монтирование добавлено в docker-compose.yml."
        else
            warn "Не получилось добавить монтирование автоматически. Добавьте вручную в volumes сервиса remnanode:"
            warn "      - ${roscom_file}:/usr/local/share/xray/roscom.dat"
        fi
    fi

    log "[3/4] Скрипт автообновления ${update_script}..."
    cat > "$update_script" <<EOF
#!/bin/bash
DOWNLOAD_URL="${download_url}"
TARGET_FILE="${roscom_file}"
COMPOSE_DIR="${work_dir}"
CONTAINER_NAME="${container_name}"
LOG_FILE="/var/log/roscom_update.log"

exec >> "\$LOG_FILE" 2>&1
echo "--- \$(date '+%Y-%m-%d %H:%M:%S') ---"

TEMP_FILE="/tmp/roscom_temp_\$(date +%s).dat"
wget -q -O "\$TEMP_FILE" "\$DOWNLOAD_URL" || { echo "ОШИБКА: скачивание не удалось"; rm -f "\$TEMP_FILE"; exit 1; }

if [ -f "\$TARGET_FILE" ] && [ "\$(md5sum "\$TARGET_FILE" | awk '{print \$1}')" == "\$(md5sum "\$TEMP_FILE" | awk '{print \$1}')" ]; then
    echo "Файл не изменился."
    rm -f "\$TEMP_FILE"
    exit 0
fi

mv -f "\$TEMP_FILE" "\$TARGET_FILE"
echo "Файл обновлён, перезапуск контейнера..."
cd "\$COMPOSE_DIR" && docker compose restart "\$CONTAINER_NAME"
EOF
    chmod +x "$update_script"

    log "[4/4] Cron (каждый день в 03:00)..."
    if ! crontab -l 2>/dev/null | grep -qF "$update_script"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * $update_script") | crontab -
    else
        warn "Задача cron уже есть."
    fi

    log "Перезапуск контейнеров..."
    (cd "$work_dir" && docker compose down && docker compose up -d)
    log "roscom.dat настроен. Правила маршрутизации: \"ext:roscom.dat:category-ru\", \"ext:roscom.dat:youtube\" и т.д."
}

### ---------------------------------------------------------------------
### 6. Psiphon как выход для xray (psiphon/psiphon_install.sh, из Chara-Freedom/vps-psiphon)
### ---------------------------------------------------------------------
setup_psiphon() {
    warn "Ставить только на зарубежную ноду: трафик Psiphon узнаётся DPI."
    install_docker
    local region args=()
    read -rp "Страна выхода Psiphon (DE или пул DE,NL,FR; Enter = авто): " region
    [ -n "$region" ] && args=(--region "$region")
    bash <(curl -fsSL "${REPO_RAW}/psiphon/psiphon_install.sh") "${args[@]}" || { err "Установка Psiphon не удалась."; return 1; }
    # Пересобираем справочный профиль, чтобы в нём появился psiphon-out
    [ -f "${NODE_DIR}/panel-profile.reference.json" ] && write_panel_reference_files
    log "Psiphon установлен. Управление: allinone -> Psiphon, или напрямую: vps-psiphon"
}

psiphon_menu() {
    if ! command -v vps-psiphon &>/dev/null; then
        warn "Psiphon ещё не установлен."
        read -rp "Установить сейчас? [Y/n]: " a
        [[ "$a" =~ ^[Nn]$ ]] || setup_psiphon
        return
    fi
    local c v
    echo -e "${CYAN}${BOLD}=== Psiphon ===${NC}"
    echo "  1) Статус          5) Логи клиента"
    echo "  2) Сменить IP      6) Журнал вотчдога"
    echo "  3) Страна выхода   7) Переустановить/обновить"
    echo "  4) Тест скорости   8) Удалить"
    echo "  0) Назад"
    read -rp "Выбор: " c
    case "$c" in
        1) vps-psiphon ;;
        2) vps-psiphon rotate ;;
        3) read -rp "Код страны (DE, NL, JP...; auto = любая): " v; vps-psiphon region "$v" ;;
        4) vps-psiphon speed ;;
        5) vps-psiphon logs 50 ;;
        6) vps-psiphon watchdog 50 ;;
        7) setup_psiphon ;;
        8) read -rp "Точно удалить Psiphon? [y/N]: " v; [[ "$v" =~ ^[Yy]$ ]] && vps-psiphon uninstall ;;
    esac
}

### ---------------------------------------------------------------------
### 7. Панель Remnawave по API: профиль из образца + сама нода
### ---------------------------------------------------------------------
need_jq() { command -v jq &>/dev/null || { apt update -y; apt install -y jq; }; }

load_panel_vars() {
    [ -f "$PANEL_STATE" ] && source "$PANEL_STATE"
    [ -n "${PANEL_URL:-}" ]   || ask "URL панели (https://panel.example.com)" PANEL_URL
    [ -n "${PANEL_TOKEN:-}" ] || ask "API-токен панели (в панели: Настройки -> API токены)" PANEL_TOKEN
    PANEL_URL="${PANEL_URL%/}"
    cat > "$PANEL_STATE" <<EOF
PANEL_URL="$PANEL_URL"
PANEL_TOKEN="$PANEL_TOKEN"
EOF
    chmod 600 "$PANEL_STATE"
}

# panel_api МЕТОД ПУТЬ [ТЕЛО] -> ответ в stdout; не 2xx = ненулевой код возврата
panel_api() {
    local method="$1" path="$2" body="${3:-}" out code
    local args=(-sS -m 30 -X "$method" -H "Authorization: Bearer ${PANEL_TOKEN}" -H "Content-Type: application/json")
    [ -n "$body" ] && args+=(--data-binary "$body")
    out=$(curl "${args[@]}" -w $'\n%{http_code}' "${PANEL_URL}/api/${path}") || { err "Панель недоступна: ${PANEL_URL}"; return 1; }
    code="${out##*$'\n'}"
    printf '%s' "${out%$'\n'*}"
    case "$code" in
        2*) return 0 ;;
        401|403) err "Панель отклонила токен (HTTP ${code})."; return 1 ;;
        *) err "API ${method} /${path} -> HTTP ${code}"; return 1 ;;
    esac
}

# SECRET_KEY ноды панель отдаёт сама - спрашивать его не нужно
panel_secret_key() {
    [ -f "$PANEL_STATE" ] || return 1
    command -v jq &>/dev/null || return 1
    source "$PANEL_STATE"
    [ -n "${PANEL_URL:-}" ] && [ -n "${PANEL_TOKEN:-}" ] || return 1
    panel_api GET keygen 2>/dev/null | jq -er '.response.secretKey // empty' 2>/dev/null
}

register_node_in_panel() {
    need_jq
    load_panel_vars
    load_common_vars

    local profiles uuids names i n
    profiles=$(panel_api GET config-profiles) || return 1
    mapfile -t uuids < <(jq -r '.response.configProfiles[].uuid' <<<"$profiles")
    mapfile -t names < <(jq -r '.response.configProfiles[].name'  <<<"$profiles")

    echo -e "${BOLD}Профиль-образец (копируется целиком, меняются только теги и SNI):${NC}"
    for i in "${!uuids[@]}"; do printf "  %d) %s\n" "$((i+1))" "${names[$i]}"; done
    echo "  0) локальный ${NODE_DIR}/panel-profile.reference.json"
    ask "Номер" n "1"

    local tmpl
    if [ "$n" = "0" ]; then
        [ -f "${NODE_DIR}/panel-profile.reference.json" ] || { err "Нет ${NODE_DIR}/panel-profile.reference.json"; return 1; }
        tmpl=$(cat "${NODE_DIR}/panel-profile.reference.json")
        warn "Reality-ключи в этом образце - заглушки, впишите их в панели после создания."
    else
        local src="${uuids[$((n-1))]:-}"
        [ -n "$src" ] || { err "Нет такого номера."; return 1; }
        tmpl=$(panel_api GET "config-profiles/${src}" | jq -e '.response.config') || { err "Не удалось получить конфиг образца."; return 1; }
    fi

    local prefix name
    ask "Тег инбаунда в конфиге" prefix "$(echo "${DOMAIN%%.*}" | tr -cd 'A-Za-z0-9_-')"
    [ -n "$prefix" ] || { err "Тег не может быть пустым."; return 1; }
    ask "Имя профиля и ноды в панели" name "$prefix"
    [ "${#name}" -ge 3 ] || { err "Имя профиля/ноды в панели - минимум 3 символа."; return 1; }

    # Теги: pl2 -> finl1, ITALY_MILAN_TCP -> finl1_TCP (меняется всё до последнего "_").
    # SNI Reality (если в образце он есть) обязан указывать на домен ЭТОЙ ноды,
    # иначе клиент получит сертификат чужого домена и хендшейк развалится.
    local newcfg
    newcfg=$(jq --arg p "$prefix" --arg d "$DOMAIN" '
        .inbounds = [ .inbounds[] | .tag = (if (.tag | test("_")) then $p + "_" + (.tag | split("_") | last) else $p end) ]
        | walk(if type == "object" and has("serverNames") then .serverNames = [$d] else . end)
    ' <<<"$tmpl") || { err "Не удалось преобразовать конфиг образца."; return 1; }

    # Образец может опираться на то, чего на этой ноде ещё нет: мёртвый psiphon-out или
    # отсутствующий roscom.dat - и xray либо не стартует, либо роняет часть маршрутов в никуда.
    if grep -q 'psiphon-out' <<<"$newcfg"; then
        if [ ! -r /etc/default/vps-psiphon ]; then
            warn "В образце есть outbound psiphon-out, но Psiphon на этой ноде не стоит."
            read -rp "Поставить Psiphon сейчас? [Y/n]: " a
            [[ "$a" =~ ^[Nn]$ ]] || setup_psiphon
        fi
        if [ -r /etc/default/vps-psiphon ]; then
            local pb pp
            read -r pb pp < <(. /etc/default/vps-psiphon; echo "${BIND:-172.17.0.1} ${SOCKS_PORT:-1080}")
            newcfg=$(jq --arg pb "$pb" --argjson pp "$pp" \
                '(.outbounds[]? | select(.tag == "psiphon-out") | .settings) |= (.address = $pb | .port = $pp)' <<<"$newcfg")
            log "psiphon-out направлен на ${pb}:${pp}."
        else
            warn "psiphon-out останется нерабочим - маршруты через него не пойдут."
        fi
    fi
    if grep -q 'roscom.dat' <<<"$newcfg" && [ ! -f "${NODE_DIR}/roscom.dat" ]; then
        warn "Образец использует ext:roscom.dat - без этого файла xray на ноде не стартует."
        read -rp "Настроить roscom.dat сейчас? [Y/n]: " a
        [[ "$a" =~ ^[Nn]$ ]] || setup_roscom
    fi

    log "Создаю профиль ${name}, теги: $(jq -r '[.inbounds[].tag] | join(", ")' <<<"$newcfg")"
    local created puuid inbounds
    created=$(panel_api POST config-profiles "$(jq -n --arg n "$name" --argjson c "$newcfg" '{name:$n, config:$c}')") || return 1
    puuid=$(jq -r '.response.uuid' <<<"$created")
    inbounds=$(jq -c '[.response.inbounds[].uuid]' <<<"$created")

    local cc
    ask "Код страны ноды (2 буквы)" cc "XX"
    panel_api POST nodes "$(jq -n --arg n "$name" --arg a "$DOMAIN" --argjson p "$NODE_PORT" \
        --arg cc "$cc" --arg pu "$puuid" --argjson ib "$inbounds" \
        '{name:$n, address:$a, port:$p, countryCode:($cc|ascii_upcase),
          configProfile:{activeConfigProfileUuid:$pu, activeInbounds:$ib}}')" >/dev/null || return 1

    log "Нода ${name} (${DOMAIN}:${NODE_PORT}) добавлена в панель, все инбаунды включены."
    warn "Хосты скрипт не создаёт - настройки для них в ${NODE_DIR}/panel-hosts.txt."
}

# Связка двух УЖЕ заведённых в панели нод (docs.rw/learn/server-routing):
# инбаунд-мост в профиль выходной ноды -> internal squad с ним -> сервисный юзер ->
# его SS-пароль в outbound профиля входной ноды + catch-all правило.
link_nodes_via_bridge() {
    need_jq
    load_panel_vars

    local nodes count
    nodes=$(panel_api GET nodes) || return 1
    count=$(jq '.response | length' <<<"$nodes")
    [ "$count" -ge 2 ] || { err "В панели меньше двух нод - связывать нечего."; return 1; }

    echo -e "${BOLD}Ноды в панели:${NC}"
    jq -r '.response | to_entries[] | "  \(.key+1)) \(.value.name)  [\(.value.address)]  профиль: \(.value.configProfile.activeConfigProfileUuid // "нет")"' <<<"$nodes"

    local n_in n_out
    ask "Номер ВХОДНОЙ ноды (куда подключаются клиенты)" n_in
    ask "Номер ВЫХОДНОЙ ноды (куда уходит трафик)" n_out
    [ "$n_in" != "$n_out" ] || { err "Входная и выходная нода должны быть разными."; return 1; }

    local in_node out_node
    in_node=$(jq -e ".response[$((n_in-1))]" <<<"$nodes")  || { err "Нет ноды с номером $n_in."; return 1; }
    out_node=$(jq -e ".response[$((n_out-1))]" <<<"$nodes") || { err "Нет ноды с номером $n_out."; return 1; }

    local in_uuid in_name in_profile out_uuid out_name out_addr out_profile
    in_uuid=$(jq -r '.uuid' <<<"$in_node");   in_name=$(jq -r '.name' <<<"$in_node")
    in_profile=$(jq -r '.configProfile.activeConfigProfileUuid // empty' <<<"$in_node")
    out_uuid=$(jq -r '.uuid' <<<"$out_node"); out_name=$(jq -r '.name' <<<"$out_node")
    out_addr=$(jq -r '.address' <<<"$out_node")
    out_profile=$(jq -r '.configProfile.activeConfigProfileUuid // empty' <<<"$out_node")
    [ -n "$in_profile" ] && [ -n "$out_profile" ] || { err "У одной из нод не выбран профиль - свяжите её с профилем в панели."; return 1; }

    local bport btag squad_name user_name
    ask "Порт моста на выходной ноде" bport "9999"
    ask "Тег инбаунда-моста" btag "BRIDGE_${out_name//[^A-Za-z0-9_]/_}"
    ask "Имя squad для моста" squad_name "bridge-${out_name//[^A-Za-z0-9_ -]/-}"
    ask "Имя сервисного юзера" user_name "bridge_$(echo "${in_name}_${out_name}" | tr -cd 'A-Za-z0-9_-' | cut -c1-28)"

    log "[1/5] Инбаунд ${btag}:${bport} в профиль выходной ноды ${out_name}..."
    local out_cfg new_out_cfg
    out_cfg=$(panel_api GET "config-profiles/${out_profile}" | jq -e '.response.config') || return 1
    new_out_cfg=$(jq --arg t "$btag" --argjson p "$bport" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $t)) + [{
            tag: $t, port: $p, listen: "0.0.0.0", protocol: "shadowsocks",
            settings: { clients: [], network: "tcp,udp" },
            sniffing: { enabled: true, destOverride: ["http","tls","quic"] } }])' <<<"$out_cfg") || return 1
    panel_api PATCH config-profiles "$(jq -n --arg u "$out_profile" --argjson c "$new_out_cfg" '{uuid:$u, config:$c}')" >/dev/null || return 1

    log "[2/5] Включаю ${btag} на ноде ${out_name}..."
    local bridge_inbound_uuid active
    bridge_inbound_uuid=$(panel_api GET "config-profiles/${out_profile}/inbounds" \
        | jq -er --arg t "$btag" '.response.inbounds[] | select(.tag == $t) | .uuid' | head -1) \
        || { err "Панель не отдала uuid инбаунда ${btag}."; return 1; }
    active=$(jq -c --arg b "$bridge_inbound_uuid" '[(.configProfile.activeInbounds[].uuid), $b] | unique' <<<"$out_node")
    panel_api PATCH nodes "$(jq -n --arg u "$out_uuid" --arg p "$out_profile" --argjson ib "$active" \
        '{uuid:$u, configProfile:{activeConfigProfileUuid:$p, activeInbounds:$ib}}')" >/dev/null || return 1

    log "[3/5] Squad ${squad_name} только с мостом..."
    local squads squad_uuid
    squads=$(panel_api GET internal-squads) || return 1
    squad_uuid=$(jq -r --arg n "$squad_name" '(.response.internalSquads // .response)[] | select(.name == $n) | .uuid' <<<"$squads" | head -1)
    if [ -n "$squad_uuid" ]; then
        warn "Squad ${squad_name} уже есть, использую его."
    else
        squad_uuid=$(panel_api POST internal-squads "$(jq -n --arg n "$squad_name" --arg b "$bridge_inbound_uuid" \
            '{name:$n, inbounds:[$b]}')" | jq -r '.response.uuid') || return 1
    fi

    log "[4/5] Сервисный юзер ${user_name} (без лимита, до 2099)..."
    local sspass created_user
    sspass=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-24)
    created_user=$(panel_api POST users "$(jq -n --arg u "$user_name" --arg s "$squad_uuid" --arg p "$sspass" \
        '{username:$u, expireAt:"2099-01-01T00:00:00.000Z", trafficLimitBytes:0,
          trafficLimitStrategy:"NO_RESET", status:"ACTIVE", ssPassword:$p, activeInternalSquads:[$s]}')") || {
        err "Не удалось создать юзера. Если он уже есть - задайте другое имя или удалите старого в панели."; return 1; }
    sspass=$(jq -r --arg p "$sspass" '.response.ssPassword // $p' <<<"$created_user")

    log "[5/5] Outbound и правило в профиль входной ноды ${in_name}..."
    local in_tags in_cfg new_in_cfg
    in_tags=$(jq -c '[.configProfile.activeInbounds[].tag]' <<<"$in_node")
    [ "$(jq 'length' <<<"$in_tags")" -gt 0 ] || { err "У входной ноды нет активных инбаундов."; return 1; }
    in_cfg=$(panel_api GET "config-profiles/${in_profile}" | jq -e '.response.config') || return 1
    # Правило идёт в КОНЕЦ: оно catch-all, и перед ним должны отработать уже существующие
    # правила профиля (роскомнадзорные списки, psiphon-out и прочее).
    new_in_cfg=$(jq --arg a "$out_addr" --argjson p "$bport" --arg pw "$sspass" --argjson t "$in_tags" '
        .outbounds = ((.outbounds // []) | map(select(.tag != "SS_OUTBOUND_TO_EXIT")) + [{
            tag: "SS_OUTBOUND_TO_EXIT", protocol: "shadowsocks",
            settings: { servers: [{ address: $a, port: $p, password: $pw, level: 0,
                                    method: "chacha20-ietf-poly1305" }] } }])
        | .routing.rules = (((.routing.rules // []) | map(select(.outboundTag != "SS_OUTBOUND_TO_EXIT"))) + [{
            type: "field", inboundTag: $t, outboundTag: "SS_OUTBOUND_TO_EXIT" }])' <<<"$in_cfg") || return 1
    panel_api PATCH config-profiles "$(jq -n --arg u "$in_profile" --argjson c "$new_in_cfg" '{uuid:$u, config:$c}')" >/dev/null || return 1

    log "Готово: ${in_name} -> ${out_name} (${out_addr}:${bport}), правило для инбаундов $(jq -r 'join(", ")' <<<"$in_tags")."
    if [ "${DOMAIN:-}" = "$out_addr" ]; then
        ufw allow "${bport}/tcp" && log "Порт ${bport}/tcp открыт на этой (выходной) ноде."
    else
        warn "На выходной ноде ${out_addr} откройте порт: ufw allow ${bport}/tcp"
    fi
    warn "Трафик, который не поймали прежние правила профиля ${in_name}, теперь уходит в мост."
}

### ---------------------------------------------------------------------
### 8. Опциональные сторонние установщики (НЕ встраиваются целиком)
### ---------------------------------------------------------------------
run_node_accelerator() {
    warn "Это сторонний репозиторий jestivald/node-accelerator (оптимизация сети/защита, не про Remnawave)."
    read -rp "Склонировать и запустить его меню? [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] || return 0
    if [ ! -d /opt/node-accelerator ]; then
        git clone https://github.com/jestivald/node-accelerator.git /opt/node-accelerator
    else
        (cd /opt/node-accelerator && git pull)
    fi
    (cd /opt/node-accelerator && bash install.sh)
}

run_reverse_proxy_pro() {
    warn "Это сторонний установщик vladimir-kartamyshev/remnawave-reverse-proxy-pro (панель+reverse-proxy, отдельный проект)."
    warn "Скрипт скачивается напрямую с GitHub автора и выполняется как есть - проверьте доверие к источнику."
    read -rp "Скачать и запустить его? [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] || return 0
    bash <(curl -fsSL "https://raw.githubusercontent.com/vladimir-kartamyshev/remnawave-reverse-proxy-pro/refs/heads/main/install_remnawave.sh")
}

### ---------------------------------------------------------------------
### Основная установка ноды одним вызовом
### ---------------------------------------------------------------------
full_install() {
    # Панель спрашиваем первой: по её API берётся SECRET_KEY, а в конце туда же добавляется нода.
    if [ ! -f "$PANEL_STATE" ]; then
        read -rp "Добавить ноду в панель автоматически по API (нужен токен)? [Y/n]: " a
        if [[ ! "$a" =~ ^[Nn]$ ]]; then
            need_jq
            load_panel_vars
        fi
    fi
    load_common_vars
    setup_firewall
    block_icmp
    install_nginx
    create_stub
    issue_ssl || { err "Без сертификата дальше нельзя. Исправьте DNS и запустите снова."; return 1; }
    configure_nginx
    install_docker
    setup_remnanode
    [ -f "$PANEL_STATE" ] && register_node_in_panel
    log "Базовая установка ноды завершена."
    read -rp "Установить fail2ban сейчас? [Y/n]: " a
    [[ "$a" =~ ^[Nn]$ ]] || install_fail2ban
    read -rp "Настроить roscom.dat сейчас? [Y/n]: " a
    [[ "$a" =~ ^[Nn]$ ]] || setup_roscom
}

### ---------------------------------------------------------------------
### Меню / CLI
### ---------------------------------------------------------------------
# Команда `allinone` на сервере: каждый раз качает свежий скрипт с GitHub и запускает его.
install_cli() {
    cat > "$CLI_PATH" <<EOF
#!/usr/bin/env bash
s="\$(curl -fsSL ${REPO_RAW}/remnawave-node-setup.sh)" || { echo "allinone: не удалось скачать скрипт" >&2; exit 1; }
exec bash -c "\$s" allinone "\$@"
EOF
    chmod 755 "$CLI_PATH"
}

print_menu() {
    clear
    echo -e "${CYAN}${BOLD}=== Remnawave Node Setup ===${NC}"
    echo -e "  ${GREEN}1)${NC} Полная установка ноды (firewall+icmp+nginx+ssl+docker+remnanode)"
    echo -e "  ${GREEN}2)${NC} fail2ban"
    echo -e "  ${GREEN}3)${NC} roscom.dat + автообновление"
    echo -e "  ${GREEN}6)${NC} Psiphon-выход (установка / управление)"
    echo -e "  ${GREEN}7)${NC} Добавить ноду в панель (профиль из образца + нода)"
    echo -e "  ${GREEN}8)${NC} Связать две ноды в панели (вход -> мост -> выход)"
    echo -e "  ${YELLOW}4)${NC} [опционально, сторонний репо] node-accelerator"
    echo -e "  ${YELLOW}5)${NC} [опционально, сторонний репо] remnawave-reverse-proxy-pro"
    echo -e "  ${RED}0)${NC} Выход"
    echo -ne "${BOLD}Выбор: ${NC}"
}

main() {
    require_root
    install_cli
    # На свежем VPS apt часто занят unattended-upgrades: пусть все apt (и сторонние установщики) ждут lock до 10 минут, а не падают
    echo 'DPkg::Lock::Timeout "600";' > /etc/apt/apt.conf.d/99allinone-lock-wait
    case "${1:-}" in
        full)           full_install ;;
        fail2ban)       install_fail2ban ;;
        roscom)         setup_roscom ;;
        psiphon)        psiphon_menu ;;
        panel)          register_node_in_panel ;;
        link)           link_nodes_via_bridge ;;
        accelerator)    run_node_accelerator ;;
        reverse-proxy)  run_reverse_proxy_pro ;;
        "")
            while true; do
                print_menu
                read -r choice
                case "$choice" in
                    1) full_install ;;
                    2) install_fail2ban ;;
                    3) setup_roscom ;;
                    4) run_node_accelerator ;;
                    5) run_reverse_proxy_pro ;;
                    6) psiphon_menu ;;
                    7) register_node_in_panel ;;
                    8) link_nodes_via_bridge ;;
                    0) exit 0 ;;
                    *) warn "Неверный выбор" ;;
                esac
                read -rp "Нажмите Enter для продолжения..." _
            done
            ;;
        *)
            err "Неизвестный аргумент: $1"
            echo "Использование: $0 [full|fail2ban|roscom|psiphon|panel|link|accelerator|reverse-proxy]"
            exit 1
            ;;
    esac
}

main "$@"
