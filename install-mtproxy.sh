#!/usr/bin/env bash
#
# MTProto Proxy — полный автоматический установщик для чистого VPS
# Репозиторий: https://github.com/sleep3r/mtproto.zig
#
# Использование:
#   curl -sSfL https://raw.githubusercontent.com/<you>/mtproxy-zig/main/install-mtproxy.sh | sudo bash
#
#   Или с параметрами Cloudflare (IPv6 hopping):
#   curl -sSfL ... | sudo CF_TOKEN=xxx CF_ZONE=yyy bash
#
#   Или интерактивно на сервере:
#   chmod +x install-mtproxy.sh && sudo ./install-mtproxy.sh
#
# Что делает скрипт:
#   1.  Обновляет систему и устанавливает все зависимости
#   2.  Устанавливает Zig 0.15.2
#   3.  Клонирует и собирает mtproto.zig (ReleaseFast)
#   4.  Генерирует конфиг с рандомным секретом
#   5.  Создаёт systemd-сервис с hardening
#   6.  Настраивает файрвол (ufw / iptables)
#   7.  Применяет TCPMSS=88 (пассивный DPI bypass)
#   8.  Ставит локальный Nginx для zero-RTT маскировки
#   9.  Собирает и ставит zapret nfqws (TCP desync)
#   10. Настраивает IPv6 hopping (если переданы CF_TOKEN + CF_ZONE)
#   11. Проверяет здоровье всех компонентов
#   12. Выводит готовую ссылку tg://proxy
#
# Поддерживаемые ОС: Ubuntu 20.04+, Debian 11+
# Архитектуры: x86_64, aarch64

set -euo pipefail

# ── Конфигурация ────────────────────────────────────────────
ZIG_VERSION="0.15.2"
INSTALL_DIR="/opt/mtproto-proxy"
REPO_URL="https://github.com/sleep3r/mtproto.zig.git"
SERVICE_NAME="mtproto-proxy"
PROXY_PORT="${PROXY_PORT:-443}"
TLS_DOMAIN="${TLS_DOMAIN:-wb.ru}"
NUM_USERS="${NUM_USERS:-1}"
NFQUEUE_NUM=200
NFQWS_TTL="${NFQWS_TTL:-6}"

# ── Цвета ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Логирование ─────────────────────────────────────────────
LOG_FILE="/var/log/mtproto-install.log"
touch "$LOG_FILE"

log_to_file() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}
trap 'log_to_file "Script exited with code $?"' EXIT

