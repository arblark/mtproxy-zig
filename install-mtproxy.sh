#!/usr/bin/env bash
#
# MTProto Proxy — full automated installer for a fresh VPS
# Upstream: https://github.com/sleep3r/mtproto.zig
#
# Usage:
#   curl -sSfL https://raw.githubusercontent.com/arblark/mtproxy-zig/main/install-mtproxy.sh | sudo bash
#   curl -sSfL ... | sudo CF_TOKEN=xxx CF_ZONE=yyy bash
#
# With AmneziaWG tunnel (for regions where Telegram is blocked):
#   curl -sSfL ... | sudo AWG_CONF=/path/to/awg.conf bash
#
# Supported: Ubuntu 20.04+, Debian 11+  |  x86_64, aarch64

set -euo pipefail

# ── Config ──────────────────────────────────────────────────
ZIG_VERSION="0.15.2"
INSTALL_DIR="/opt/mtproto-proxy"
REPO_URL="https://github.com/sleep3r/mtproto.zig.git"
SERVICE_NAME="mtproto-proxy"
PROXY_PORT="${PROXY_PORT:-443}"
TLS_DOMAIN="${TLS_DOMAIN:-wb.ru}"
NUM_USERS="${NUM_USERS:-1}"
NFQUEUE_NUM=200
NFQWS_TTL="${NFQWS_TTL:-6}"
NGINX_PORT=8443
AWG_CONF="${AWG_CONF:-}"

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# ── Logging ─────────────────────────────────────────────────
LOG_FILE="/var/log/mtproto-install.log"
touch "$LOG_FILE"
log_to_file() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
trap 'log_to_file "Script exited with code $?"' EXIT

info()    { echo -e "${CYAN}▸${RESET} $*"; }
ok()      { echo -e "${GREEN}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET} $*"; }
fail()    { echo -e "${RED}✗${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }

# ── Banner ──────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
cat << 'BANNER'
  __  __ _____ ____            _
 |  \/  |_   _|  _ \ _ __ ___ | |_ ___
 | |\/| | | | | |_) | '__/ _ \| __/ _ \
 | |  | | | | |  __/| | | (_) | || (_) |
 |_|  |_| |_| |_|   |_|  \___/ \__\___/
              .zig installer
BANNER
echo -e "${RESET}"
echo -e "${DIM}$(date '+%Y-%m-%d %H:%M:%S') | Лог: ${LOG_FILE}${RESET}"
echo ""

# ── Preflight ───────────────────────────────────────────────
section "Предварительные проверки"

[[ $EUID -eq 0 ]] || fail "Запустите от root: sudo bash $0"

if [[ ! -f /etc/debian_version ]] && [[ ! -f /etc/lsb-release ]]; then
    warn "Скрипт тестировался на Ubuntu/Debian."
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ZIG_ARCH="x86_64" ;;
    aarch64) ZIG_ARCH="aarch64" ;;
    *)       fail "Неподдерживаемая архитектура: $ARCH" ;;
esac
ok "Архитектура: $ARCH"

TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
ok "RAM: ${TOTAL_RAM_MB} MB"
[[ $TOTAL_RAM_MB -lt 256 ]] && warn "Мало RAM (<256 MB). Сборка может быть медленной."

ok "CPU: $(nproc) ядер"

# ── Package manager repair ──────────────────────────────────
section "Установка системных зависимостей"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# Disable needrestart interactive prompts that break piped installs
if [[ -d /etc/needrestart/conf.d ]]; then
    echo '$nrconf{restart} = "a";' > /etc/needrestart/conf.d/99-autorestart.conf
fi

info "Подготовка пакетного менеджера..."

systemctl stop unattended-upgrades.service 2>/dev/null || true
systemctl disable unattended-upgrades.service 2>/dev/null || true
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

pkill -9 -f unattended-upgr 2>/dev/null || true
pkill -9 -f 'apt\.(get|daily)' 2>/dev/null || true
pkill -9 -f dpkg 2>/dev/null || true
sleep 2

rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
      /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true

# Remove broken kernel packages that block all dpkg operations
CURRENT_KERNEL=$(uname -r)
BROKEN_PKGS=$(dpkg -l 'linux-image-*' 'linux-modules-*' 'linux-firmware' 'initramfs-tools' 2>/dev/null | \
    awk '/^(iF|iU|iW|iHR)/{print $2}' | grep -v "$CURRENT_KERNEL" || true)

if [[ -n "$BROKEN_PKGS" ]]; then
    info "Удаляем сломанные пакеты ядра..."
    for pkg in $BROKEN_PKGS; do
        dpkg --remove --force-remove-reinstreq "$pkg" 2>/dev/null || true
    done
    rm -f /boot/initrd.img-*.old 2>/dev/null || true
fi

dpkg --configure -a --force-confdef --force-confold > /dev/null 2>&1 || true
apt-get -f install -y > /dev/null 2>&1 || true
ok "Пакетный менеджер готов"

