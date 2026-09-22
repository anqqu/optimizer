#!/bin/bash
# =============================================================================
#  ⚡ VPS Network Optimizer v2.2
#  Автор: anqqu | https://github.com/anqqu/optimizer
#  ОС: Debian 11/12, Ubuntu 22.04/24.04 LTS | Виртуализация: KVM
# =============================================================================

# ЗАЩИТА ОТ curl | bash: если stdin не терминал — скачиваем себя и перезапускаем
if [[ ! -t 0 ]]; then
    _SELF_TMP=$(mktemp /tmp/optimizer-XXXXXX.sh)
    curl -fsSL "https://raw.githubusercontent.com/anqqu/optimizer/main/optimizer.sh" \
         -o "$_SELF_TMP" 2>/dev/null || { echo "Ошибка загрузки"; exit 1; }
    chmod +x "$_SELF_TMP"
    exec bash "$_SELF_TMP" "$@" < /dev/tty
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✅ $*${RESET}"; }
err()  { echo -e "  ${RED}❌ $*${RESET}"; }
warn() { echo -e "  ${YELLOW}⚠️  $*${RESET}"; }
info() { echo -e "  ${BLUE}ℹ️  $*${RESET}"; }
sep()  { echo -e "  ${CYAN}────────────────────────────────────────────${RESET}"; }

check_root() {
    [[ $EUID -ne 0 ]] && { err "Запусти от root: sudo bash optimizer.sh"; exit 1; }
}

check_os() {
    [[ ! -f /etc/os-release ]] && { warn "ОС не определена, продолжаем..."; return; }
    source /etc/os-release
    if [[ "$ID" != "debian" && "$ID" != "ubuntu" && "$ID_LIKE" != *"debian"* ]]; then
        warn "Неподдерживаемая ОС: $PRETTY_NAME"
        read -rp "  Продолжить? [y/N]: " c; [[ "$c" =~ ^[Yy]$ ]] || exit 0
    fi
}

fn_update() {
    sep; echo -e "${BOLD}📦 Обновление пакетов${RESET}"; sep
    export DEBIAN_FRONTEND=noninteractive
    APT_OPTS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -o Acquire::Retries=3)
    OS_ID=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    if [[ "$OS_ID" == "ubuntu" ]]; then
        MIRRORS=("http://archive.ubuntu.com/ubuntu" "http://de.archive.ubuntu.com/ubuntu"
                 "http://ru.archive.ubuntu.com/ubuntu" "http://mirror.yandex.ru/ubuntu"
                 "http://fr.archive.ubuntu.com/ubuntu" "http://mirrors.aliyun.com/ubuntu")
    else
        MIRRORS=("http://deb.debian.org/debian" "http://ftp.de.debian.org/debian"
                 "http://ftp.ru.debian.org/debian" "http://mirror.yandex.ru/debian"
                 "http://ftp.fr.debian.org/debian" "http://mirrors.aliyun.com/debian")
    fi
    SOURCES_FILE="/etc/apt/sources.list"
    CURRENT_MIRROR=$(grep -m1 '^deb http' "$SOURCES_FILE" 2>/dev/null | awk '{print $2}' | sed 's|/[^/]*$||' | head -n1)
    info "Текущее зеркало: ${CURRENT_MIRROR:-неизвестно}"
    MIRROR_OK=false
    if [[ -n "$CURRENT_MIRROR" ]] && curl -fsI --connect-timeout 5 "$CURRENT_MIRROR" > /dev/null 2>&1; then
        MIRROR_OK=true; ok "Зеркало доступно: $CURRENT_MIRROR"
    else
        warn "Основное зеркало недоступно. Ищем рабочее..."
        for mirror in "${MIRRORS[@]}"; do
            info "→ проверяем $mirror"
            if curl -fsI --connect-timeout 5 "$mirror" > /dev/null 2>&1; then
                ok "Найдено: $mirror"
                cp "$SOURCES_FILE" "${SOURCES_FILE}.bak.$(date +%Y%m%d%H%M%S)"
                if [[ -n "$CURRENT_MIRROR" ]]; then
                    OLD_ESC=$(echo "$CURRENT_MIRROR" | sed 's|/|\\/|g')
                    NEW_ESC=$(echo "$mirror" | sed 's|/|\\/|g')
                    sed -i "s|${OLD_ESC}|${NEW_ESC}|g" "$SOURCES_FILE"
                    ok "sources.list обновлён"
                fi
                MIRROR_OK=true; break
            fi
        done
    fi
    [[ "$MIRROR_OK" == false ]] && warn "Нет доступных зеркал, пробуем через кэш..."
    info "apt update..."
    DEBIAN_FRONTEND=noninteractive apt-get update -o Acquire::Retries=3 -o Acquire::http::Timeout=30 2>&1 | \
        grep -v '^W:' | grep -v 'translation' | grep -v 'Ign:' || true
    ok "Список пакетов обновлён"
    info "apt upgrade (без интерактивных диалогов)..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade "${APT_OPTS[@]}" 2>&1 | \
        grep -v '^debconf:' | grep -v 'locale-gen' || true
    ok "Пакеты обновлены"
    info "autoremove..."
    DEBIAN_FRONTEND=noninteractive apt-get autoremove "${APT_OPTS[@]}" 2>/dev/null || true
    info "Устанавливаем зависимости (curl, gnupg, dkms, bc)..."
    DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" \
        curl gnupg lsb-release ca-certificates dkms libelf-dev build-essential bc
    ok "Зависимости установлены"
    export DEBIAN_FRONTEND=dialog
}

