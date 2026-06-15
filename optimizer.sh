#!/bin/bash
# =============================================
# XanMod + BBRv3 + TFO + MSS Clamp + Conntrack
# Автоопределение CPU + отключение CAKE
# =============================================

set -e

echo "=== Optimization Script (с отключением CAKE) ==="

# Обновление
sudo apt update && sudo apt upgrade -y

# Зависимости
sudo apt install -y curl gnupg lsb-release ca-certificates dkms libelf-dev build-essential

# === XanMod SAFE (official method + precheck) ===

echo "=== XanMod safe install ==="

sudo install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://dl.xanmod.org/archive.key | sudo gpg --dearmor -o /etc/apt/keyrings/xanmod.gpg

REPO_URL="http://deb.xanmod.org"

CODENAME=$(lsb_release -sc)

echo "Detected codename: $CODENAME"

# проверка ДО добавления (ВАЖНО)
if curl -fsI "$REPO_URL/dists/$CODENAME/Release" >/dev/null 2>&1; then

    echo "deb [signed-by=/etc/apt/keyrings/xanmod.gpg] $REPO_URL $CODENAME main" | \
    sudo tee /etc/apt/sources.list.d/xanmod.list > /dev/null

    sudo apt update

else
    echo "⚠️ XanMod repo not available for $CODENAME"

    # fallback только из официального списка (НЕ выдумываем)
    for c in bookworm trixie sid noble plucky questing resolute faye gigi wilma xia zara zena; do

        echo "→ trying $c"

        if curl -fsI "$REPO_URL/dists/$c/Release" >/dev/null 2>&1; then

            echo "deb [signed-by=/etc/apt/keyrings/xanmod.gpg] $REPO_URL $c main" | \
            sudo tee /etc/apt/sources.list.d/xanmod.list > /dev/null

            sudo apt update
            break
        fi
    done
fi

# === 2. Определение версии CPU и установка ===
echo "Определяем уровень CPU..."
curl -fsSLO https://dl.xanmod.org/check_x86-64_psabi.sh
chmod +x check_x86-64_psabi.sh

CPU_LEVEL=$(./check_x86-64_psabi.sh | grep -o 'x86-64-v[0-9]' | head -n1 || echo "v2")

# === Выбор лучшего доступного XanMod пакета ===

if [[ "$CPU_LEVEL" == "x86-64-v4" || "$CPU_LEVEL" == "x86-64-v3" ]]; then

    CANDIDATES=(
        linux-xanmod-x64v3
        linux-xanmod-lts-x64v3
        linux-xanmod-edge-x64v3
    )

elif [[ "$CPU_LEVEL" == "x86-64-v2" ]]; then

    CANDIDATES=(
        linux-xanmod-x64v2
        linux-xanmod-lts-x64v2
        linux-xanmod-edge-x64v2
    )

else

    CANDIDATES=(
        linux-xanmod-x64v1
        linux-xanmod-lts-x64v1
    )

fi

PKG=""

for p in "${CANDIDATES[@]}"; do
    if apt-cache search "^$p$" | grep -q "$p"; then
        PKG="$p"
        break
    fi
done

if [[ -z "$PKG" ]]; then
    echo "❌ Не найден ни один XanMod пакет!"
    apt-cache search xanmod
    exit 1
fi

echo "Выбран пакет: $PKG"

echo "Устанавливаем: $PKG ($CPU_LEVEL)"

if ! sudo apt install -y "$PKG"; then
    echo "⚠️ Не удалось установить $PKG, пробуем fallback..."
    for ALT in linux-xanmod-x64v2 linux-xanmod-x64v1 linux-xanmod-edge-x64v3 linux-xanmod-edge-x64v2 linux-xanmod-edge; do
        if apt-cache search "^$ALT$" | grep -q "$ALT"; then
            echo "✅ Используем fallback: $ALT"
            sudo apt install -y "$ALT" && break
        fi
    done
fi

# === 3. Отключение CAKE (если включён) ===
echo "Проверяем и отключаем CAKE qdisc..."

# Получаем все сетевые интерфейсы (исключаем lo)
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$')

for iface in $INTERFACES; do
    if tc qdisc show dev "$iface" 2>/dev/null | grep -iq cake; then
        echo "→ Обнаружен CAKE на $iface — заменяем на fq"
        sudo tc qdisc del dev "$iface" root 2>/dev/null || true
        sudo tc qdisc replace dev "$iface" root fq
    else
        # На всякий случай ставим fq, если нет ничего подходящего
        CURRENT=$(tc qdisc show dev "$iface" 2>/dev/null | head -n1)
        if ! echo "$CURRENT" | grep -Eq 'fq|fq_codel'; then
            echo "→ Устанавливаем fq на $iface (текущий: ${CURRENT:-none})"
            sudo tc qdisc replace dev "$iface" root fq
        fi
    fi
done

echo "CAKE отключён, используется fq + BBRv3"

# === 4. Sysctl настройки (с обработкой ошибок) ===
echo "Создаём оптимизированные sysctl настройки..."

# === Автоподбор параметров по RAM + CPU ===

TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
CPU_CORES=$(nproc)

echo "RAM detected: ${TOTAL_RAM_MB}MB"
echo "CPU cores: ${CPU_CORES}"

# --- Conntrack по RAM ---
if [ "$TOTAL_RAM_MB" -le 1024 ]; then
    # 1/1, 1/2 — слабые ноды
    CONNTRACK_MAX=131072
    CONNTRACK_BUCKETS=32768
    SOMAXCONN=4096
    NETDEV_BACKLOG=8192
    SYN_BACKLOG=4096