fix_dpkg() {
    pkill -9 -f apt 2>/dev/null || true
    pkill -9 -f dpkg 2>/dev/null || true
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null || true
    local broken
    broken=$(dpkg -l 2>/dev/null | awk '/^(iF|iU|iW)/{print $2}' | grep -E 'linux-|initramfs|firmware' || true)
    for pkg in $broken; do
        dpkg --remove --force-remove-reinstreq "$pkg" 2>/dev/null || true
    done
    dpkg --configure -a --force-confdef --force-confold > /dev/null 2>&1 || true
    apt-get -f install -y > /dev/null 2>&1 || true
}

wait_for_apt() {
    local i=0
    while [[ -f /var/lib/dpkg/lock-frontend ]] && lsof /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; do
        [[ $i -eq 0 ]] && info "Ожидание apt..."
        sleep 3; i=$((i + 3))
        if [[ $i -ge 60 ]]; then
            pkill -9 -f apt 2>/dev/null || true
            rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null || true
            break
        fi
    done
}

# ── Install base packages ───────────────────────────────────
info "Обновление пакетных списков..."
apt-get update -qq > /dev/null 2>&1 || true

info "Установка пакетов..."
BASE_PACKAGES=(git curl wget openssl jq tar xz-utils build-essential iptables
    libnetfilter-queue-dev libcap-dev libmnl-dev zlib1g-dev)

if ! apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    "${BASE_PACKAGES[@]}" > /dev/null 2>&1; then
    warn "Ошибка — пробуем починить dpkg..."
    fix_dpkg
    apt-get install -y "${BASE_PACKAGES[@]}" > /dev/null 2>&1 || true
fi

# Nginx: prevent default IPv6 config from breaking install on IPv4-only hosts
info "Установка nginx..."
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
echo "# Empty default" > /etc/nginx/sites-available/default
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
systemctl mask nginx.service 2>/dev/null || true
apt-get install -y nginx > /dev/null 2>&1 || true
systemctl unmask nginx.service 2>/dev/null || true

apt-get install -y certbot python3-certbot-nginx > /dev/null 2>&1 || true

if ! command -v xxd &>/dev/null; then
    apt-get install -y xxd 2>/dev/null || apt-get install -y vim-common 2>/dev/null || true
fi

for cmd in git curl openssl; do
    command -v "$cmd" &>/dev/null || fail "Не установлена зависимость: $cmd"
done
command -v xxd &>/dev/null || fail "xxd не удалось установить"

ok "Все зависимости установлены"

# ── Install Zig ─────────────────────────────────────────────
section "Установка Zig ${ZIG_VERSION}"

if command -v zig &>/dev/null && zig version 2>/dev/null | grep -q "$ZIG_VERSION"; then
    ok "Zig $ZIG_VERSION уже установлен"
else
    ZIG_TAR="zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz"
    ZIG_URLS=(
        "https://mirror.bazel.build/ziglang.org/download/${ZIG_VERSION}/${ZIG_TAR}"
        "https://zig.linus.dev/download/${ZIG_VERSION}/${ZIG_TAR}"
        "https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TAR}"
    )
    cd /tmp
    rm -f "$ZIG_TAR" 2>/dev/null || true
    ZIG_OK=false
    for url in "${ZIG_URLS[@]}"; do
        mirror=$(echo "$url" | awk -F/ '{print $3}')
        info "Скачивание Zig из ${mirror}..."
        if curl -fSL --connect-timeout 10 --speed-limit 100000 --speed-time 15 \
                --retry 1 --retry-delay 3 -o "$ZIG_TAR" "$url" 2>&1; then
            ZIG_OK=true
            break
        fi
        rm -f "$ZIG_TAR" 2>/dev/null || true
        warn "${mirror} недоступен, пробуем следующее зеркало..."
    done
    $ZIG_OK || fail "Не удалось скачать Zig ни с одного зеркала. Проверьте сеть: curl -I https://mirror.bazel.build"
    info "Распаковка..."
    tar xf "$ZIG_TAR"
    rm -rf /usr/local/zig
    mv "zig-${ZIG_ARCH}-linux-${ZIG_VERSION}" /usr/local/zig
    ln -sf /usr/local/zig/zig /usr/local/bin/zig
    rm -f "$ZIG_TAR"
    ok "Zig $ZIG_VERSION установлен → $(zig version)"
fi

# ── Clone & build ───────────────────────────────────────────
section "Сборка MTProto proxy"

TMPBUILD=$(mktemp -d)
cleanup() { rm -rf "$TMPBUILD"; log_to_file "Cleanup done"; }
trap cleanup EXIT

info "Клонирование репозитория..."
for _try in 1 2 3; do
    git clone --depth 1 "$REPO_URL" "$TMPBUILD" && break
    warn "Попытка ${_try}/3 не удалась, повтор через 5с..."
    rm -rf "$TMPBUILD"; TMPBUILD=$(mktemp -d); sleep 5