info()    { echo -e "${CYAN}▸${RESET} $*"; }
ok()      { echo -e "${GREEN}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET} $*"; }
fail()    { echo -e "${RED}✗${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }

# ── Баннер ──────────────────────────────────────────────────
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
echo -e "${DIM}Полная автоматическая установка MTProto proxy${RESET}"
echo -e "${DIM}$(date '+%Y-%m-%d %H:%M:%S') | Лог: ${LOG_FILE}${RESET}"
echo ""

# ── Предварительные проверки ────────────────────────────────
section "Предварительные проверки"

[[ $EUID -eq 0 ]] || fail "Запустите от root: sudo bash $0"

if [[ ! -f /etc/debian_version ]] && [[ ! -f /etc/lsb-release ]]; then
    warn "Скрипт тестировался на Ubuntu/Debian. На другой ОС возможны проблемы."
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
if [[ $TOTAL_RAM_MB -lt 256 ]]; then
    warn "Мало RAM (<256 MB). Сборка может занять больше времени."
fi

CORES=$(nproc)
ok "CPU: ${CORES} ядер"

# ── Обновление системы и зависимости ────────────────────────
section "Установка системных зависимостей"

export DEBIAN_FRONTEND=noninteractive

# Агрессивная очистка apt/dpkg lock-ов на свежем VPS
info "Подготовка пакетного менеджера..."

# 1. Убить все автоматические apt-процессы
systemctl stop unattended-upgrades.service 2>/dev/null || true
systemctl disable unattended-upgrades.service 2>/dev/null || true
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

pkill -9 -f unattended-upgr 2>/dev/null || true
pkill -9 -f 'apt\.(get|daily)' 2>/dev/null || true
pkill -9 -f dpkg 2>/dev/null || true
sleep 2

# 2. Снять все lock-файлы
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
      /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true

# 3. Принудительно удалить сломанные пакеты ядра (они блокируют весь dpkg)
CURRENT_KERNEL=$(uname -r)
BROKEN_PKGS=$(dpkg -l 'linux-image-*' 'linux-modules-*' 'linux-firmware' 'initramfs-tools' 2>/dev/null | \
    awk '/^(iF|iU|iW|iHR)/{print $2}' | grep -v "$CURRENT_KERNEL" || true)

if [[ -n "$BROKEN_PKGS" ]]; then
    info "Удаляем сломанные пакеты ядра, блокирующие dpkg..."
    for pkg in $BROKEN_PKGS; do
        info "  → $pkg"
        dpkg --remove --force-remove-reinstreq "$pkg" 2>/dev/null || true
    done
    rm -f /boot/initrd.img-*.old 2>/dev/null || true
    ok "Сломанные пакеты удалены"
fi

# 4. Починить dpkg
dpkg --configure -a --force-confdef --force-confold 2>&1 | tail -3 || true
apt-get -f install -y 2>&1 | tail -3 || true
ok "Пакетный менеджер готов"

# Функция починки для повторного использования
fix_dpkg() {
    pkill -9 -f apt 2>/dev/null || true
    pkill -9 -f dpkg 2>/dev/null || true
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null || true
    # Удалить сломанные пакеты ядра если они мешают
    local broken
    broken=$(dpkg -l 2>/dev/null | awk '/^(iF|iU|iW)/{print $2}' | grep -E 'linux-|initramfs|firmware' || true)
    for pkg in $broken; do
        dpkg --remove --force-remove-reinstreq "$pkg" 2>/dev/null || true
    done
    dpkg --configure -a --force-confdef --force-confold 2>&1 | tail -3 || true
    apt-get -f install -y 2>&1 | tail -3 || true
}

# Функция ожидания для повторного использования
wait_for_apt() {
    local i=0
    while [[ -f /var/lib/dpkg/lock-frontend ]] && lsof /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; do
        [[ $i -eq 0 ]] && info "Ожидание apt..."
        sleep 3
        i=$((i + 3))
        if [[ $i -ge 60 ]]; then
            pkill -9 -f apt 2>/dev/null || true
            pkill -9 -f dpkg 2>/dev/null || true
            rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null || true
            break
        fi
    done
}

info "Обновление пакетных списков..."
apt-get update -qq 2>&1 | tail -1 || true

info "Установка пакетов (это может занять пару минут)..."

# Сначала базовые пакеты без nginx (чтобы nginx не ломал остальное)
BASE_PACKAGES=(git curl wget openssl jq build-essential iptables
    libnetfilter-queue-dev libcap-dev libmnl-dev zlib1g-dev)

if ! apt-get install -y "${BASE_PACKAGES[@]}" 2>&1 | tail -5; then
    warn "Ошибка при массовой установке — пробуем починить dpkg и повторить..."
    fix_dpkg
    apt-get install -y "${BASE_PACKAGES[@]}" 2>&1 | tail -3 || true
fi

# Nginx отдельно — чтобы его сбой не блокировал всё остальное
info "Установка nginx..."

# Отключить IPv6 в дефолтном конфиге ДО установки/конфигурирования
mkdir -p /etc/nginx/conf.d
# Превентивно создать дефолт без IPv6 listen
mkdir -p /etc/nginx/sites-available
if [[ -f /etc/nginx/sites-available/default ]]; then
    sed -i 's/listen \[::\]:80/# listen [::]:80/' /etc/nginx/sites-available/default 2>/dev/null || true
fi

# Временно замаскировать nginx чтобы dpkg не пытался его стартовать при установке
systemctl mask nginx.service 2>/dev/null || true
apt-get install -y nginx 2>&1 | tail -3 || true
systemctl unmask nginx.service 2>/dev/null || true

# Теперь пофиксить конфиг nginx: убрать IPv6 listen если IPv6 недоступен
if ! cat /proc/net/if_inet6 &>/dev/null || [[ ! -s /proc/net/if_inet6 ]]; then
    info "IPv6 отключён на сервере — патчим конфиг nginx..."
    find /etc/nginx -name '*.conf' -o -name 'default' 2>/dev/null | while read -r f; do
        sed -i 's/listen \[::\]:80/# listen [::]:80/' "$f" 2>/dev/null || true
        sed -i 's/listen \[::\]:443/# listen [::]:443/' "$f" 2>/dev/null || true
    done
    if [[ -f /etc/nginx/sites-enabled/default ]]; then
        sed -i 's/listen \[::\]:80/# listen [::]:80/' /etc/nginx/sites-enabled/default 2>/dev/null || true
    fi
fi

# certbot опционален
apt-get install -y certbot python3-certbot-nginx 2>/dev/null || warn "certbot не установлен — не критично"

# xxd может быть частью vim-common или отдельным пакетом
if ! command -v xxd &>/dev/null; then
    apt-get install -y xxd 2>/dev/null || apt-get install -y vim-common 2>/dev/null || true
fi

# Критические зависимости — без них продолжать нельзя
for cmd in git curl openssl; do
    command -v "$cmd" &>/dev/null || fail "Критическая зависимость не установлена: $cmd"
done
command -v xxd &>/dev/null || fail "xxd не удалось установить (нужен для генерации ссылки)"

ok "Все зависимости установлены"

# ── Установка Zig ───────────────────────────────────────────
section "Установка Zig ${ZIG_VERSION}"

if command -v zig &>/dev/null && zig version 2>/dev/null | grep -q "$ZIG_VERSION"; then
    ok "Zig $ZIG_VERSION уже установлен"
else
    info "Скачивание Zig ${ZIG_VERSION} (${ZIG_ARCH})..."
    ZIG_TAR="zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz"
    ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TAR}"

    cd /tmp
    curl -sSfL -o "$ZIG_TAR" "$ZIG_URL" || fail "Не удалось скачать Zig"
    info "Распаковка..."
    tar xf "$ZIG_TAR"
    rm -rf /usr/local/zig
    mv "zig-${ZIG_ARCH}-linux-${ZIG_VERSION}" /usr/local/zig
    ln -sf /usr/local/zig/zig /usr/local/bin/zig
    rm -f "$ZIG_TAR"
    ok "Zig $ZIG_VERSION установлен → $(zig version)"
