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

# === 1. Универсальный репозиторий XanMod (fix 404 + multi-OS) ===

echo "Добавляем XanMod (универсальный режим)..."

sudo install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://dl.xanmod.org/archive.key | sudo gpg --dearmor -o /etc/apt/keyrings/xanmod.gpg

REPO_URL="https://deb.xanmod.org"

. /etc/os-release
CODENAME="$VERSION_CODENAME"

add_repo() {
    echo "deb [signed-by=/etc/apt/keyrings/xanmod.gpg] $REPO_URL $1 main" | \
    sudo tee /etc/apt/sources.list.d/xanmod.list > /dev/null
}

FALLBACKS="bookworm jammy bullseye focal"

add_repo "$CODENAME"

if ! sudo apt update >/dev/null 2>&1; then
    echo "⚠️ Основной repo не работает, пробуем fallback..."

    for i in $FALLBACKS; do
        echo "→ пробуем $i"
        sudo rm -f /etc/apt/sources.list.d/xanmod.list
        add_repo "$i"

        if sudo apt update >/dev/null 2>&1; then
            echo "✅ Работает: $i"
            break
        fi
    done
fi

# === 2. Определение версии CPU и установка ===
echo "Определяем уровень CPU..."
curl -fsSLO https://dl.xanmod.org/check_x86-64_psabi.sh
chmod +x check_x86-64_psabi.sh

CPU_LEVEL=$(./check_x86-64_psabi.sh | grep -o 'x86-64-v[0-9]' | head -n1 || echo "v2")

case "$CPU_LEVEL" in
    x86-64-v2) PKG="linux-xanmod-x64v2" ;;
    x86-64-v3|x86-64-v4) PKG="linux-xanmod-x64v3" ;;
    *) PKG="linux-xanmod-x64v2" ;;
esac

echo "Устанавливаем: $PKG ($CPU_LEVEL)"

# Правильная установка — только метапакет!
sudo apt install -y $PKG

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

sudo tee /etc/sysctl.d/99-xanmod.conf > /dev/null <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3

# Conntrack (применятся после загрузки модуля)
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_buckets = 131072
net.netfilter.nf_conntrack_tcp_timeout_established = 7440
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# Основные параметры
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 25
EOF

# Загружаем модули conntrack перед применением
echo "Загружаем модули netfilter..."
sudo modprobe nf_conntrack 2>/dev/null || true
sudo modprobe nf_conntrack_ipv4 2>/dev/null || true
sudo modprobe nf_netlink 2>/dev/null || true

# Применяем sysctl с игнорированием ошибок
echo "Применяем sysctl..."
sudo sysctl -p /etc/sysctl.d/99-xanmod.conf 2>&1 | grep -v "No such file or directory" || true

# Автозагрузка модулей
echo "nf_conntrack" | sudo tee /etc/modules-load.d/nf-conntrack.conf > /dev/null

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

# === 6. Автозапуск fq (упрощённая версия — рекомендуемая) ===
echo "Настраиваем автозапуск qdisc (mq + fq)..."

sudo tee /etc/systemd/system/tc-fq-optimize.service > /dev/null <<EOF
[Unit]
Description=Maintain mq + fq for VLESS Reality + XanMod
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/apply-fq.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo tee /usr/local/bin/apply-fq.sh > /dev/null <<'EOT'
#!/bin/bash
# Простая версия — оставляем mq + fq как есть (самое стабильное решение)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] qdisc maintenance started"

INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$')

for iface in $INTERFACES; do
    echo "→ Проверяем $iface"
    
    # Удаляем только если стоит CAKE (на всякий случай)
    if tc qdisc show dev "$iface" 2>/dev/null | grep -iq cake; then
        echo "   Обнаружен CAKE → заменяем на mq"
        tc qdisc del dev "$iface" root 2>/dev/null || true
        tc qdisc replace dev "$iface" root mq
    else
        echo "   mq/fq уже используется — оставляем как есть"
    fi
done

echo "✅ qdisc maintenance completed (mq + fq)"
EOT

sudo chmod +x /usr/local/bin/apply-fq.sh
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