done
[[ -d "$TMPBUILD/src" ]] || fail "Не удалось клонировать после 3 попыток"
cd "$TMPBUILD"

info "Сборка (ReleaseFast)... ~1-3 мин."
BUILD_START=$(date +%s)
zig build -Doptimize=ReleaseFast 2>&1 || fail "Сборка не удалась"
BUILD_TIME=$(( $(date +%s) - BUILD_START ))

BINARY_SIZE_KB=$(( $(stat -c%s zig-out/bin/mtproto-proxy 2>/dev/null || echo 0) / 1024 ))
ok "Сборка: ${BUILD_TIME}с | ${BINARY_SIZE_KB} KB"

# ── Install ─────────────────────────────────────────────────
section "Установка"

mkdir -p "$INSTALL_DIR"

if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    info "Остановка существующего сервиса..."
    systemctl stop "$SERVICE_NAME"
fi

cp zig-out/bin/mtproto-proxy "$INSTALL_DIR/mtproto-proxy"
chmod +x "$INSTALL_DIR/mtproto-proxy"

# Copy deploy helper scripts for future updates
cp "$TMPBUILD/deploy"/*.sh "$INSTALL_DIR/" 2>/dev/null || true
cp "$TMPBUILD/deploy/capture_template.py" "$INSTALL_DIR/" 2>/dev/null || true
chmod +x "$INSTALL_DIR"/*.sh 2>/dev/null || true
ok "Бинарник + скрипты установлены → $INSTALL_DIR/"

# ── Config ──────────────────────────────────────────────────
section "Конфигурация"

generate_secret() { openssl rand -hex 16; }

if [[ ! -f "$INSTALL_DIR/config.toml" ]]; then
    info "Генерация конфигурации (пользователей: ${NUM_USERS})..."

    USERS_BLOCK=""
    SECRETS=()
    for i in $(seq 1 "$NUM_USERS"); do
        SECRET=$(generate_secret)
        SECRETS+=("$SECRET")
        if [[ $NUM_USERS -eq 1 ]]; then
            USERS_BLOCK+="user = \"${SECRET}\""
        else
            USERS_BLOCK+="user${i} = \"${SECRET}\""
        fi
        [[ $i -lt $NUM_USERS ]] && USERS_BLOCK+=$'\n'
    done

    cat > "$INSTALL_DIR/config.toml" << EOF
[general]
use_middle_proxy = false

[server]
port = ${PROXY_PORT}
# tag = "1234567890abcdef1234567890abcdef"

[censorship]
tls_domain = "${TLS_DOMAIN}"
mask = true
mask_port = ${NGINX_PORT}
desync = true
fast_mode = true

[access.users]
${USERS_BLOCK}
EOF
    ok "Конфигурация создана"
else
    ok "Конфигурация уже существует, сохраняем"
    SECRETS=()
    while IFS= read -r s; do
        SECRETS+=("$s")
    done < <(grep -oP '=\s*"\K[0-9a-f]{32}' "$INSTALL_DIR/config.toml" || true)
fi

TLS_DOMAIN=$(grep -oP 'tls_domain\s*=\s*"\K[^"]+' "$INSTALL_DIR/config.toml" 2>/dev/null || echo "$TLS_DOMAIN")
PROXY_PORT=$(grep -oP '^\s*port\s*=\s*\K[0-9]+' "$INSTALL_DIR/config.toml" 2>/dev/null || echo "$PROXY_PORT")

# ── System user ─────────────────────────────────────────────
if ! id -u mtproto &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin mtproto
    ok "Создан пользователь 'mtproto'"
fi
chown -R mtproto:mtproto "$INSTALL_DIR"

# ── Systemd service ─────────────────────────────────────────
section "Systemd сервис"

if [[ -f "$TMPBUILD/deploy/mtproto-proxy.service" ]]; then
    cp "$TMPBUILD/deploy/mtproto-proxy.service" /etc/systemd/system/
else
    cat > /etc/systemd/system/${SERVICE_NAME}.service << 'EOF'
[Unit]
Description=MTProto Proxy (Zig)
Documentation=https://github.com/sleep3r/mtproto.zig
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mtproto
Group=mtproto
WorkingDirectory=/opt/mtproto-proxy
ExecStart=/opt/mtproto-proxy/mtproto-proxy /opt/mtproto-proxy/config.toml
Restart=always
RestartSec=3

NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadOnlyPaths=/opt/mtproto-proxy

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

LimitNOFILE=131582
TasksMax=65535

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
ok "Systemd сервис установлен"

# ── Firewall ────────────────────────────────────────────────
section "Файрвол"

if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
    ufw allow "${PROXY_PORT}/tcp" > /dev/null 2>&1
    ufw allow OpenSSH > /dev/null 2>&1
    ok "Открыты порты: ${PROXY_PORT}/tcp, SSH"
else
    info "ufw не активен — убедитесь, что порт ${PROXY_PORT} открыт"
fi

# ── TCPMSS=88 (passive DPI bypass) ──────────────────────────
section "TCPMSS=88 (пассивный DPI bypass)"

if command -v iptables &>/dev/null; then
    iptables -t mangle -D OUTPUT -p tcp --sport "$PROXY_PORT" --tcp-flags SYN,ACK SYN,ACK \
         -j TCPMSS --set-mss 88 2>/dev/null || true
    iptables -t mangle -A OUTPUT -p tcp --sport "$PROXY_PORT" --tcp-flags SYN,ACK SYN,ACK \
         -j TCPMSS --set-mss 88
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    ok "TCPMSS=88 → IPv4"
fi

if command -v ip6tables &>/dev/null; then
    ip6tables -t mangle -D OUTPUT -p tcp --sport "$PROXY_PORT" --tcp-flags SYN,ACK SYN,ACK \
         -j TCPMSS --set-mss 88 2>/dev/null || true
    if ip6tables -t mangle -A OUTPUT -p tcp --sport "$PROXY_PORT" --tcp-flags SYN,ACK SYN,ACK \
         -j TCPMSS --set-mss 88 2>/dev/null; then
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        ok "TCPMSS=88 → IPv6"
    else
        info "IPv6 TCPMSS пропущен (IPv6 отключён)"
    fi
fi

if ! dpkg -l iptables-persistent 2>/dev/null | grep -q "^ii"; then
    wait_for_apt
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections 2>/dev/null || true
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections 2>/dev/null || true
    apt-get install -y iptables-persistent 2>/dev/null || warn "iptables-persistent не установлен"
fi

# ── Zero-RTT masking (Nginx) ───────────────────────────────
section "Zero-RTT маскировка (Nginx)"

NGINX_OK=false

if ! command -v nginx &>/dev/null; then
    warn "Nginx не установлен — пробуем ещё раз..."
    wait_for_apt
    apt-get install -y nginx > /dev/null 2>&1 || true
fi

if command -v nginx &>/dev/null; then
    CERT_DIR="/etc/nginx/ssl"
    mkdir -p "$CERT_DIR" /var/www/masking /etc/nginx/sites-available /etc/nginx/sites-enabled

    info "Генерация self-signed сертификата для ${TLS_DOMAIN}..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${CERT_DIR}/key.pem" -out "${CERT_DIR}/cert.pem" \
        -days 3650 -nodes -subj "/CN=${TLS_DOMAIN}" 2>/dev/null
    ok "Сертификат создан"

    cat > /var/www/masking/index.html << 'HTMLEOF'
<html><head><title>Welcome</title></head><body><h1>It works!</h1></body></html>
HTMLEOF

    cat > /etc/nginx/sites-available/mtproto-masking << NGINXEOF
server {
    listen 127.0.0.1:${NGINX_PORT} ssl;
    server_name ${TLS_DOMAIN};
    ssl_certificate     ${CERT_DIR}/cert.pem;
    ssl_certificate_key ${CERT_DIR}/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    root /var/www/masking;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
    access_log off;
    error_log /var/log/nginx/masking-error.log warn;
}
NGINXEOF

    ln -sf /etc/nginx/sites-available/mtproto-masking /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default

    if nginx -t 2>&1; then
        systemctl enable nginx > /dev/null 2>&1
        systemctl restart nginx
        sleep 1
        if curl -sk "https://127.0.0.1:${NGINX_PORT}/" > /dev/null 2>&1; then
            ok "Nginx: 127.0.0.1:${NGINX_PORT} ✓"
            NGINX_OK=true
        else
            warn "Nginx может ещё не отвечать"
        fi
    else
        warn "Ошибка конфигурации Nginx"
    fi
else
    warn "Nginx недоступен — zero-RTT маскировка не настроена"
fi

# ── Zapret nfqws (TCP desync) ──────────────────────────────
section "Zapret nfqws (TCP desync)"

ZAPRET_DIR="/opt/zapret"
NFQWS_SERVICE="nfqws-mtproto"

if [[ -x "${ZAPRET_DIR}/nfq/nfqws" ]]; then
    ok "nfqws уже собран"
else
    info "Клонирование zapret..."
    rm -rf "$ZAPRET_DIR"
    if git clone --depth 1 https://github.com/bol-van/zapret.git "$ZAPRET_DIR" 2>&1; then
        info "Сборка nfqws..."
        cd "${ZAPRET_DIR}/nfq"
        make clean > /dev/null 2>&1 || true
        make > /dev/null 2>&1 || true
        [[ -x nfqws ]] && ok "nfqws собран" || warn "Сборка nfqws не удалась"
    else
        warn "Не удалось клонировать zapret"
    fi
fi

if [[ -x "${ZAPRET_DIR}/nfq/nfqws" ]]; then
    iptables  -t mangle -D OUTPUT -p tcp --sport "$PROXY_PORT" -j NFQUEUE --queue-num "$NFQUEUE_NUM" 2>/dev/null || true
    ip6tables -t mangle -D OUTPUT -p tcp --sport "$PROXY_PORT" -j NFQUEUE --queue-num "$NFQUEUE_NUM" 2>/dev/null || true
    iptables  -t mangle -A OUTPUT -p tcp --sport "$PROXY_PORT" -j NFQUEUE --queue-num "$NFQUEUE_NUM"
    ip6tables -t mangle -A OUTPUT -p tcp --sport "$PROXY_PORT" -j NFQUEUE --queue-num "$NFQUEUE_NUM" 2>/dev/null || true
    iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true

    cat > "/etc/systemd/system/${NFQWS_SERVICE}.service" << EOF
[Unit]
Description=nfqws TCP desync for MTProto proxy
After=network.target
Before=mtproto-proxy.service

[Service]
Type=simple
ExecStart=${ZAPRET_DIR}/nfq/nfqws \\
    --qnum=${NFQUEUE_NUM} \\
    --dpi-desync=fake,split2 \\
    --dpi-desync-ttl=${NFQWS_TTL} \\
    --dpi-desync-split-pos=1 \\
    --dpi-desync-fooling=md5sig
Restart=always
RestartSec=5
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$NFQWS_SERVICE" > /dev/null 2>&1
    systemctl restart "$NFQWS_SERVICE"
    sleep 1
    systemctl is-active --quiet "$NFQWS_SERVICE" && ok "nfqws запущен (TTL=${NFQWS_TTL})" || warn "nfqws не запустился"
fi

# ── IPv6 Hopping (Cloudflare) ──────────────────────────────
section "IPv6 hopping"

if [[ -n "${CF_TOKEN:-}" && -n "${CF_ZONE:-}" ]]; then
    info "Настройка авто-ротации IPv6..."
    [[ -f "$TMPBUILD/deploy/ipv6-hop.sh" ]] && cp "$TMPBUILD/deploy/ipv6-hop.sh" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/ipv6-hop.sh" 2>/dev/null || true

    cat > "$INSTALL_DIR/env.sh" << EOF
export CF_TOKEN="${CF_TOKEN}"
export CF_ZONE="${CF_ZONE}"
EOF
    chmod 600 "$INSTALL_DIR/env.sh"

    cat > /etc/cron.d/mtproto-ipv6 << EOF
*/5 * * * * root source ${INSTALL_DIR}/env.sh && ${INSTALL_DIR}/ipv6-hop.sh >> /var/log/mtproto-ipv6-hop.log 2>&1
EOF
    chmod 644 /etc/cron.d/mtproto-ipv6
    ok "IPv6 авто-ротация настроена (каждые 5 мин)"