fn_xanmod() {
    sep; echo -e "${BOLD}🚀 Установка XanMod Kernel${RESET}"; sep
    info "Добавляем репозиторий XanMod..."
    curl -fsSL https://dl.xanmod.org/archive.key | \
        gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg
    echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' \
        > /etc/apt/sources.list.d/xanmod-release.list
    DEBIAN_FRONTEND=noninteractive apt-get update -o Acquire::Retries=3 2>/dev/null | \
        grep -v '^W:' | grep -v 'Ign:' || true
    info "Определяем уровень CPU..."
    PSABI_SCRIPT="/tmp/check_x86-64_psabi.sh"
    curl -fsSL "https://dl.xanmod.org/check_x86-64_psabi.sh" -o "$PSABI_SCRIPT" 2>/dev/null || true
    chmod +x "$PSABI_SCRIPT" 2>/dev/null || true
    CPU_LEVEL="x64v3"
    if [[ -f "$PSABI_SCRIPT" ]]; then
        PSABI_OUT=$(bash "$PSABI_SCRIPT" 2>/dev/null || echo "")
        if   echo "$PSABI_OUT" | grep -q 'x86-64-v4'; then CPU_LEVEL="x64v4"
        elif echo "$PSABI_OUT" | grep -q 'x86-64-v3'; then CPU_LEVEL="x64v3"
        elif echo "$PSABI_OUT" | grep -q 'x86-64-v2'; then CPU_LEVEL="x64v2"
        else CPU_LEVEL="x64v1"; fi
    fi
    info "Уровень CPU: $CPU_LEVEL"
    PKG=""
    for C in "linux-xanmod-${CPU_LEVEL}" "linux-xanmod-edge-${CPU_LEVEL}" \
             "linux-xanmod-x64v3" "linux-xanmod-x64v2" "linux-xanmod"; do
        if apt-cache show "$C" > /dev/null 2>&1; then PKG="$C"; break; fi
    done
    [[ -z "$PKG" ]] && { err "XanMod пакет не найден!"; apt-cache search xanmod; return 1; }
    info "Устанавливаем: $PKG"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG"; then
        ok "XanMod ядро установлено: $PKG"
    else
        warn "Не удалось, пробуем резервные варианты..."
        INSTALLED=0
        for ALT in linux-xanmod-x64v2 linux-xanmod-x64v1 linux-xanmod-edge-x64v3 linux-xanmod-edge; do
            apt-cache search "^$ALT$" | grep -q "$ALT" && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$ALT" && { ok "Установлен: $ALT"; INSTALLED=1; break; }
        done
        [[ $INSTALLED -eq 0 ]] && { err "Не удалось установить XanMod"; return 1; }
    fi
    ok "XanMod установлен! Перезагрузка нужна для загрузки нового ядра."
    info "Следующий шаг: пункты 3 (BBRv3) и 4 (TFO)."
}

fn_bbr() {
    sep; echo -e "${BOLD}📡 Включение BBRv3 + fq qdisc${RESET}"; sep
    # BBR — алгоритм управления перегрузкой, следит за RTT и пропускной способностью.
    # fq (Fair Queue) — оптимальный qdisc-партнёр для BBR на серверах.
    info "Применяем BBRv3 + fq..."
    sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
    SYSCTL_FILE="/etc/sysctl.d/99-xanmod.conf"
    if [[ -f "$SYSCTL_FILE" ]]; then
        grep -q 'default_qdisc' "$SYSCTL_FILE" || echo "net.core.default_qdisc = fq" >> "$SYSCTL_FILE"
        grep -q 'tcp_congestion_control' "$SYSCTL_FILE" || echo "net.ipv4.tcp_congestion_control = bbr" >> "$SYSCTL_FILE"
        sed -i 's/^net.core.default_qdisc\s*=.*/net.core.default_qdisc = fq/' "$SYSCTL_FILE"
        sed -i 's/^net.ipv4.tcp_congestion_control\s*=.*/net.ipv4.tcp_congestion_control = bbr/' "$SYSCTL_FILE"
    else
        printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > "$SYSCTL_FILE"
    fi
    ACTUAL=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    [[ "$ACTUAL" == "bbr" ]] && ok "BBRv3 активен! (qdisc: fq)" \
                              || warn "BBRv3 применён в конфиге, активируется после reboot."
}

fn_tfo() {
    sep; echo -e "${BOLD}⚡ Включение TCP Fast Open (TFO)${RESET}"; sep
    # TFO передаёт данные уже в SYN-пакете при повторных соединениях.
    # Сокращает задержку на 1 RTT. Значение 3 = клиент(1) + сервер(2).
    sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null || true
    SYSCTL_FILE="/etc/sysctl.d/99-xanmod.conf"
    if [[ -f "$SYSCTL_FILE" ]]; then
        grep -q 'tcp_fastopen' "$SYSCTL_FILE" || echo "net.ipv4.tcp_fastopen = 3" >> "$SYSCTL_FILE"
        sed -i 's/^net.ipv4.tcp_fastopen\s*=.*/net.ipv4.tcp_fastopen = 3/' "$SYSCTL_FILE"
    else
        echo "net.ipv4.tcp_fastopen = 3" >> "$SYSCTL_FILE"
    fi
    ACTUAL=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)
    [[ "$ACTUAL" == "3" ]] && ok "TFO активен! (режим: 3 = клиент + сервер)" \
                           || warn "TFO в конфиге, текущее значение: ${ACTUAL:-0}"
}