fi

# ── Клонирование и сборка ───────────────────────────────────
section "Сборка MTProto proxy"

TMPBUILD=$(mktemp -d)
cleanup() { rm -rf "$TMPBUILD"; log_to_file "Cleanup done, temp dir removed"; }
trap cleanup EXIT

info "Клонирование репозитория..."
git clone --depth 1 "$REPO_URL" "$TMPBUILD" || fail "Не удалось клонировать репозиторий"
cd "$TMPBUILD"

info "Сборка (ReleaseFast)... Это может занять 1-3 минуты."
BUILD_START=$(date +%s)
zig build -Doptimize=ReleaseFast 2>&1 || fail "Сборка не удалась"
BUILD_END=$(date +%s)
BUILD_TIME=$((BUILD_END - BUILD_START))

BINARY_SIZE=$(stat -c%s zig-out/bin/mtproto-proxy 2>/dev/null || echo "0")
BINARY_SIZE_KB=$((BINARY_SIZE / 1024))
ok "Сборка завершена за ${BUILD_TIME}с | Бинарник: ${BINARY_SIZE_KB} KB"

# ── Установка бинарника ─────────────────────────────────────
section "Установка"

mkdir -p "$INSTALL_DIR"

if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    info "Остановка существующего сервиса..."
    systemctl stop "$SERVICE_NAME"