else
    info "IPv6 hopping пропущен (CF_TOKEN / CF_ZONE не заданы)"
fi

# ── AmneziaWG Tunnel (blocked regions) ─────────────────────
TUNNEL_MODE=false

if [[ -n "${AWG_CONF:-}" ]]; then
    section "AmneziaWG Tunnel"

    [[ -f "$AWG_CONF" ]] || fail "AWG_CONF файл не найден: $AWG_CONF"

    info "Установка AmneziaWG..."
    if command -v awg &>/dev/null; then
        ok "AmneziaWG уже установлен"
    else
        apt-get install -y software-properties-common > /dev/null 2>&1 || true
        add-apt-repository -y ppa:amnezia/ppa 2>/dev/null || true
        apt-get update -qq 2>/dev/null || true
        apt-get install -y amneziawg-tools > /dev/null 2>&1 || fail "Не удалось установить amneziawg-tools"
        ok "AmneziaWG установлен"
    fi

    info "Настройка туннеля..."
    if [[ -f "$TMPBUILD/deploy/setup_tunnel.sh" ]]; then
        cp "$TMPBUILD/deploy/setup_tunnel.sh" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/setup_tunnel.sh"
    fi

    AWG_CONF_DIR="/etc/amnezia/amneziawg"
    mkdir -p "$AWG_CONF_DIR"
    cp "$AWG_CONF" "$AWG_CONF_DIR/awg0.conf"
    chmod 600 "$AWG_CONF_DIR/awg0.conf"

    NS_NAME="tg_proxy_ns"
    NETNS_SCRIPT="/usr/local/bin/setup_netns.sh"

    cat > "$NETNS_SCRIPT" << 'NETNS_EOF'