fn_sysctl() {
    sep; echo -e "${BOLD}🔧 Настройка sysctl${RESET}"; sep
    info "Загружаем модули ядра..."
    modprobe nf_conntrack 2>/dev/null || true
    modprobe br_netfilter 2>/dev/null || true
    SYSCTL_FILE="/etc/sysctl.d/99-xanmod.conf"
    info "Записываем sysctl настройки в $SYSCTL_FILE..."
    cat > "$SYSCTL_FILE" << 'SYSEOF'
# VPS Network Optimizer — sysctl

# BBR + qdisc (также настраивается пунктами 3 и 4)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3

# Conntrack
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_established = 600

# Сетевые буферы
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 65535
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.udp_rmem_min = 16384

# TCP оптимизация
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_syncookies = 1

# IP форвардинг (для туннелей)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Лимиты
fs.file-max = 2097152
vm.max_map_count = 262144
SYSEOF

    sysctl --system 2>/dev/null | grep -v '^*' | grep -v '^sysctl' | tail -10 || true

    if ! grep -q '* soft nofile' /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf << 'LIMEOF'
# VPS Network Optimizer
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMEOF
    fi

    mkdir -p /etc/systemd/system.conf.d
    printf '[Manager]\nDefaultLimitNOFILE=1048576\n' > /etc/systemd/system.conf.d/limits.conf

    ok "sysctl применён: /etc/sysctl.d/99-xanmod.conf"
}

fn_proxy_tune() {
    sep; echo -e "${BOLD}🔌 Оптимизация TCP для прокси${RESET}"; sep

    # Trio keepalive — три параметра работают вместе:
    # tcp_keepalive_time  — через N сек бездействия начать проверку (дефолт 7200 = 2ч!)
    # tcp_keepalive_intvl — интервал между проверочными пакетами
    # tcp_keepalive_probes — кол-во попыток до закрытия соединения
    # Итого: 600 + 30*5 = ~12 мин вместо ~2 часов на обнаружение мёртвых соединений
    info "Настраиваем TCP Keepalive trio (time + intvl + probes)..."
    sysctl -w net.ipv4.tcp_keepalive_time=600   2>/dev/null || true
    sysctl -w net.ipv4.tcp_keepalive_intvl=30   2>/dev/null || true
    sysctl -w net.ipv4.tcp_keepalive_probes=5   2>/dev/null || true

    # tcp_notsent_lowat = пара к keepalive для прокси:
    # при HTTP/2/QUIC ядро принимает данные только когда в буфере < 16KB
    # → меньше задержка, лучше отзывчивость прокси
    info "Настраиваем tcp_notsent_lowat=16384..."
    sysctl -w net.ipv4.tcp_notsent_lowat=16384  2>/dev/null || true

    # vm.swappiness: 60 (дефолт) для десктопов, 10 для серверов
    # держим всё в RAM, в swap только в крайней нужде
    SWAP_ACTIVE=$(swapon --show --noheadings 2>/dev/null | wc -l)
    if [[ "$SWAP_ACTIVE" -gt 0 ]]; then
        info "Swap обнаружен — swappiness=10 (дефолт 60)..."
        sysctl -w vm.swappiness=10 2>/dev/null || true
    else
        info "Swap не активен — swappiness пропускаем (создай swap в пункте 10)."
    fi

    SYSCTL_FILE="/etc/sysctl.d/99-xanmod.conf"
    sed -i '/tcp_keepalive_time\|tcp_keepalive_intvl\|tcp_keepalive_probes\|tcp_notsent_lowat\|vm.swappiness/d' \
        "$SYSCTL_FILE" 2>/dev/null || true
    cat >> "$SYSCTL_FILE" << 'PROXYEOF'

# Оптимизация TCP для прокси
# Trio keepalive: ~12 мин на обнаружение мёртвых соединений (вместо ~2 часов)
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
# Снижает задержку при мультиплексировании (HTTP/2, QUIC)
net.ipv4.tcp_notsent_lowat = 16384
PROXYEOF
    if [[ "$SWAP_ACTIVE" -gt 0 ]]; then
        echo "vm.swappiness = 10" >> "$SYSCTL_FILE"
    fi

    ok "Оптимизация TCP для прокси применена!"
    info "Keepalive: time=600s | intvl=30s | probes=5"
    info "notsent_lowat: 16384 байт"
    [[ "$SWAP_ACTIVE" -gt 0 ]] && info "swappiness: 10"
}

fn_detect_mtu() {
    local target="${1:-8.8.8.8}"
    info "Адаптивный поиск MTU (цель: $target)..."
    local low=576 high=1500 best=1500 mid data_size
    if ! ping -c 1 -W 2 "$target" > /dev/null 2>&1; then
        warn "Хост недоступен, используем rt mtu."
        DETECTED_MTU=0; MSS_V4=0; MSS_V6=0; return 1
    fi
    while [[ $((high - low)) -gt 1 ]]; do
        mid=$(( (low + high) / 2 ))
        data_size=$(( mid - 28 ))
        [[ $data_size -lt 0 ]] && data_size=0
        if ping -M do -s "$data_size" -c 2 -W 3 "$target" > /dev/null 2>&1; then
            best=$mid; low=$mid
        else
            high=$mid
        fi
    done
    DETECTED_MTU=$best
    MSS_V4=$(( DETECTED_MTU - 40 ))
    MSS_V6=$(( DETECTED_MTU - 60 ))
    ok "Path MTU: ${DETECTED_MTU} | MSS IPv4: ${MSS_V4} | MSS IPv6: ${MSS_V6}"
}