fi

cp zig-out/bin/mtproto-proxy "$INSTALL_DIR/mtproto-proxy"
chmod +x "$INSTALL_DIR/mtproto-proxy"
ok "Бинарник установлен → $INSTALL_DIR/mtproto-proxy"

# ── Генерация конфигурации ──────────────────────────────────
section "Конфигурация"

generate_secret() {
    openssl rand -hex 16
}

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
[server]
port = ${PROXY_PORT}
# tag = "1234567890abcdef1234567890abcdef"  # промо-тег от @MTProxybot

[censorship]
tls_domain = "${TLS_DOMAIN}"
mask = true
mask_port = 8443
desync = true
fast_mode = true

[access.users]
${USERS_BLOCK}
EOF
    ok "Конфигурация создана: $INSTALL_DIR/config.toml"
else
    ok "Конфигурация уже существует, сохраняем"
    SECRETS=()
    while IFS= read -r s; do
        SECRETS+=("$s")
    done < <(grep -oP '=\s*"\K[0-9a-f]{32}' "$INSTALL_DIR/config.toml" || true)
fi

# Прочитать актуальные значения из конфига
TLS_DOMAIN=$(grep -oP 'tls_domain\s*=\s*"\K[^"]+' "$INSTALL_DIR/config.toml" 2>/dev/null || echo "$TLS_DOMAIN")
PROXY_PORT=$(grep -oP '^\s*port\s*=\s*\K[0-9]+' "$INSTALL_DIR/config.toml" 2>/dev/null || echo "$PROXY_PORT")

# ── Создание системного пользователя ────────────────────────
if ! id -u mtproto &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin mtproto
    ok "Создан системный пользователь 'mtproto'"
fi
chown -R mtproto:mtproto "$INSTALL_DIR"

# ── Systemd сервис ──────────────────────────────────────────
section "Systemd сервис"

cat > /etc/systemd/system/${SERVICE_NAME}.service << 'EOF'
[Unit]
Description=MTProto Proxy (Zig)
Documentation=https://github.com/sleep3r/mtproto.zig
After=network-online.target nfqws-mtproto.service nginx.service
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

LimitNOFILE=65535
TasksMax=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
ok "Systemd сервис установлен"

# ── Файрвол ─────────────────────────────────────────────────
section "Файрвол"

if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
    ufw allow "${PROXY_PORT}/tcp" > /dev/null 2>&1
    ufw allow OpenSSH > /dev/null 2>&1
    ok "Открыты порты: ${PROXY_PORT}/tcp, SSH (ufw)"
else
    info "ufw не активен — убедитесь, что порт ${PROXY_PORT} открыт"
fi

# ── TCPMSS clamping (пассивный DPI bypass) ──────────────────
section "TCPMSS=88 (пассивный DPI bypass)"

apply_tcpmss() {
    local cmd="$1"
    $cmd -t mangle -D OUTPUT -p tcp --sport "$PROXY_PORT" --tcp-flags SYN,ACK SYN,ACK \
         -j TCPMSS --set-mss 88 2>/dev/null || true
    $cmd -t mangle -A OUTPUT -p tcp --sport "$PROXY_PORT" --tcp-flags SYN,ACK SYN,ACK \
         -j TCPMSS --set-mss 88
}

if command -v iptables &>/dev/null; then
    apply_tcpmss iptables
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    ok "TCPMSS=88 → IPv4"
fi

if command -v ip6tables &>/dev/null; then
    apply_tcpmss ip6tables
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    ok "TCPMSS=88 → IPv6"
fi

# ── Сохранение правил iptables при перезагрузке ─────────────
if ! dpkg -l iptables-persistent 2>/dev/null | grep -q "^ii"; then
    wait_for_apt
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections 2>/dev/null || true
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections 2>/dev/null || true
    if apt-get install -y iptables-persistent 2>/dev/null; then
        ok "iptables-persistent установлен (правила сохранятся после ребута)"
    else
        warn "iptables-persistent не удалось установить — правила могут не пережить ребут"
    fi