#!/bin/bash
set -e
NS_NAME="tg_proxy_ns"
MAIN_IF=$(ip route get 8.8.8.8 | awk '{printf $5}')

ip netns del $NS_NAME 2>/dev/null || true
ip link del veth_main 2>/dev/null || true

sysctl -w net.ipv4.ip_forward=1 >/dev/null
ip netns add $NS_NAME

mkdir -p /etc/netns/$NS_NAME
cat > /etc/netns/$NS_NAME/resolv.conf << EOF2
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF2

ip link add veth_main type veth peer name veth_ns
ip link set veth_ns netns $NS_NAME
ip addr add 10.200.200.1/24 dev veth_main
ip link set veth_main up

ip netns exec $NS_NAME ip addr add 10.200.200.2/24 dev veth_ns
ip netns exec $NS_NAME ip link set veth_ns up
ip netns exec $NS_NAME ip link set lo up
ip netns exec $NS_NAME ip route add default via 10.200.200.1

ip netns exec $NS_NAME awg-quick up /etc/amnezia/amneziawg/awg0.conf

ip netns exec $NS_NAME ip rule add from 10.200.200.2 table 100 priority 100
ip netns exec $NS_NAME ip route add default via 10.200.200.1 table 100

iptables -t nat -D PREROUTING -i $MAIN_IF -p tcp --dport 443 -j DNAT --to-destination 10.200.200.2:443 2>/dev/null || true
iptables -t nat -A PREROUTING -i $MAIN_IF -p tcp --dport 443 -j DNAT --to-destination 10.200.200.2:443
iptables -t nat -D POSTROUTING -s 10.200.200.0/24 -o $MAIN_IF -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -s 10.200.200.0/24 -o $MAIN_IF -j MASQUERADE
iptables -D FORWARD -i $MAIN_IF -o veth_main -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i $MAIN_IF -o veth_main -j ACCEPT
iptables -D FORWARD -i veth_main -o $MAIN_IF -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i veth_main -o $MAIN_IF -j ACCEPT
NETNS_EOF
    chmod +x "$NETNS_SCRIPT"
    ok "Скрипт namespace создан"

    # Switch config to direct mode (middleproxy needs per-IP registration)
    if grep -q 'use_middle_proxy\s*=\s*true' "$INSTALL_DIR/config.toml" 2>/dev/null; then
        sed -i 's/use_middle_proxy\s*=\s*true/use_middle_proxy = false/' "$INSTALL_DIR/config.toml"
        sed -i '/^\s*tag\s*=/d' "$INSTALL_DIR/config.toml"
        ok "Переключено в direct mode"
    fi

    # Patch systemd service for tunnel mode
    cat > /etc/systemd/system/${SERVICE_NAME}.service << 'SVC_EOF'