fn_mss() {
    sep; echo -e "${BOLD}🔒 MSS Clamping (nftables)${RESET}"; sep
    echo ""
    echo -e "  ${CYAN}Режим MSS Clamping:${RESET}"
    echo -e "  ${GREEN}1)${RESET} 🤖 Авто ${YELLOW}(rt mtu из таблицы маршрутов)${RESET}"
    echo -e "  ${GREEN}2)${RESET} 🔍 Адаптивный ${YELLOW}(бинарный поиск реального Path MTU)${RESET}"
    echo -e "  ${GREEN}3)${RESET} ✏️  Ручной ${YELLOW}(1420 WireGuard, 1492 PPPoE, 1500 Ethernet)${RESET}"
    echo ""
    read -rp "  Режим [1-3, Enter=1]: " mss_mode
    mss_mode="${mss_mode:-1}"
    USE_RT_MTU=true; MSS_V4=0; MSS_V6=0; DETECTED_MTU=0

    case "$mss_mode" in
        1) USE_RT_MTU=true; info "Режим: авто (rt mtu)" ;;
        2)
            fn_detect_mtu "8.8.8.8"
            if [[ $DETECTED_MTU -gt 0 ]]; then
                USE_RT_MTU=false
            else
                warn "Не удалось определить MTU, используем авто"
                USE_RT_MTU=true
            fi ;;
        3)
            read -rp "  MTU [576-9000, Enter=1500]: " custom_mtu
            custom_mtu="${custom_mtu:-1500}"
            if [[ "$custom_mtu" =~ ^[0-9]+$ ]] && \
               [ "$custom_mtu" -ge 576 ] && [ "$custom_mtu" -le 9000 ]; then
                DETECTED_MTU=$custom_mtu
                MSS_V4=$(( custom_mtu - 40 ))
                MSS_V6=$(( custom_mtu - 60 ))
                USE_RT_MTU=false
                info "MTU: $DETECTED_MTU | MSS IPv4: $MSS_V4 | MSS IPv6: $MSS_V6"
            else
                warn "Некорректный MTU, используем авто"
                USE_RT_MTU=true
            fi ;;
        *) USE_RT_MTU=true; info "Неверный выбор, авто-режим" ;;
    esac

    info "Устанавливаем nftables..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q nftables 2>/dev/null || true
    systemctl enable nftables 2>/dev/null || true
    NFT_CONF="/etc/nftables.conf"

    if [[ "$USE_RT_MTU" == true ]]; then
        cat > "$NFT_CONF" << 'NFTEOF'
#!/usr/sbin/nft -f
# VPS Network Optimizer — MSS Clamping (авто rt mtu)
flush ruleset
table inet mangle {
    chain forward {
        type filter hook forward priority mangle; policy accept;
        tcp flags syn tcp option maxseg size set rt mtu
    }
    chain output {
        type filter hook output priority mangle; policy accept;
        tcp flags syn tcp option maxseg size set rt mtu
    }
}
NFTEOF
    else
        cat > "$NFT_CONF" << NFTEOF
#!/usr/sbin/nft -f
# VPS Network Optimizer — MSS Clamping (MTU: ${DETECTED_MTU})
flush ruleset
table inet mangle {
    chain forward {
        type filter hook forward priority mangle; policy accept;
        meta nfproto ipv4 tcp flags syn tcp option maxseg size set ${MSS_V4}
        meta nfproto ipv6 tcp flags syn tcp option maxseg size set ${MSS_V6}
    }
    chain output {
        type filter hook output priority mangle; policy accept;
        meta nfproto ipv4 tcp flags syn tcp option maxseg size set ${MSS_V4}
        meta nfproto ipv6 tcp flags syn tcp option maxseg size set ${MSS_V6}
    }
}
NFTEOF
    fi

    systemctl restart nftables
    ok "nftables запущен и сохранён"
    nft list ruleset
    ok "MSS Clamping настроен!"
}

fn_cake() {
    sep; echo -e "${BOLD}📦 Отключение CAKE → fq qdisc${RESET}"; sep
    # CAKE хорош для роутеров, на серверах с BBR лучше fq (Fair Queue)
    info "Получаем интерфейсы..."
    INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$')
    for iface in $INTERFACES; do
        CURRENT_QDISC=$(tc qdisc show dev "$iface" 2>/dev/null | grep -oP '(?<=qdisc )\w+' | head -1)
        info "  $iface: qdisc = ${CURRENT_QDISC:-неизвестно}"
        [[ "$CURRENT_QDISC" == "cake" ]] && tc qdisc del dev "$iface" root 2>/dev/null || true
        tc qdisc add dev "$iface" root fq limit 10000 2>/dev/null && ok "fq установлен на $iface" \
            || warn "fq уже есть или ошибка на $iface"
    done

    cat > /etc/systemd/system/tc-fq-optimize.service << 'SVCEOF'
[Unit]
Description=Apply fq qdisc to network interfaces
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for i in $(ip -o link show | awk -F": " "{print \$2}" | grep -v "^lo$"); do tc qdisc replace dev $i root fq limit 10000; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable tc-fq-optimize.service 2>/dev/null
    ok "Сервис tc-fq-optimize включён"
    echo ""
    tc qdisc show 2>/dev/null || true
    ok "CAKE отключён, fq установлен!"
}

fn_ipv6() {
    sep; echo -e "${BOLD}🌐 Управление IPv6${RESET}"; sep
    CURRENT=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    if [[ "$CURRENT" == "1" ]]; then
        echo -e "  Статус: ${RED}IPv6 отключён${RESET}"
        read -rp "  Включить IPv6? [y/N]: " c
        if [[ "$c" =~ ^[Yy]$ ]]; then
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 2>/dev/null || true
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 2>/dev/null || true
            sysctl -w net.ipv6.conf.lo.disable_ipv6=0 2>/dev/null || true
            sed -i '/disable_ipv6/d' /etc/sysctl.d/99-xanmod.conf 2>/dev/null || true
            ok "IPv6 включён"
        else
            info "Отменено."
        fi
    else
        echo -e "  Статус: ${GREEN}IPv6 включён${RESET}"
        echo ""
        echo "  Зачем отключать IPv6:"
        echo "  • Некоторые прокси работают только через IPv4"
        echo "  • Исключает утечки через IPv6 если туннель его не поддерживает"
        echo "  • Упрощает отладку сети"
        echo ""
        read -rp "  Отключить IPv6? [y/N]: " c
        if [[ "$c" =~ ^[Yy]$ ]]; then
            sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
            sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
            sysctl -w net.ipv6.conf.lo.disable_ipv6=1 2>/dev/null || true
            SYSCTL_FILE="/etc/sysctl.d/99-xanmod.conf"
            sed -i '/disable_ipv6/d' "$SYSCTL_FILE" 2>/dev/null || true
            printf '\n# IPv6 отключён\nnet.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1\n' >> "$SYSCTL_FILE"
            ok "IPv6 отключён (сохранено в sysctl)"
        else
            info "Отменено."
        fi
    fi
}