fi

# ── Локальный Nginx (zero-RTT маскировка) ───────────────────
section "Zero-RTT маскировка (Nginx)"

NGINX_PORT=8443
NGINX_OK=false

if ! command -v nginx &>/dev/null; then
    warn "Nginx не установлен — пробуем ещё раз..."
    wait_for_apt
    apt-get install -y nginx 2>&1 | tail -3 || true
fi

if command -v nginx &>/dev/null; then
    CERT_DIR="/etc/nginx/ssl"
    mkdir -p "$CERT_DIR"

    info "Генерация self-signed сертификата для ${TLS_DOMAIN}..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${CERT_DIR}/key.pem" \
        -out "${CERT_DIR}/cert.pem" \
        -days 3650 -nodes \
        -subj "/CN=${TLS_DOMAIN}" \
        2>/dev/null
    ok "Сертификат создан"

    mkdir -p /var/www/masking
    cat > /var/www/masking/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html><head><title>Welcome</title></head>
<body><h1>It works!</h1></body></html>
HTMLEOF

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

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

    location / {
        try_files \$uri \$uri/ =404;
    }

    access_log off;
    error_log /var/log/nginx/masking-error.log warn;
}
NGINXEOF

    ln -sf /etc/nginx/sites-available/mtproto-masking /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default

    # Патч: отключить IPv6 listen во всех конфигах nginx если IPv6 недоступен
    if ! cat /proc/net/if_inet6 &>/dev/null || [[ ! -s /proc/net/if_inet6 ]]; then
        find /etc/nginx -type f \( -name '*.conf' -o -name 'default' \) 2>/dev/null | while read -r f; do
            sed -i 's/^\(\s*\)listen \[::\]/\1# listen [::]/' "$f" 2>/dev/null || true
        done
    fi

    if nginx -t 2>&1; then
        systemctl enable nginx > /dev/null 2>&1
        systemctl restart nginx
        sleep 1
        if curl -sk "https://127.0.0.1:${NGINX_PORT}/" > /dev/null 2>&1; then
            ok "Nginx работает на 127.0.0.1:${NGINX_PORT}"
            NGINX_OK=true
        else
            warn "Nginx может ещё не отвечать"
        fi
    else
        warn "Ошибка конфигурации Nginx — проверьте: nginx -t"
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
    if ! git clone --depth 1 https://github.com/bol-van/zapret.git "$ZAPRET_DIR"; then
        warn "Не удалось клонировать zapret — пропускаем TCP desync"
    fi

    if [[ -d "${ZAPRET_DIR}/nfq" ]]; then
        info "Сборка nfqws..."
        cd "${ZAPRET_DIR}/nfq"
        make clean > /dev/null 2>&1 || true
        make 2>&1 | tail -3 || true
    fi

    if [[ -x nfqws ]]; then
        ok "nfqws собран"
    else
        warn "Сборка nfqws не удалась — пропускаем TCP desync"
    fi
fi

if [[ -x "${ZAPRET_DIR}/nfq/nfqws" ]]; then
    # Правила NFQUEUE
    iptables  -t mangle -D OUTPUT -p tcp --sport "$PROXY_PORT" -j NFQUEUE --queue-num "$NFQUEUE_NUM" 2>/dev/null || true
    ip6tables -t mangle -D OUTPUT -p tcp --sport "$PROXY_PORT" -j NFQUEUE --queue-num "$NFQUEUE_NUM" 2>/dev/null || true
    iptables  -t mangle -A OUTPUT -p tcp --sport "$PROXY_PORT" -j NFQUEUE --queue-num "$NFQUEUE_NUM"
    ip6tables -t mangle -A OUTPUT -p tcp --sport "$PROXY_PORT" -j NFQUEUE --queue-num "$NFQUEUE_NUM"
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

    if systemctl is-active --quiet "$NFQWS_SERVICE"; then
        ok "nfqws запущен (TTL=${NFQWS_TTL}, NFQUEUE=${NFQUEUE_NUM})"
    else
        warn "nfqws не удалось запустить"
    fi