elif [ "$TOTAL_RAM_MB" -le 2048 ]; then
    # 1/2, 2/2
    CONNTRACK_MAX=262144
    CONNTRACK_BUCKETS=65536
    SOMAXCONN=8192
    NETDEV_BACKLOG=16384
    SYN_BACKLOG=8192
elif [ "$TOTAL_RAM_MB" -le 4096 ]; then
    # 2/4
    CONNTRACK_MAX=524288
    CONNTRACK_BUCKETS=131072
    SOMAXCONN=16384
    NETDEV_BACKLOG=32768
    SYN_BACKLOG=16384
else
    # 4/8 и выше
    CONNTRACK_MAX=1048576
    CONNTRACK_BUCKETS=262144
    SOMAXCONN=32768
    NETDEV_BACKLOG=65536
    SYN_BACKLOG=32768
fi

# --- Корректировка backlog по числу ядер (больше ядер = больше очередей) ---
if [ "$CPU_CORES" -ge 4 ]; then
    NETDEV_BACKLOG=$((NETDEV_BACKLOG * 2))
fi

echo "nf_conntrack_max=$CONNTRACK_MAX"
echo "nf_conntrack_buckets=$CONNTRACK_BUCKETS"
echo "somaxconn=$SOMAXCONN | netdev_backlog=$NETDEV_BACKLOG | syn_backlog=$SYN_BACKLOG"

# nf_conntrack hashsize можно задать ТОЛЬКО через параметр модуля
echo "options nf_conntrack hashsize=$CONNTRACK_BUCKETS" | \
    sudo tee /etc/modprobe.d/nf_conntrack.conf > /dev/null

sudo tee /etc/sysctl.d/99-xanmod.conf > /dev/null <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3

# Conntrack (применятся после загрузки модуля)
net.netfilter.nf_conntrack_max = $CONNTRACK_MAX
net.netfilter.nf_conntrack_tcp_timeout_established = 7440
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# Основные параметры
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $NETDEV_BACKLOG
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

net.ipv4.tcp_max_syn_backlog = $SYN_BACKLOG
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 25

# File descriptors (важно для Xray)
fs.file-max = 1048576
fs.nr_open = 1048576

# UDP буферы (для QUIC/Hysteria)
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

net.ipv4.tcp_no_metrics_save = 1
EOF

# Загружаем модули conntrack перед применением
echo "Загружаем модули netfilter..."
sudo modprobe nf_conntrack 2>/dev/null || true

# Применяем sysctl с игнорированием ошибок
echo "Применяем sysctl..."
sudo sysctl -p /etc/sysctl.d/99-xanmod.conf 2>&1 | grep -v "No such file or directory" || true

# Автозагрузка модулей
echo "nf_conntrack" | sudo tee /etc/modules-load.d/nf-conntrack.conf > /dev/null

# === 4.5 Лимиты файловых дескрипторов ===
echo "Настраиваем лимиты файловых дескрипторов..."

sudo tee /etc/security/limits.d/99-xray.conf > /dev/null <<EOF
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

sudo mkdir -p /etc/systemd/system.conf.d
sudo tee /etc/systemd/system.conf.d/limits.conf > /dev/null <<EOF
[Manager]
DefaultLimitNOFILE=1048576
EOF

# === 5. MSS Clamping через nftables ===
echo "Настраиваем MSS clamping (исправленная версия)..."

sudo tee /etc/nftables.conf > /dev/null <<'EOF'
flush ruleset

table ip mangle {
    chain forward {
        type filter hook forward priority mangle; policy accept;
        tcp flags syn tcp option maxseg size set rt mtu
    }

    chain output {
        type filter hook output priority mangle; policy accept;
        tcp flags syn tcp option maxseg size set rt mtu
    }
}

table ip6 mangle {
    chain forward {
        type filter hook forward priority mangle; policy accept;
        tcp flags syn tcp option maxseg size set rt mtu
    }

    chain output {
        type filter hook output priority mangle; policy accept;
        tcp flags syn tcp option maxseg size set rt mtu
    }
}
EOF

# Применяем конфиг
sudo nft -f /etc/nftables.conf

# Включаем автозапуск
sudo systemctl enable --now nftables 2>/dev/null || true

# === 6. Страховка от CAKE (default_qdisc=fq делает основную работу) ===
echo "Настраиваем страховочный qdisc-сервис..."

sudo tee /usr/local/bin/apply-fq.sh > /dev/null <<'EOT'
#!/bin/bash
# Убираем CAKE если провайдер навязал; default_qdisc=fq делает остальное
for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do
    if tc qdisc show dev "$iface" 2>/dev/null | grep -iq cake; then
        tc qdisc del dev "$iface" root 2>/dev/null || true
        tc qdisc replace dev "$iface" root fq 2>/dev/null || true
    fi
done
EOT
sudo chmod +x /usr/local/bin/apply-fq.sh

sudo tee /etc/systemd/system/tc-fq-optimize.service > /dev/null <<EOF
[Unit]
Description=Remove CAKE qdisc (keep fq via default_qdisc)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/apply-fq.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now tc-fq-optimize.service

echo "→ Сервис tc-fq-optimize создан (упрощённый режим)"

echo "=== Установка завершена! ==="
echo "Перезагрузи систему: reboot"
echo ""
echo "После перезагрузки проверь:"
echo "  uname -r"
echo "  sysctl net.ipv4.tcp_congestion_control"
echo "  tc qdisc show"
echo "  nft list ruleset"