fn_swap() {
    sep; echo -e "${BOLD}💾 Создание Swap-файла${RESET}"; sep
    echo ""
    echo -e "  ${CYAN}Свободное место:${RESET}"
    df -h / | awk 'NR==2 {printf "  Всего: %s | Занято: %s | Свободно: %s\n", $2, $3, $4}'
    echo ""
    echo -e "  ${GREEN}1)${RESET} 512 МБ ${YELLOW}(для 1+ ГБ RAM)${RESET}"
    echo -e "  ${GREEN}2)${RESET} 1 ГБ   ${YELLOW}(рекомендуется для 1-2 ГБ RAM)${RESET}"
    echo -e "  ${GREEN}3)${RESET} 2 ГБ   ${YELLOW}(для 2-4 ГБ RAM)${RESET}"
    echo -e "  ${GREEN}4)${RESET} 4 ГБ   ${YELLOW}(для 4+ ГБ RAM)${RESET}"
    echo -e "  ${GREEN}5)${RESET} ✏️  Свой размер (в МБ)"
    echo ""
    read -rp "  Размер [1-5, Enter=2]: " swap_choice
    swap_choice="${swap_choice:-2}"
    case "$swap_choice" in
        1) SWAP_MB=512;  SWAP_LABEL="512 МБ" ;;
        2) SWAP_MB=1024; SWAP_LABEL="1 ГБ"   ;;
        3) SWAP_MB=2048; SWAP_LABEL="2 ГБ"   ;;
        4) SWAP_MB=4096; SWAP_LABEL="4 ГБ"   ;;
        5)
            read -rp "  Введи МБ (128-32768): " custom_mb
            if [[ "$custom_mb" =~ ^[0-9]+$ ]] && [ "$custom_mb" -ge 128 ] && [ "$custom_mb" -le 32768 ]; then
                SWAP_MB=$custom_mb
                [[ "$SWAP_MB" -ge 1024 ]] && SWAP_LABEL="$(echo "scale=1; $SWAP_MB/1024" | bc) ГБ" \
                                          || SWAP_LABEL="${SWAP_MB} МБ"
            else
                warn "Некорректный ввод, используем 1 ГБ"; SWAP_MB=1024; SWAP_LABEL="1 ГБ"
            fi ;;
        *) warn "Неверный выбор, используем 1 ГБ"; SWAP_MB=1024; SWAP_LABEL="1 ГБ" ;;
    esac

    info "Создаём Swap: ${SWAP_LABEL}..."
    swapoff /swapfile 2>/dev/null || true
    if fallocate -l "${SWAP_MB}M" /swapfile; then
        ok "Файл /swapfile выделен"
    else
        warn "fallocate недоступен, используем dd..."
        dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=progress
    fi
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -qE '^\s*/swapfile\s' /etc/fstab || echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    echo ""
    swapon --show
    free -h
    ok "Swap ${SWAP_LABEL} активен!"
}

fn_show_statusbar() {
    uname -r 2>/dev/null | grep -qi xanmod \
        && S_XANMOD="${GREEN}✅ XanMod${RESET}" || S_XANMOD="${RED}❌ XanMod${RESET}"

    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q '^bbr' \
        && S_BBR="${GREEN}✅ BBR${RESET}" || S_BBR="${RED}❌ BBR${RESET}"

    TFO_VAL=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "0")
    [[ "$TFO_VAL" == "3" ]] && S_TFO="${GREEN}✅ TFO${RESET}" || S_TFO="${RED}❌ TFO${RESET}"

    sysctl -n net.core.default_qdisc 2>/dev/null | grep -qE '^fq$' \
        && S_FQ="${GREEN}✅ fq${RESET}" || S_FQ="${RED}❌ fq${RESET}"

    nft list ruleset 2>/dev/null | grep -q mangle \
        && S_MSS="${GREEN}✅ MSS${RESET}" || S_MSS="${RED}❌ MSS${RESET}"

    KA_VAL=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo "7200")
    [[ "$KA_VAL" -le 600 ]] && S_PROXY="${GREEN}✅ Proxy${RESET}" || S_PROXY="${RED}❌ Proxy${RESET}"

    SWAP_INFO=$(swapon --show=SIZE,NAME --noheadings 2>/dev/null | awk '/swapfile/{print $1}')
    [[ -n "$SWAP_INFO" ]] && S_SWAP="${GREEN}Swap:${SWAP_INFO}${RESET}" || S_SWAP="${YELLOW}Swap:нет${RESET}"

    IPV6_DIS=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    [[ "$IPV6_DIS" == "1" ]] && S_IPV6="${YELLOW}IPv6:выкл${RESET}" || S_IPV6="${GREEN}IPv6:вкл${RESET}"

    echo -e "  ${S_XANMOD}  ${S_BBR}  ${S_TFO}  ${S_FQ}  ${S_MSS}  ${S_PROXY}  ${S_SWAP}  ${S_IPV6}"
}