fi

# ── IPv6 Hopping (Cloudflare) ──────────────────────────────
section "IPv6 hopping"

if [[ -n "${CF_TOKEN:-}" && -n "${CF_ZONE:-}" ]]; then
    info "Настройка авто-ротации IPv6..."

    if [[ -f "$TMPBUILD/deploy/ipv6-hop.sh" ]]; then
        cp "$TMPBUILD/deploy/ipv6-hop.sh" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/ipv6-hop.sh"
    fi

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
    info "Пропуск IPv6 hopping (CF_TOKEN и CF_ZONE не заданы)"
    echo -e "  ${DIM}Для включения: sudo CF_TOKEN=xxx CF_ZONE=yyy bash install-mtproxy.sh${RESET}"
fi

# ── Запуск прокси ───────────────────────────────────────────
section "Запуск MTProto proxy"

systemctl restart "$SERVICE_NAME"
sleep 2

# ── Проверка здоровья ───────────────────────────────────────
section "Проверка здоровья"

HEALTH_OK=true

check_service() {
    local svc="$1"
    local label="$2"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        ok "$label работает"
    else
        warn "$label НЕ работает"
        HEALTH_OK=false
    fi
}

check_service "$SERVICE_NAME" "MTProto proxy"
check_service "nginx" "Nginx (zero-RTT)"
if [[ -x "${ZAPRET_DIR}/nfq/nfqws" ]]; then
    check_service "$NFQWS_SERVICE" "nfqws (TCP desync)"
fi

# Проверка порта
if ss -tlnp | grep -q ":${PROXY_PORT} " 2>/dev/null; then
    ok "Порт ${PROXY_PORT} слушается"
else
    warn "Порт ${PROXY_PORT} не прослушивается!"
    HEALTH_OK=false
fi

# Проверка iptables TCPMSS
if iptables -t mangle -L OUTPUT -n 2>/dev/null | grep -q "TCPMSS.*88"; then
    ok "TCPMSS=88 активен"
fi

if $HEALTH_OK; then
    ok "Все проверки пройдены!"
else
    warn "Есть проблемы — проверьте логи: journalctl -u $SERVICE_NAME -f"
fi