[Unit]
Description=MTProto Proxy (Zig) via AmneziaWG Tunnel
Documentation=https://github.com/sleep3r/mtproto.zig
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/local/bin/setup_netns.sh
ExecStart=/sbin/ip netns exec tg_proxy_ns /opt/mtproto-proxy/mtproto-proxy /opt/mtproto-proxy/config.toml
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_SYS_ADMIN
LimitNOFILE=131582
TasksMax=65535

[Install]
WantedBy=multi-user.target
SVC_EOF
    systemctl daemon-reload
    ok "Systemd сервис настроен для tunnel mode"
    TUNNEL_MODE=true
fi

# ── Start proxy ─────────────────────────────────────────────
section "Запуск MTProto proxy"

chown -R mtproto:mtproto "$INSTALL_DIR"
systemctl restart "$SERVICE_NAME"
sleep 3

# ── Health checks ───────────────────────────────────────────
section "Проверка здоровья"

HEALTH_OK=true

check_service() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        ok "$2 работает"
    else
        warn "$2 НЕ работает"
        HEALTH_OK=false
    fi
}

check_service "$SERVICE_NAME" "MTProto proxy"
command -v nginx &>/dev/null && check_service "nginx" "Nginx (zero-RTT)"
[[ -x "${ZAPRET_DIR}/nfq/nfqws" ]] && check_service "$NFQWS_SERVICE" "nfqws (TCP desync)"

if ss -tlnp | grep -q ":${PROXY_PORT} " 2>/dev/null; then
    ok "Порт ${PROXY_PORT} слушается"
else
    warn "Порт ${PROXY_PORT} не слушается!"
    HEALTH_OK=false
fi

iptables -t mangle -L OUTPUT -n 2>/dev/null | grep -q "TCPMSS.*88" && ok "TCPMSS=88 активен"

# Masking validation
MASK_PORT=$(awk '/^\s*\[censorship\]/{f=1;next} /^\s*\[/{f=0} f && /^\s*mask_port\s*=/{gsub(/[^0-9]/,"",$NF); print $NF}' \
    "$INSTALL_DIR/config.toml" 2>/dev/null)
if [[ -n "$MASK_PORT" ]] && curl -sk --max-time 3 "https://127.0.0.1:${MASK_PORT}/" > /dev/null 2>&1; then
    ok "Маскировка: 127.0.0.1:${MASK_PORT} отвечает"
fi

# Tunnel DC connectivity check
if $TUNNEL_MODE; then
    info "Проверка доступности Telegram DC через туннель..."
    DC_OK=true
    for dc_ip in 149.154.175.50 149.154.167.50 149.154.175.100 149.154.167.91 91.108.56.100; do
        if ip netns exec tg_proxy_ns nc -zw3 "$dc_ip" 443 2>/dev/null; then
            ok "DC $dc_ip доступен"
        else
            warn "DC $dc_ip НЕ доступен"
            DC_OK=false
            HEALTH_OK=false
        fi
    done
    $DC_OK && ok "Все Telegram DC доступны через AWG туннель" || warn "Некоторые DC недоступны — проверьте AWG конфиг"