fn_status() {
    sep; echo -e "${BOLD}📊 Статус оптимизации${RESET}"; sep; echo ""
    status_row() {
        local name="$1" state="$2" value="$3" icon color
        case "$state" in
            ok)   icon="✅"; color="$GREEN"  ;;
            warn) icon="⚠️ "; color="$YELLOW" ;;
            err)  icon="❌"; color="$RED"    ;;
        esac
        printf "  %-22s %b%-5s%b  %s\n" "$name" "$color" "$icon" "$RESET" "$value"
    }

    KERNEL=$(uname -r 2>/dev/null)
    echo "$KERNEL" | grep -qi xanmod && status_row "XanMod Kernel" ok "$KERNEL" \
                                     || status_row "XanMod Kernel" err "$KERNEL"

    BBR_VAL=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    [[ "$BBR_VAL" == "bbr" ]] && status_row "BBRv3" ok "$BBR_VAL" \
                               || status_row "BBRv3" err "$BBR_VAL (нужен bbr)"

    TFO_VAL=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "0")
    if   [[ "$TFO_VAL" == "3" ]]; then status_row "TCP Fast Open" ok "3 (клиент + сервер)"
    elif [[ "$TFO_VAL" == "1" || "$TFO_VAL" == "2" ]]; then status_row "TCP Fast Open" warn "частично ($TFO_VAL)"
    else status_row "TCP Fast Open" err "выключен ($TFO_VAL)"; fi

    QDISC_VAL=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
    [[ "$QDISC_VAL" == "fq" ]] && status_row "Default qdisc" ok "fq" \
                                || status_row "Default qdisc" warn "$QDISC_VAL (нужен fq)"

    if nft list ruleset 2>/dev/null | grep -q mangle; then
        MSS_VAL=$(grep -o 'maxseg size set [0-9]*' /etc/nftables.conf 2>/dev/null | head -1 | awk '{print $NF}')
        [[ -n "$MSS_VAL" ]] && status_row "MSS Clamping" ok "nftables (MSS=$MSS_VAL)" \
                             || status_row "MSS Clamping" ok "nftables (rt mtu)"
    else
        status_row "MSS Clamping" err "не настроен"
    fi

    KA_VAL=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo "7200")
    [[ "$KA_VAL" -le 600 ]] && status_row "TCP Proxy tune" ok "keepalive=${KA_VAL}s" \
                             || status_row "TCP Proxy tune" warn "не настроен (${KA_VAL}s)"

    CT_VAL=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "")
    [[ -n "$CT_VAL" ]] && status_row "Conntrack max" ok "$CT_VAL" \
                       || status_row "Conntrack max" warn "модуль не загружен"

    SWAP_LINE=$(swapon --show=NAME,SIZE,USED --noheadings 2>/dev/null | grep swapfile | head -1)
    if [[ -n "$SWAP_LINE" ]]; then
        status_row "Swap" ok "$(echo "$SWAP_LINE" | awk '{print $2}') (исп: $(echo "$SWAP_LINE" | awk '{print $3}'))"
    else
        status_row "Swap" warn "не активен"
    fi

    IPV6_DIS=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    [[ "$IPV6_DIS" == "1" ]] && status_row "IPv6" warn "отключён" || status_row "IPv6" ok "включён"

    systemctl is-active --quiet tc-fq-optimize.service 2>/dev/null \
        && status_row "tc-fq сервис" ok "активен" || status_row "tc-fq сервис" warn "не установлен"

    echo ""; sep
}

fn_cleanup() {
    sep; echo -e "${BOLD}🧹 Очистка диска${RESET}"; sep
    echo ""

    # Показываем место ДО очистки
    echo -e "  ${CYAN}Диск сейчас:${RESET}"
    df -h / | awk 'NR==2 {printf "  Всего: %s | Занято: %s | Свободно: %s\n", $2, $3, $4}'
    echo ""

    # Дисклеймер — показываем ЧТО именно будет удалено
    echo -e "  ${YELLOW}⚠️  Будет удалено (необратимо):${RESET}"
    echo "  • apt autoremove  — пакеты, нужные только как зависимости (сейчас не нужны)"
    echo "  • apt clean       — кэш загруженных .deb файлов"
    echo "  • journalctl      — системные логи, оставит только последние 100 МБ"
    echo "  • /tmp/optimizer* — временные файлы скрипта"

    # Проверяем Docker — добавляем в список только если установлен
    DOCKER_INSTALLED=false
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        DOCKER_INSTALLED=true
        DOCKER_IMAGES=$(docker images -q 2>/dev/null | wc -l)
        DOCKER_DANGLING=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
        echo "  • docker image prune — образы без тегов (dangling), сейчас таких: ${DOCKER_DANGLING}"
        echo "                         ⚠️  Используемые образы и контейнеры НЕ затрагиваются"
    else
        echo "  • Docker — не установлен, пропускаем"
    fi

    echo ""
    warn "Работающие сервисы, данные и конфигурации НЕ затрагиваются."
    echo ""
    read -rp "  Начать очистку? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Отменено."; return; }

    echo ""
    # --- Неиспользуемые пакеты ---
    info "Удаляем неиспользуемые пакеты (autoremove)..."
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y \
        -o Dpkg::Options::="--force-confdef" 2>/dev/null | \
        grep -E 'Removing|removed|freed' | head -10 || true
    ok "autoremove выполнен"

    # --- Кэш apt ---
    info "Чистим кэш apt..."
    apt-get autoclean 2>/dev/null || true
    apt-get clean 2>/dev/null || true
    ok "Кэш apt очищен"

    # --- Системные логи (journald) ---
    info "Чистим journald логи (оставляем последние 100 МБ)..."
    journalctl --vacuum-size=100M 2>/dev/null || true
    ok "Логи очищены"

    # --- Наши временные файлы ---
    info "Удаляем временные файлы /tmp/optimizer-*..."
    rm -f /tmp/optimizer-*.sh 2>/dev/null || true
    ok "Временные файлы удалены"

    # --- Docker (только если установлен и работает) ---
    if [[ "$DOCKER_INSTALLED" == true ]]; then
        echo ""
        echo -e "  ${CYAN}Docker cleanup:${RESET}"
        info "Удаляем dangling образы (docker image prune)..."
        docker image prune -f 2>/dev/null && ok "Docker образы очищены" || warn "Ошибка docker prune"
    fi

    # Показываем место ПОСЛЕ очистки
    echo ""
    echo -e "  ${CYAN}Диск после очистки:${RESET}"
    df -h / | awk 'NR==2 {printf "  Всего: %s | Занято: %s | Свободно: %s\n", $2, $3, $4}'
    echo ""
    ok "Очистка завершена!"
}