# ── Скрипт управления ──────────────────────────────────────
cat > "$INSTALL_DIR/manage.sh" << 'MANAGE_EOF'
#!/usr/bin/env bash
# Управление MTProto proxy
case "${1:-}" in
    status)
        echo "=== MTProto Proxy ==="
        systemctl status mtproto-proxy --no-pager 2>/dev/null || echo "не установлен"
        echo ""
        echo "=== Nginx (masking) ==="
        systemctl status nginx --no-pager 2>/dev/null || echo "не установлен"
        echo ""
        echo "=== nfqws (desync) ==="
        systemctl status nfqws-mtproto --no-pager 2>/dev/null || echo "не установлен"
        ;;
    restart)
        systemctl restart nfqws-mtproto 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true
        systemctl restart mtproto-proxy
        echo "Все сервисы перезапущены"
        ;;
    logs)
        journalctl -u mtproto-proxy -f
        ;;
    link)
        CONFIG="/opt/mtproto-proxy/config.toml"
        PORT=$(grep -oP '^\s*port\s*=\s*\K[0-9]+' "$CONFIG" 2>/dev/null || echo "443")
        DOMAIN=$(grep -oP 'tls_domain\s*=\s*"\K[^"]+' "$CONFIG" 2>/dev/null || echo "wb.ru")
        DOMAIN_HEX=$(echo -n "$DOMAIN" | xxd -p | tr -d '\n')
        PUBLIC_IP=$(curl -s --max-time 5 https://ifconfig.me || echo "<IP>")
        echo ""
        echo "Ссылки подключения:"
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
        echo "Добавлен пользователь: ${NAME}"
        echo "Секрет: ${SECRET}"
        ;;
    uninstall)
        echo "Удаление MTProto proxy..."
        systemctl stop mtproto-proxy 2>/dev/null || true
        systemctl disable mtproto-proxy 2>/dev/null || true
        systemctl stop nfqws-mtproto 2>/dev/null || true
        systemctl disable nfqws-mtproto 2>/dev/null || true
        rm -f /etc/systemd/system/mtproto-proxy.service
        rm -f /etc/systemd/system/nfqws-mtproto.service
        rm -f /etc/cron.d/mtproto-ipv6
        systemctl daemon-reload
        iptables -t mangle -D OUTPUT -p tcp --sport 443 --tcp-flags SYN,ACK SYN,ACK -j TCPMSS --set-mss 88 2>/dev/null || true
        iptables -t mangle -D OUTPUT -p tcp --sport 443 -j NFQUEUE --queue-num 200 2>/dev/null || true
        ip6tables -t mangle -D OUTPUT -p tcp --sport 443 --tcp-flags SYN,ACK SYN,ACK -j TCPMSS --set-mss 88 2>/dev/null || true
        ip6tables -t mangle -D OUTPUT -p tcp --sport 443 -j NFQUEUE --queue-num 200 2>/dev/null || true
        rm -rf /opt/mtproto-proxy
        rm -rf /opt/zapret
        rm -f /etc/nginx/sites-enabled/mtproto-masking
        rm -f /etc/nginx/sites-available/mtproto-masking
        userdel mtproto 2>/dev/null || true
        echo "Удалено."
        ;;
    *)
        echo "Использование: $0 {status|restart|logs|link|add-user [имя]|uninstall}"
        ;;
esac
MANAGE_EOF
chmod +x "$INSTALL_DIR/manage.sh"
ln -sf "$INSTALL_DIR/manage.sh" /usr/local/bin/mtproxy

# ── Финальный вывод ─────────────────────────────────────────
PUBLIC_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
            curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
            echo "<ВАШ_IP>")
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
    if [[ ${#SECRETS[@]} -gt 1 ]]; then
        echo -e " ${DIM}Пользователь $((i+1)):${RESET}"
    fi
    echo -e "   ${CYAN}tg://proxy?server=${PUBLIC_IP}&port=${PROXY_PORT}&secret=${GREEN}${EE_SECRET}${RESET}"
    echo -e "   ${DIM}https://t.me/proxy?server=${PUBLIC_IP}&port=${PROXY_PORT}&secret=${EE_SECRET}${RESET}"
    echo ""
done

echo -e " ${BOLD}Активные обходы DPI:${RESET}"
echo -e "   ${GREEN}✓${RESET} Anti-Replay Cache (защита от ТСПУ Ревизор)"
echo -e "   ${GREEN}✓${RESET} TCPMSS=88 (фрагментация ClientHello)"
echo -e "   ${GREEN}✓${RESET} Split-TLS (1-байт TLS Record chunking)"
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

echo ""
echo -e " ${BOLD}Управление:${RESET}"
echo -e "   ${DIM}mtproxy status${RESET}          — статус всех сервисов"
echo -e "   ${DIM}mtproxy restart${RESET}         — перезапуск"
echo -e "   ${DIM}mtproxy logs${RESET}            — логи в реальном времени"
echo -e "   ${DIM}mtproxy link${RESET}            — показать ссылки подключения"
echo -e "   ${DIM}mtproxy add-user имя${RESET}    — добавить пользователя"
echo -e "   ${DIM}mtproxy uninstall${RESET}       — полное удаление"
echo ""
echo -e " ${BOLD}Конфиг:${RESET}  ${DIM}${INSTALL_DIR}/config.toml${RESET}"
echo -e " ${BOLD}Логи:${RESET}    ${DIM}journalctl -u ${SERVICE_NAME} -f${RESET}"
echo -e " ${BOLD}Лог установки:${RESET} ${DIM}${LOG_FILE}${RESET}"
echo ""