fi

$HEALTH_OK && ok "Все проверки пройдены!" || warn "Есть проблемы — journalctl -u $SERVICE_NAME -f"

# ── Management script ───────────────────────────────────────
cat > "$INSTALL_DIR/manage.sh" << 'MANAGE_EOF'
#!/usr/bin/env bash
case "${1:-}" in
    status)
        systemctl status mtproto-proxy --no-pager 2>/dev/null; echo ""
        systemctl status nginx --no-pager 2>/dev/null; echo ""
        systemctl status nfqws-mtproto --no-pager 2>/dev/null
        ;;
    restart)
        systemctl restart nfqws-mtproto 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true
        systemctl restart mtproto-proxy
        echo "Все сервисы перезапущены"
        ;;
    logs)  journalctl -u mtproto-proxy -f ;;
    link)
        CONFIG="/opt/mtproto-proxy/config.toml"
        PORT=$(grep -oP '^\s*port\s*=\s*\K[0-9]+' "$CONFIG" 2>/dev/null || echo "443")
        DOMAIN=$(grep -oP 'tls_domain\s*=\s*"\K[^"]+' "$CONFIG" 2>/dev/null || echo "wb.ru")
        DOMAIN_HEX=$(echo -n "$DOMAIN" | xxd -p | tr -d '\n')
        PUBLIC_IP=$(curl -s --max-time 5 https://ifconfig.me || echo "<IP>")
        echo ""
        grep -oP '=\s*"\K[0-9a-f]{32}' "$CONFIG" | while read -r secret; do
            EE="ee${secret}${DOMAIN_HEX}"
            echo "  tg://proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${EE}"
            echo "  https://t.me/proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${EE}"
            echo ""
        done
        ;;
    add-user)
        SECRET=$(openssl rand -hex 16)
        NAME="${2:-user_$(date +%s)}"
        echo "${NAME} = \"${SECRET}\"" >> /opt/mtproto-proxy/config.toml
        systemctl restart mtproto-proxy
        echo "Добавлен: ${NAME} | Секрет: ${SECRET}"
        ;;
    update)
        echo "Обновление из GitHub Releases..."
        bash /opt/mtproto-proxy/update.sh "${2:-}"
        ;;
    tunnel)
        if [[ -z "${2:-}" ]]; then
            echo "Использование: mtproxy tunnel /path/to/awg.conf"
            echo "Настраивает AmneziaWG туннель для регионов с блокировкой Telegram."
            exit 1
        fi
        bash /opt/mtproto-proxy/setup_tunnel.sh "$2"
        ;;
    uninstall)
        echo "Удаление MTProto proxy..."
        systemctl stop mtproto-proxy nfqws-mtproto 2>/dev/null || true
        systemctl disable mtproto-proxy nfqws-mtproto 2>/dev/null || true
        rm -f /etc/systemd/system/mtproto-proxy.service /etc/systemd/system/nfqws-mtproto.service
        rm -f /etc/cron.d/mtproto-ipv6
        # Cleanup AmneziaWG tunnel
        ip netns exec tg_proxy_ns awg-quick down /etc/amnezia/amneziawg/awg0.conf 2>/dev/null || true
        ip netns del tg_proxy_ns 2>/dev/null || true
        ip link del veth_main 2>/dev/null || true
        rm -f /usr/local/bin/setup_netns.sh
        rm -rf /etc/amnezia/amneziawg 2>/dev/null || true
        rm -rf /etc/netns/tg_proxy_ns 2>/dev/null || true
        MAIN_IF=$(ip route get 8.8.8.8 2>/dev/null | awk '{printf $5}')
        iptables -t nat -D PREROUTING -i "$MAIN_IF" -p tcp --dport 443 -j DNAT --to-destination 10.200.200.2:443 2>/dev/null || true
        iptables -t nat -D POSTROUTING -s 10.200.200.0/24 -o "$MAIN_IF" -j MASQUERADE 2>/dev/null || true
        iptables -D FORWARD -i "$MAIN_IF" -o veth_main -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -i veth_main -o "$MAIN_IF" -j ACCEPT 2>/dev/null || true
        systemctl daemon-reload
        iptables -t mangle -D OUTPUT -p tcp --sport 443 --tcp-flags SYN,ACK SYN,ACK -j TCPMSS --set-mss 88 2>/dev/null || true
        iptables -t mangle -D OUTPUT -p tcp --sport 443 -j NFQUEUE --queue-num 200 2>/dev/null || true
        ip6tables -t mangle -D OUTPUT -p tcp --sport 443 --tcp-flags SYN,ACK SYN,ACK -j TCPMSS --set-mss 88 2>/dev/null || true
        ip6tables -t mangle -D OUTPUT -p tcp --sport 443 -j NFQUEUE --queue-num 200 2>/dev/null || true
        rm -rf /opt/mtproto-proxy /opt/zapret
        rm -f /etc/nginx/sites-enabled/mtproto-masking /etc/nginx/sites-available/mtproto-masking
        rm -f /usr/local/bin/mtproxy
        userdel mtproto 2>/dev/null || true
        echo "Удалено."
        ;;
    *)
        echo "mtproxy {status|restart|logs|link|add-user [имя]|update [vX.Y.Z]|tunnel <awg.conf>|uninstall}"
        ;;