fn_remna() {
    sep; echo -e "${BOLD}🐳 Обновление RemnaNode${RESET}"; sep
    echo ""

    # Проверяем наличие Docker
    if ! command -v docker &>/dev/null; then
        err "Docker не установлен. Установи Docker и повтори."
        return 1
    fi

    # Проверяем папку проекта
    REMNA_DIR="/opt/remnanode"
    if [[ ! -d "$REMNA_DIR" ]]; then
        err "Папка $REMNA_DIR не найдена!"
        echo ""
        read -rp "  Введи другой путь к проекту [Enter = отмена]: " custom_dir
        [[ -z "$custom_dir" ]] && { info "Отменено."; return; }
        if [[ ! -d "$custom_dir" ]]; then
            err "Папка $custom_dir не существует."; return 1
        fi
        REMNA_DIR="$custom_dir"
    fi

    info "Папка проекта: $REMNA_DIR"

    # Проверяем наличие docker-compose файла
    if [[ ! -f "$REMNA_DIR/docker-compose.yml" ]] && \
       [[ ! -f "$REMNA_DIR/docker-compose.yaml" ]] && \
       [[ ! -f "$REMNA_DIR/compose.yml" ]]; then
        err "docker-compose файл не найден в $REMNA_DIR"
        return 1
    fi

    # Показываем текущие запущенные контейнеры
    echo -e "  ${CYAN}Текущие контейнеры:${RESET}"
    docker compose -f "$REMNA_DIR"/docker-compose.y*ml ps 2>/dev/null || \
    docker compose -f "$REMNA_DIR"/compose.yml ps 2>/dev/null || true
    echo ""

    warn "Будет выполнено:"
    echo "  1. docker compose pull  — скачать новые образы"
    echo "  2. docker compose down  — остановить контейнеры"
    echo "  3. docker compose up -d — запустить с новыми образами"
    echo ""
    warn "Сервис будет недоступен ~10-60 секунд во время обновления."
    echo ""
    read -rp "  Обновить RemnaNode? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Отменено."; return; }

    cd "$REMNA_DIR" || { err "Не удалось перейти в $REMNA_DIR"; return 1; }

    echo ""
    info "Шаг 1/3: Скачиваем новые образы (docker compose pull)..."
    docker compose pull
    ok "Образы скачаны"

    echo ""
    info "Шаг 2/3: Останавливаем контейнеры (docker compose down)..."
    docker compose down
    ok "Контейнеры остановлены"

    echo ""
    info "Шаг 3/3: Запускаем с новыми образами (docker compose up -d)..."
    docker compose up -d
    ok "RemnaNode запущен!"

    echo ""
    sep
    echo -e "  ${CYAN}Статус контейнеров:${RESET}"
    docker compose ps
    echo ""

    read -rp "  Следить за логами в реальном времени? [y/N]: " show_logs
    if [[ "$show_logs" =~ ^[Yy]$ ]]; then
        info "Вывод логов (Ctrl+C для выхода)..."
        echo ""
        docker compose logs -f
    else
        info "Последние 30 строк логов:"
        echo ""
        docker compose logs --tail=30
    fi
}

fn_install_opti() {
    # Устанавливает команду 'opti' — запускает этот скрипт из любого места терминала.
    # Скрипт скачивается свежий каждый раз при вызове 'opti'.
    OPTI_PATH="/usr/local/bin/opti"

    if [[ -f "$OPTI_PATH" ]]; then
        info "Команда 'opti' уже установлена ($OPTI_PATH)"
        return 0
    fi

    cat > "$OPTI_PATH" << 'OPTIEOF'
#!/bin/bash
# VPS Network Optimizer — быстрый запуск
# Установлен скриптом: https://github.com/anqqu/optimizer
_TMP=$(mktemp /tmp/optimizer-XXXXXX.sh)
curl -fsSL "https://raw.githubusercontent.com/anqqu/optimizer/main/optimizer.sh" \
     -o "$_TMP" 2>/dev/null || { echo "Ошибка: не удалось загрузить скрипт"; rm -f "$_TMP"; exit 1; }
chmod +x "$_TMP"
bash "$_TMP" "$@"
rm -f "$_TMP"
OPTIEOF

    chmod +x "$OPTI_PATH"
    ok "Команда 'opti' установлена → $OPTI_PATH"
    info "Теперь можешь запускать меню командой: opti"
}