esac
MANAGE_EOF
chmod +x "$INSTALL_DIR/manage.sh"
ln -sf "$INSTALL_DIR/manage.sh" /usr/local/bin/mtproxy

# ── Final output ────────────────────────────────────────────
PUBLIC_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
            curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "<IP>")
DOMAIN_HEX=$(echo -n "$TLS_DOMAIN" | xxd -p | tr -d '\n')

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║${RESET}${BOLD}   MTProto Proxy установлен!                              ${CYAN}║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e " ${BOLD}Ссылки для подключения:${RESET}"
echo ""
for i in "${!SECRETS[@]}"; do
    SECRET="${SECRETS[$i]}"
    EE_SECRET="ee${SECRET}${DOMAIN_HEX}"
    [[ ${#SECRETS[@]} -gt 1 ]] && echo -e " ${DIM}Пользователь $((i+1)):${RESET}"
    echo -e "   ${CYAN}tg://proxy?server=${PUBLIC_IP}&port=${PROXY_PORT}&secret=${GREEN}${EE_SECRET}${RESET}"
    echo -e "   ${DIM}https://t.me/proxy?server=${PUBLIC_IP}&port=${PROXY_PORT}&secret=${EE_SECRET}${RESET}"
    echo ""
done

echo -e " ${BOLD}DPI bypass:${RESET}"
echo -e "   ${GREEN}✓${RESET} Anti-Replay Cache (ТСПУ Ревизор)"
echo -e "   ${GREEN}✓${RESET} TCPMSS=88 (фрагментация ClientHello)"
echo -e "   ${GREEN}✓${RESET} Split-TLS (1-байт chunking)"
if $NGINX_OK; then
    echo -e "   ${GREEN}✓${RESET} Zero-RTT Nginx (127.0.0.1:${NGINX_PORT})"
else
    echo -e "   ${DIM}○ Zero-RTT Nginx (не настроен)${RESET}"
fi
if systemctl is-active --quiet "$NFQWS_SERVICE" 2>/dev/null; then
    echo -e "   ${GREEN}✓${RESET} TCP Desync nfqws (Zapret, TTL=${NFQWS_TTL})"
else
    echo -e "   ${DIM}○ TCP Desync nfqws (не запущен)${RESET}"
fi
if [[ -f /etc/cron.d/mtproto-ipv6 ]]; then
    echo -e "   ${GREEN}✓${RESET} IPv6 авто-ротация (каждые 5 мин)"
else
    echo -e "   ${DIM}○ IPv6 hopping (задайте CF_TOKEN + CF_ZONE)${RESET}"
fi
if $TUNNEL_MODE; then
    echo ""
    echo -e " ${BOLD}AmneziaWG Tunnel:${RESET}"
    echo -e "   ${GREEN}✓${RESET} Прокси работает в изолированном network namespace"
    echo -e "   ${GREEN}✓${RESET} AWG туннель активен (host-сеть не затронута)"
    echo -e "   ${GREEN}✓${RESET} Direct mode (регистрация middleproxy не нужна)"
    echo -e "   ${GREEN}✓${RESET} SSH и остальные сервисы не затронуты"
    echo ""
    echo -e "   ${DIM}Туннель:${RESET} ip netns exec tg_proxy_ns awg show"
fi

echo ""
echo -e " ${BOLD}Управление:${RESET}"
echo -e "   ${DIM}mtproxy status${RESET}             — статус сервисов"
echo -e "   ${DIM}mtproxy restart${RESET}            — перезапуск"
echo -e "   ${DIM}mtproxy logs${RESET}               — логи"
echo -e "   ${DIM}mtproxy link${RESET}               — ссылки подключения"
echo -e "   ${DIM}mtproxy add-user имя${RESET}       — добавить пользователя"
echo -e "   ${DIM}mtproxy update${RESET}             — обновить из GitHub Releases"
echo -e "   ${DIM}mtproxy update v0.7.0${RESET}      — конкретная версия"
echo -e "   ${DIM}mtproxy tunnel awg.conf${RESET}    — AWG туннель (заблокированные регионы)"
echo -e "   ${DIM}mtproxy uninstall${RESET}          — удаление"
echo ""
echo -e " ${BOLD}Конфиг:${RESET}  ${DIM}${INSTALL_DIR}/config.toml${RESET}"
echo -e " ${BOLD}Логи:${RESET}    ${DIM}journalctl -u ${SERVICE_NAME} -f${RESET}"
echo ""