fn_full_install() {
    sep; echo -e "${BOLD}🏆 Полная установка${RESET}"; sep
    warn "Это займёт несколько минут. Сделай снапшот VPS!"
    echo ""
    read -rp "  Продолжить? [y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || { info "Отменено."; return; }

    echo ""; info "Шаг 1/8: Обновление пакетов...";         fn_update
    echo ""; info "Шаг 2/8: Установка XanMod...";           fn_xanmod
    echo ""; info "Шаг 3/8: BBRv3...";                      fn_bbr
    echo ""; info "Шаг 4/8: TFO...";                        fn_tfo
    echo ""; info "Шаг 5/8: sysctl...";                     fn_sysctl
    echo ""; info "Шаг 6/8: Оптимизация TCP для прокси..."; fn_proxy_tune
    echo ""; info "Шаг 7/8: MSS Clamping...";               fn_mss
    echo ""; info "Шаг 8/8: CAKE → fq...";                  fn_cake

    sep; ok "=== Полная установка завершена! ==="; sep
    echo ""
    warn "Нужна перезагрузка для загрузки XanMod!"
    read -rp "  Перезагрузить сейчас? [y/N]: " r
    if [[ "$r" =~ ^[Yy]$ ]]; then info "Перезагружаемся..."; reboot
    else info "Перезагрузи вручную: sudo reboot"; fi
}

main_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════╗${RESET}"
        echo -e "${CYAN}${BOLD}║       ⚡ VPS Network Optimizer  v2.2          ║${RESET}"
        echo -e "${CYAN}${BOLD}║      github.com/anqqu/optimizer               ║${RESET}"
        echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════╝${RESET}"
        echo ""
        echo -e "  ${BLUE}Ядро:${RESET} $(uname -r)  ${BLUE}|${RESET}  ${BLUE}ОС:${RESET} $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
        echo -e "  ${BLUE}RAM:${RESET}  $(free -h | awk '/^Mem:/{print $2}')  ${BLUE}|${RESET}  ${BLUE}CPU:${RESET} $(nproc) ядра  ${BLUE}|${RESET}  ${BLUE}Диск:${RESET} $(df -h / | awk 'NR==2{print $4}') свободно"
        echo ""
        fn_show_statusbar
        echo ""
        sep
        echo -e "  ${BOLD}Ядро и сеть:${RESET}"
        echo -e "  ${GREEN} 1)${RESET} 🔄 Обновить пакеты ${YELLOW}(apt + авто-зеркало)${RESET}"
        echo -e "  ${GREEN} 2)${RESET} 🚀 Установить XanMod Kernel"
        echo -e "  ${GREEN} 3)${RESET} 📡 Включить BBRv3 + fq qdisc"
        echo -e "  ${GREEN} 4)${RESET} ⚡ Включить TCP Fast Open ${YELLOW}(TFO)${RESET}"
        echo -e "  ${GREEN} 5)${RESET} 🔧 Настроить sysctl ${YELLOW}(conntrack, буферы, лимиты)${RESET}"
        echo -e "  ${GREEN} 6)${RESET} 🔌 Оптимизация TCP для прокси ${YELLOW}(keepalive + notsent_lowat)${RESET}"
        echo -e "  ${GREEN} 7)${RESET} 🔒 MSS Clamping ${YELLOW}(авто / адаптивный MTU / ручной)${RESET}"
        echo -e "  ${GREEN} 8)${RESET} 📦 Отключить CAKE → fq qdisc"
        echo ""
        echo -e "  ${BOLD}Система:${RESET}"
        echo -e "  ${GREEN} 9)${RESET} 🌐 IPv6 ${YELLOW}(вкл / выкл)${RESET}"
        echo -e "  ${GREEN}10)${RESET} 💾 Создать Swap ${YELLOW}(512МБ / 1 / 2 / 4 ГБ / свой)${RESET}"
        echo -e "  ${GREEN}11)${RESET} 🧹 Очистить диск ${YELLOW}(autoremove, кэш, логи, docker)${RESET}"
        echo ""
        echo -e "  ${BOLD}Сервисы:${RESET}"
        echo -e "  ${GREEN}12)${RESET} 🐳 Обновить RemnaNode ${YELLOW}(docker compose pull + up)${RESET}"
        echo ""
        echo -e "  ${BOLD}Утилиты:${RESET}"
        echo -e "  ${GREEN}13)${RESET} 📊 Проверить статус"
        echo -e "  ${GREEN}14)${RESET} 📥 Установить команду ${CYAN}opti${RESET} ${YELLOW}(запуск из любого места)${RESET}"
        echo ""
        echo -e "  ${BOLD}Быстрый старт:${RESET}"
        echo -e "  ${GREEN}15)${RESET} 🏆 ${BOLD}Полная установка (все шаги сразу)${RESET}"
        sep
        echo -e "  ${RED} 0)${RESET} ❌ Выход"
        echo ""

        read -rp "  Выбери пункт [0-15]: " choice
        echo ""

        case "$choice" in
            1)  fn_update       ;;
            2)  fn_xanmod       ;;
            3)  fn_bbr          ;;
            4)  fn_tfo          ;;
            5)  fn_sysctl       ;;
            6)  fn_proxy_tune   ;;
            7)  fn_mss          ;;
            8)  fn_cake         ;;
            9)  fn_ipv6         ;;
            10) fn_swap         ;;
            11) fn_cleanup      ;;
            12) fn_remna        ;;
            13) fn_status       ;;
            14) fn_install_opti ;;
            15) fn_full_install ;;
            0)
                echo -e "${GREEN}Удачи! 👋${RESET}"
                exit 0 ;;
            *)
                warn "Неверный выбор: '$choice'. Введи 0-15." ;;
        esac

        echo ""
        read -rp "  Нажми Enter чтобы вернуться в меню..." _
    done
}

# =============================================================================
# ТОЧКА ВХОДА
# =============================================================================
check_root
check_os
# Авто-установка команды 'opti' при первом запуске (тихо, без вопросов)
fn_install_opti 2>/dev/null || true
main_menu