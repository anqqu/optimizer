#!/bin/bash
# =============================================================================
#  ⚡ VPS Network Optimizer v2.1
#  Автор: anqqu | https://github.com/anqqu/optimizer
#  Описание: Интерактивное меню для оптимизации сетевого стека и ядра VPS
#  ОС: Debian 11/12, Ubuntu 22.04/24.04 LTS | Виртуализация: KVM
# =============================================================================

# =============================================================================
# ЗАЩИТА ОТ ЗАПУСКА ЧЕРЕЗ ПАЙП (curl | bash)
# =============================================================================
# Проблема: при "curl | bash" stdin занят самим скриптом, а не терминалом.
# Поэтому read мгновенно получает EOF вместо ввода — меню крутится бесконечно.
#
# Решение: [ -t 0 ] проверяет, является ли stdin терминалом (tty).
# Если нет — скачиваем себя во временный файл и перезапускаемся как файл.
# Тогда stdin = терминал, и read работает нормально.
# =============================================================================
if [[ ! -t 0 ]]; then
    _SELF_TMP=$(mktemp /tmp/optimizer-XXXXXX.sh)
    curl -fsSL "https://raw.githubusercontent.com/anqqu/optimizer/main/optimizer.sh" \
         -o "$_SELF_TMP" 2>/dev/null \
         || { echo "Ошибка: не удалось загрузить скрипт"; exit 1; }
    chmod +x "$_SELF_TMP"
    # < /dev/tty явно задаёт stdin для нового процесса = терминал
    # Без этого exec наследует пайп как stdin и цикл повторяется бесконечно
    exec bash "$_SELF_TMP" "$@" < /dev/tty
fi

# --- Цвета для красивого вывода в терминале ---
RED='\033[0;31m'       # Красный — ошибки
GREEN='\033[0;32m'     # Зелёный — успех
YELLOW='\033[1;33m'    # Жёлтый — предупреждения
BLUE='\033[0;34m'      # Синий — информация
CYAN='\033[0;36m'      # Голубой — заголовки
BOLD='\033[1m'         # Жирный текст
RESET='\033[0m'        # Сброс цвета

# --- Вспомогательные функции вывода ---

# ok "текст" — зелёная галочка
ok()   { echo -e "${GREEN}✅ $*${RESET}"; }
# err "текст" — красный крестик
err()  { echo -e "${RED}❌ $*${RESET}"; }
# warn "текст" — жёлтое предупреждение
warn() { echo -e "${YELLOW}⚠️  $*${RESET}"; }
# info "текст" — синяя информация
info() { echo -e "${BLUE}→ $*${RESET}"; }
# sep — разделительная линия
sep()  { echo -e "${CYAN}─────────────────────────────────────────────${RESET}"; }

# =============================================================================
# ПРОВЕРКИ ПЕРЕД ЗАПУСКОМ
# =============================================================================

# Проверяем, что скрипт запущен с правами root (sudo)
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Скрипт необходимо запускать от root или через sudo!"
        echo "  Пример: sudo ./optimizer.sh"
        exit 1
    fi
}

# Проверяем, что ОС — Debian или Ubuntu
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        warn "Не удалось определить ОС. Продолжаем на свой страх и риск..."
        return
    fi
    # Читаем ID дистрибутива из стандартного файла
    source /etc/os-release
    if [[ "$ID" != "debian" && "$ID" != "ubuntu" && "$ID_LIKE" != *"debian"* ]]; then
        warn "Скрипт предназначен для Debian/Ubuntu. Ваша ОС: $PRETTY_NAME"
        warn "Продолжение может привести к ошибкам."
        echo ""
        read -rp "Продолжить всё равно? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { info "Отменено."; exit 0; }
    fi
}

# =============================================================================
# ФУНКЦИЯ 1 — Обновление пакетов
# =============================================================================
fn_update() {
    sep
    echo -e "${BOLD}📦 Обновление пакетов системы${RESET}"
    sep

    # ==========================================================================
    # ВАЖНО: DEBIAN_FRONTEND=noninteractive запрещает apt показывать диалоги.
    # Это решает проблему когда apt спрашивает "выбери язык" или "что делать
    # с изменёнными конфиг-файлами" — теперь он берёт дефолты автоматически.
    # Dpkg::Options::="--force-confdef"  — брать значение по умолчанию
    # Dpkg::Options::="--force-confold"  — оставлять старый конфиг при конфликте
    # ==========================================================================
    export DEBIAN_FRONTEND=noninteractive

    # Сокращение: APT_OPTS используем везде чтобы не повторяться
    APT_OPTS=(
        -y
        -o Dpkg::Options::="--force-confdef"
        -o Dpkg::Options::="--force-confold"
        -o Acquire::Retries=3
    )

    # ==========================================================================
    # АВТОСМЕНА ЗЕРКАЛА: если основной сервер недоступен — пробуем резервные.
    # Определяем ОС и выбираем список зеркал под неё.
    # ==========================================================================

    # Читаем ID дистрибутива (debian / ubuntu)
    OS_ID=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')

    if [[ "$OS_ID" == "ubuntu" ]]; then
        # Зеркала Ubuntu — пробуем в порядке приоритета
        MIRRORS=(
            "http://archive.ubuntu.com/ubuntu"
            "http://de.archive.ubuntu.com/ubuntu"
            "http://ru.archive.ubuntu.com/ubuntu"
            "http://fr.archive.ubuntu.com/ubuntu"
            "http://mirror.yandex.ru/ubuntu"
            "http://mirrors.aliyun.com/ubuntu"
        )
        SOURCES_FILE="/etc/apt/sources.list"
    else
        # Зеркала Debian — пробуем в порядке приоритета
        MIRRORS=(
            "http://deb.debian.org/debian"
            "http://ftp.de.debian.org/debian"
            "http://ftp.ru.debian.org/debian"
            "http://ftp.fr.debian.org/debian"
            "http://mirror.yandex.ru/debian"
            "http://mirrors.aliyun.com/debian"
        )
        SOURCES_FILE="/etc/apt/sources.list"
    fi

    # --- Проверяем текущее зеркало из sources.list ---
    # Берём первый http(s)-адрес из файла как "основное зеркало"
    CURRENT_MIRROR=$(grep -m1 '^deb http' "$SOURCES_FILE" 2>/dev/null | awk '{print $2}' | \
                     sed 's|/[^/]*$||' | head -n1)

    info "Текущее зеркало: ${CURRENT_MIRROR:-неизвестно}"

    # Проверяем доступность через HTTP HEAD (быстро, без скачивания)
    MIRROR_OK=false
    if [[ -n "$CURRENT_MIRROR" ]] && \
       curl -fsI --connect-timeout 5 "$CURRENT_MIRROR" > /dev/null 2>&1; then
        MIRROR_OK=true
        ok "Зеркало доступно: $CURRENT_MIRROR"
    else
        warn "Основное зеркало недоступно или не определено. Ищем рабочее..."
        for mirror in "${MIRRORS[@]}"; do
            info "→ проверяем $mirror"
            if curl -fsI --connect-timeout 5 "$mirror" > /dev/null 2>&1; then
                ok "Найдено рабочее зеркало: $mirror"

                # Делаем резервную копию sources.list перед изменением
                cp "$SOURCES_FILE" "${SOURCES_FILE}.bak.$(date +%Y%m%d%H%M%S)"
                info "Резервная копия сохранена: ${SOURCES_FILE}.bak.*"

                # Заменяем все вхождения старого зеркала на новое
                if [[ -n "$CURRENT_MIRROR" ]]; then
                    # Экранируем / для sed
                    OLD_ESC=$(echo "$CURRENT_MIRROR" | sed 's|/|\\/|g')
                    NEW_ESC=$(echo "$mirror"          | sed 's|/|\\/|g')
                    sed -i "s|${OLD_ESC}|${NEW_ESC}|g" "$SOURCES_FILE"
                    ok "sources.list обновлён: $CURRENT_MIRROR → $mirror"
                else
                    warn "Не удалось определить текущее зеркало для замены."
                    warn "Отредактируй $SOURCES_FILE вручную."
                fi

                MIRROR_OK=true
                break
            fi
        done
    fi

    if [ "$MIRROR_OK" = false ]; then
        err "Нет доступных зеркал! Проверь интернет-соединение."
        warn "Попробуем apt update всё равно — может сработает через кэш..."
    fi

    # ==========================================================================
    # APT UPDATE — обновление списка пакетов
    # ==========================================================================
    info "Запускаем apt update..."
    # Флаг -o Acquire::Retries=3 — повторить загрузку 3 раза при ошибке сети
    if DEBIAN_FRONTEND=noninteractive apt-get update \
       -o Acquire::Retries=3 \
       -o Acquire::http::Timeout=30 2>&1 | \
       grep -v '^W:' | grep -v 'translation' | grep -v 'Ign:'; then
        ok "Список пакетов обновлён"
    else
        warn "apt update завершился с предупреждениями (обычно не критично)"
    fi

    # ==========================================================================
    # APT UPGRADE — установка обновлений без интерактивных вопросов
    # ==========================================================================
    info "Запускаем apt upgrade (без интерактивных диалогов)..."
    # Весь вывод debconf подавляем через DEBIAN_FRONTEND=noninteractive.
    # force-confdef/confold = не спрашивать про конфиг-файлы, брать старые.
    if DEBIAN_FRONTEND=noninteractive apt-get upgrade "${APT_OPTS[@]}" 2>&1 | \
       grep -v '^debconf:' | grep -v 'locale-gen'; then
        ok "Пакеты обновлены успешно"
    else
        warn "apt upgrade завершился с предупреждениями"
    fi

    # Чистим ненужные пакеты (осиротевшие зависимости)
    info "Очищаем ненужные пакеты (autoremove)..."
    DEBIAN_FRONTEND=noninteractive apt-get autoremove "${APT_OPTS[@]}" 2>/dev/null || true

    # ==========================================================================
    # ЗАВИСИМОСТИ — всё что нужно для XanMod и остальных шагов
    # ==========================================================================
    info "Устанавливаем зависимости (curl, gnupg, dkms, bc...)..."
    # bc нужен для расчёта размера swap в дробных ГБ
    DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" \
        curl gnupg lsb-release ca-certificates \
        dkms libelf-dev build-essential bc
    ok "Зависимости установлены"

    # Сбрасываем переменную обратно чтобы не влиять на другие части скрипта
    export DEBIAN_FRONTEND=dialog
}

# =============================================================================
# ФУНКЦИЯ 2 — Установка XanMod + BBRv3 + TFO
# =============================================================================
fn_xanmod() {
    sep
    echo -e "${BOLD}🚀 Установка XanMod Kernel + BBRv3 + TFO${RESET}"
    sep

    # --- Добавляем репозиторий XanMod ---
    info "Добавляем ключ и репозиторий XanMod..."
    install -m 0755 -d /etc/apt/keyrings

    # Скачиваем и конвертируем GPG-ключ
    curl -fsSL https://dl.xanmod.org/archive.key | gpg --dearmor -o /etc/apt/keyrings/xanmod.gpg

    REPO_URL="http://deb.xanmod.org"
    # lsb_release -sc возвращает кодовое имя ОС (например bookworm, noble)
    CODENAME=$(lsb_release -sc)
    info "Определён дистрибутив: $CODENAME"

    # Проверяем, существует ли репозиторий для нашей версии ОС
    if curl -fsI "$REPO_URL/dists/$CODENAME/Release" >/dev/null 2>&1; then
        echo "deb [signed-by=/etc/apt/keyrings/xanmod.gpg] $REPO_URL $CODENAME main" | \
            tee /etc/apt/sources.list.d/xanmod.list > /dev/null
        apt update
    else
        warn "Репозиторий XanMod не поддерживает '$CODENAME', ищем совместимый..."
        # Перебираем известные кодовые имена как запасной вариант
        for c in bookworm trixie sid noble plucky questing resolute faye gigi wilma xia zara zena; do
            info "→ пробуем: $c"
            if curl -fsI "$REPO_URL/dists/$c/Release" >/dev/null 2>&1; then
                echo "deb [signed-by=/etc/apt/keyrings/xanmod.gpg] $REPO_URL $c main" | \
                    tee /etc/apt/sources.list.d/xanmod.list > /dev/null
                apt update
                ok "Используем репозиторий: $c"
                break
            fi
        done
    fi

    # --- Определяем уровень CPU (v2/v3/v4) ---
    info "Определяем уровень x86-64 вашего CPU..."
    # Скачиваем скрипт проверки в /tmp, а не в рабочую директорию
    curl -fsSLo /tmp/check_x86-64_psabi.sh https://dl.xanmod.org/check_x86-64_psabi.sh
    chmod +x /tmp/check_x86-64_psabi.sh

    # Получаем результат и берём первое совпадение (например x86-64-v3)
    CPU_LEVEL=$(/tmp/check_x86-64_psabi.sh | grep -o 'x86-64-v[0-9]' | head -n1 || echo "v2")
    info "Ваш CPU: $CPU_LEVEL"

    # --- Выбираем подходящий пакет XanMod под CPU ---
    if [[ "$CPU_LEVEL" == "x86-64-v4" || "$CPU_LEVEL" == "x86-64-v3" ]]; then
        CANDIDATES=(linux-xanmod-x64v3 linux-xanmod-lts-x64v3 linux-xanmod-edge-x64v3)
    elif [[ "$CPU_LEVEL" == "x86-64-v2" ]]; then
        CANDIDATES=(linux-xanmod-x64v2 linux-xanmod-lts-x64v2 linux-xanmod-edge-x64v2)
    else
        CANDIDATES=(linux-xanmod-x64v1 linux-xanmod-lts-x64v1)
    fi

    # Перебираем кандидатов и берём первый доступный в репозитории
    PKG=""
    for p in "${CANDIDATES[@]}"; do
        if apt-cache search "^$p$" | grep -q "$p"; then
            PKG="$p"
            break
        fi
    done

    if [[ -z "$PKG" ]]; then
        err "Не найден ни один XanMod пакет в репозитории!"
        info "Доступные пакеты xanmod:"
        apt-cache search xanmod
        return 1
    fi

    info "Выбран пакет: $PKG"

    # Устанавливаем, при неудаче пробуем запасные варианты
    if apt install -y "$PKG"; then
        ok "XanMod ядро установлено: $PKG"
    else
        warn "Не удалось установить $PKG, пробуем запасные варианты..."
        INSTALLED=0
        for ALT in linux-xanmod-x64v2 linux-xanmod-x64v1 linux-xanmod-edge-x64v3 linux-xanmod-edge-x64v2 linux-xanmod-edge; do
            if apt-cache search "^$ALT$" | grep -q "$ALT"; then
                info "Пробуем: $ALT"
                if apt install -y "$ALT"; then
                    ok "Установлен запасной вариант: $ALT"
                    INSTALLED=1
                    break
                fi
            fi
        done
        [[ $INSTALLED -eq 0 ]] && { err "Не удалось установить ни одного XanMod пакета"; return 1; }
    fi

    ok "XanMod ядро установлено!"
    warn "Перезагрузка потребуется для загрузки нового ядра."
    info "Следующий шаг: включи BBRv3 (пункт 3) и TFO (пункт 4)."
}

# =============================================================================
# ФУНКЦИЯ 3 — Включение BBRv3 (алгоритм управления перегрузкой TCP)
# =============================================================================
fn_bbr() {
    sep
    echo -e "${BOLD}📡 Включение BBRv3 + fq qdisc${RESET}"
    sep

    # BBR (Bottleneck Bandwidth and Round-trip propagation time) — умный алгоритм
    # который следит за пропускной способностью канала и RTT, а не за потерями.
    # Намного лучше стандартного CUBIC для высоких нагрузок и нестабильных каналов.
    # fq (Fair Queue) — оптимальный qdisc-партнёр для BBR на серверах.

    info "Применяем BBRv3 + fq..."
    sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true

    # Сохраняем в файл чтобы применялось после перезагрузки
    # Создаём файл если его нет, или обновляем существующие строки
    SYSCTL_FILE="/etc/sysctl.d/99-xanmod.conf"
    if [[ -f "$SYSCTL_FILE" ]]; then
        # Обновляем строки если уже есть, или добавляем в конец
        grep -q 'default_qdisc' "$SYSCTL_FILE" || \
            echo "net.core.default_qdisc = fq" >> "$SYSCTL_FILE"
        grep -q 'tcp_congestion_control' "$SYSCTL_FILE" || \
            echo "net.ipv4.tcp_congestion_control = bbr" >> "$SYSCTL_FILE"
        # Обновляем значения если строки уже есть
        sed -i 's/^net.core.default_qdisc\s*=.*/net.core.default_qdisc = fq/' "$SYSCTL_FILE"
        sed -i 's/^net.ipv4.tcp_congestion_control\s*=.*/net.ipv4.tcp_congestion_control = bbr/' "$SYSCTL_FILE"
    else
        # Файл ещё не создан — пишем базовый блок
        tee "$SYSCTL_FILE" > /dev/null <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    fi

    # Проверяем результат
    ACTUAL=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$ACTUAL" == "bbr" ]]; then
        ok "BBRv3 активен! (алгоритм: $ACTUAL, qdisc: fq)"
    else
        warn "BBRv3 применён в конфиге, но активируется после перезагрузки."
        info "Текущий алгоритм: ${ACTUAL:-неизвестно}"
    fi
}

# =============================================================================
# ФУНКЦИЯ 4 — Включение TCP Fast Open (TFO)
# =============================================================================
fn_tfo() {
    sep
    echo -e "${BOLD}⚡ Включение TCP Fast Open (TFO)${RESET}"
    sep

    # TFO позволяет передавать данные уже в SYN-пакете при повторных соединениях.
    # Это сокращает задержку на 1 RTT (round-trip time) — очень заметно на высоком пинге.
    # Значение 3 = включить и для клиента (1) и для сервера (2): 1+2=3.

    sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null || true

    SYSCTL_FILE="/etc/sysctl.d/99-xanmod.conf"
    if [[ -f "$SYSCTL_FILE" ]]; then
        grep -q 'tcp_fastopen' "$SYSCTL_FILE" || \
            echo "net.ipv4.tcp_fastopen = 3" >> "$SYSCTL_FILE"
        sed -i 's/^net.ipv4.tcp_fastopen\s*=.*/net.ipv4.tcp_fastopen = 3/' "$SYSCTL_FILE"
    else
        echo "net.ipv4.tcp_fastopen = 3" >> "$SYSCTL_FILE"
    fi

    ACTUAL=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)
    if [[ "$ACTUAL" == "3" ]]; then
        ok "TFO активен! (режим: 3 = клиент + сервер)"
    else
        warn "TFO применён в конфиге. Текущее значение: ${ACTUAL:-0}"
    fi
}

# =============================================================================
# ФУНКЦИЯ 3 — Настройка sysctl (conntrack, буферы сети, лимиты)
# =============================================================================
fn_sysctl() {
    sep
    echo -e "${BOLD}🔧 Настройка sysctl (conntrack, буферы, лимиты)${RESET}"
    sep

    # --- Автоопределение RAM и CPU для подбора оптимальных значений ---
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc)
    info "RAM: ${TOTAL_RAM_MB} МБ | CPU ядра: ${CPU_CORES}"

    # Подбираем значения conntrack и backlog в зависимости от RAM
    if [ "$TOTAL_RAM_MB" -le 1024 ]; then
        # Слабые ноды: 1 ядро / 1 ГБ
        CONNTRACK_MAX=131072;  CONNTRACK_BUCKETS=32768
        SOMAXCONN=4096;        NETDEV_BACKLOG=8192;  SYN_BACKLOG=4096
    elif [ "$TOTAL_RAM_MB" -le 2048 ]; then
        # 1-2 ГБ RAM
        CONNTRACK_MAX=262144;  CONNTRACK_BUCKETS=65536
        SOMAXCONN=8192;        NETDEV_BACKLOG=16384; SYN_BACKLOG=8192
    elif [ "$TOTAL_RAM_MB" -le 4096 ]; then
        # 2-4 ГБ RAM
        CONNTRACK_MAX=524288;  CONNTRACK_BUCKETS=131072
        SOMAXCONN=16384;       NETDEV_BACKLOG=32768; SYN_BACKLOG=16384
    else
        # 4+ ГБ RAM — максимальные значения
        CONNTRACK_MAX=1048576; CONNTRACK_BUCKETS=262144
        SOMAXCONN=32768;       NETDEV_BACKLOG=65536; SYN_BACKLOG=32768
    fi

    # Если ядер 4 и больше — удваиваем очередь сетевых пакетов
    [ "$CPU_CORES" -ge 4 ] && NETDEV_BACKLOG=$((NETDEV_BACKLOG * 2))

    info "conntrack_max=$CONNTRACK_MAX | somaxconn=$SOMAXCONN | netdev_backlog=$NETDEV_BACKLOG"

    # hashsize задаётся только через параметр модуля (не через sysctl напрямую)
    echo "options nf_conntrack hashsize=$CONNTRACK_BUCKETS" | \
        tee /etc/modprobe.d/nf_conntrack.conf > /dev/null

    # Записываем все sysctl настройки в отдельный файл (применяются при загрузке)
    tee /etc/sysctl.d/99-xanmod.conf > /dev/null <<EOF
# --- BBRv3 + очередь пакетов ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# TFO=3: включить TCP Fast Open для клиента и сервера
net.ipv4.tcp_fastopen = 3

# --- Conntrack (таблица соединений NAT/firewall) ---
net.netfilter.nf_conntrack_max = $CONNTRACK_MAX
# Таймаут established соединений (2 часа = 7440 сек)
net.netfilter.nf_conntrack_tcp_timeout_established = 7440
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# --- Размеры очередей ---
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $NETDEV_BACKLOG
net.ipv4.tcp_max_syn_backlog = $SYN_BACKLOG

# --- Буферы TCP (rmem/wmem: минимум, по умолчанию, максимум) ---
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# --- Оптимизация поведения TCP ---
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 25
net.ipv4.tcp_no_metrics_save = 1

# --- Лимиты файловых дескрипторов (важно для Xray/прокси) ---
fs.file-max = 1048576
fs.nr_open = 1048576

# --- UDP буферы (для QUIC/Hysteria) ---
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
EOF

    # Загружаем модуль conntrack перед применением (иначе часть параметров недоступна)
    info "Загружаем модуль nf_conntrack..."
    modprobe nf_conntrack 2>/dev/null || true

    # Применяем настройки сразу (без перезагрузки), игнорируем недоступные параметры
    info "Применяем sysctl..."
    sysctl -p /etc/sysctl.d/99-xanmod.conf 2>&1 | grep -v "No such file" || true

    # Автозагрузка модуля conntrack при старте системы
    echo "nf_conntrack" | tee /etc/modules-load.d/nf-conntrack.conf > /dev/null

    # --- Лимиты файловых дескрипторов через PAM (limits.d) ---
    info "Настраиваем лимиты файловых дескрипторов (nofile)..."
    tee /etc/security/limits.d/99-xray.conf > /dev/null <<EOF
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    # Лимиты для systemd-сервисов (отдельный механизм от PAM)
    mkdir -p /etc/systemd/system.conf.d
    tee /etc/systemd/system.conf.d/limits.conf > /dev/null <<EOF
[Manager]
DefaultLimitNOFILE=1048576
EOF

    ok "sysctl настройки применены и сохранены в /etc/sysctl.d/99-xanmod.conf"
}

# =============================================================================
# ВСПОМОГАТЕЛЬНАЯ ФУНКЦИЯ — Определение реального Path MTU бинарным поиском
# =============================================================================
# Принцип: пинг с флагом "не фрагментировать" (-M do) и бинарный поиск размера.
# Если пакет прошёл — MTU >= размера. Если ошибка — MTU < размера.
# За ~10 итераций находим точное значение.
# Результат сохраняется в глобальных переменных DETECTED_MTU, MSS_V4, MSS_V6.
fn_detect_mtu() {
    local target="${1:-8.8.8.8}"
    local low=576    # Минимальный MTU по RFC 791
    local high=1500  # Стандартный Ethernet MTU
    local best=$low

    info "Бинарный поиск Path MTU (цель: $target)..."
    info "Диапазон: ${low}–${high} байт. Займёт ~15 секунд..."

    while [ $((high - low)) -gt 1 ]; do
        local mid=$(( (low + high) / 2 ))
        # ping -M do = Don't Fragment | -s = данные ICMP (MTU - 28 байт заголовков)
        # -c 2 = два пакета для надёжности | -W 3 = таймаут 3 секунды
        local data_size=$(( mid - 28 ))
        if ping -M do -s "$data_size" -c 2 -W 3 "$target" > /dev/null 2>&1; then
            best=$mid   # Пакет прошёл — запоминаем, ищем больше
            low=$mid
        else
            high=$mid   # Пакет не прошёл — ищем меньше
        fi
    done

    [ "$best" -lt 576 ] && { warn "MTU ($best) слишком мал, используем 1500"; best=1500; }

    # Экспортируем результаты в глобальные переменные
    DETECTED_MTU=$best
    # MSS = MTU минус заголовки: IPv4 = 20+20=40, IPv6 = 40+20=60
    MSS_V4=$(( DETECTED_MTU - 40 ))
    MSS_V6=$(( DETECTED_MTU - 60 ))

    ok "Path MTU: ${DETECTED_MTU} байт | MSS IPv4: ${MSS_V4} | MSS IPv6: ${MSS_V6}"
}

# =============================================================================
# ФУНКЦИЯ 4 — MSS Clamping через nftables (IPv4 + IPv6)
# =============================================================================
fn_mss() {
    sep
    echo -e "${BOLD}🔒 Настройка MSS Clamping (nftables)${RESET}"
    sep

    # MSS Clamping — ограничивает размер TCP-сегмента.
    # Решает "path MTU black hole" — потери пакетов из-за разного MTU
    # на участках пути (особенно актуально для VPN/туннелей).

    echo ""
    echo -e "  ${CYAN}Режим MSS Clamping:${RESET}"
    echo -e "  ${GREEN}1)${RESET} 🤖 Автоматически ${YELLOW}(rt mtu — из таблицы маршрутов ядра)${RESET}"
    echo -e "  ${GREEN}2)${RESET} 🔍 Адаптивный ${YELLOW}(бинарный поиск реального Path MTU)${RESET}"
    echo -e "  ${GREEN}3)${RESET} ✏️  Ввести MTU вручную ${YELLOW}(например: 1420 WireGuard, 1492 PPPoE)${RESET}"
    echo ""
    read -rp "  Выбери режим [1/2/3, Enter=1]: " mss_choice
    mss_choice="${mss_choice:-1}"

    USE_RT_MTU=true
    DETECTED_MTU=""
    MSS_V4=""
    MSS_V6=""

    case "$mss_choice" in
        2)
            echo ""
            read -rp "  IP для пинга [Enter = 8.8.8.8]: " ping_target
            ping_target="${ping_target:-8.8.8.8}"

            # Проверяем достижимость хоста перед поиском
            if ! ping -c 1 -W 3 "$ping_target" > /dev/null 2>&1; then
                warn "Хост $ping_target недостижим, пробуем 1.1.1.1..."
                ping_target="1.1.1.1"
            fi

            if ping -c 1 -W 3 "$ping_target" > /dev/null 2>&1; then
                fn_detect_mtu "$ping_target"
                USE_RT_MTU=false
            else
                warn "Не удалось достучаться ни до одного хоста. Используем rt mtu."
                USE_RT_MTU=true
            fi
            ;;
        3)
            echo ""
            read -rp "  Введи MTU (576–9000): " manual_mtu
            if [[ "$manual_mtu" =~ ^[0-9]+$ ]] && \
               [ "$manual_mtu" -ge 576 ] && [ "$manual_mtu" -le 9000 ]; then
                DETECTED_MTU="$manual_mtu"
                MSS_V4=$(( manual_mtu - 40 ))
                MSS_V6=$(( manual_mtu - 60 ))
                ok "MTU: ${DETECTED_MTU} | MSS IPv4: ${MSS_V4} | MSS IPv6: ${MSS_V6}"
                USE_RT_MTU=false
            else
                warn "Некорректное значение. Используем автоматический режим."
                USE_RT_MTU=true
            fi
            ;;
        *)
            info "Автоматический режим (rt mtu из таблицы маршрутов)"
            USE_RT_MTU=true
            ;;
    esac

    echo ""
    info "Записываем конфигурацию nftables..."

    if [ "$USE_RT_MTU" = true ]; then
        # Динамический: MSS берётся из таблицы маршрутов ядра
        tee /etc/nftables.conf > /dev/null <<'EOF'
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
    else
        # Фиксированный: точные значения MSS из детектирования/ввода
        tee /etc/nftables.conf > /dev/null <<EOF
flush ruleset

# MSS Clamping: MTU=${DETECTED_MTU}, MSS IPv4=${MSS_V4}, MSS IPv6=${MSS_V6}
table ip mangle {
    chain forward {
        type filter hook forward priority mangle; policy accept;
        tcp flags syn tcp option maxseg size set ${MSS_V4}
    }
    chain output {
        type filter hook output priority mangle; policy accept;
        tcp flags syn tcp option maxseg size set ${MSS_V4}
    }
}

table ip6 mangle {
    chain forward {
        type filter hook forward priority mangle; policy accept;
        tcp flags syn tcp option maxseg size set ${MSS_V6}
    }
    chain output {
        type filter hook output priority mangle; policy accept;
        tcp flags syn tcp option maxseg size set ${MSS_V6}
    }
}
EOF
    fi

    if nft -f /etc/nftables.conf; then
        ok "Правила nftables применены"
    else
        err "Ошибка при применении nftables конфига"
        return 1
    fi

    systemctl enable --now nftables 2>/dev/null || true
    ok "MSS Clamping активен (IPv4 + IPv6)"
}

# =============================================================================
# ФУНКЦИЯ 5 — Отключение CAKE qdisc → замена на fq
# =============================================================================
fn_cake() {
    sep
    echo -e "${BOLD}📦 Отключение CAKE → замена на fq qdisc${RESET}"
    sep

    # CAKE — это qdisc (дисциплина очереди пакетов).
    # Она хороша для home-роутеров, но на VPS с BBR использование CAKE
    # избыточно и может снижать производительность.
    # fq (Fair Queue) + BBR = оптимальная связка для серверов.

    info "Проверяем все сетевые интерфейсы..."
    # Получаем список интерфейсов, исключая loopback (lo)
    INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$')

    for iface in $INTERFACES; do
        CURRENT_QDISC=$(tc qdisc show dev "$iface" 2>/dev/null | head -n1)

        if tc qdisc show dev "$iface" 2>/dev/null | grep -iq cake; then
            info "$iface: обнаружен CAKE → заменяем на fq"
            tc qdisc del dev "$iface" root 2>/dev/null || true
            tc qdisc replace dev "$iface" root fq
            ok "$iface: переключён на fq"
        elif ! echo "$CURRENT_QDISC" | grep -Eq 'fq|fq_codel'; then
            info "$iface: текущий qdisc '${CURRENT_QDISC:-none}' → ставим fq"
            tc qdisc replace dev "$iface" root fq
            ok "$iface: переключён на fq"
        else
            ok "$iface: уже использует fq/fq_codel (всё хорошо)"
        fi
    done

    # Создаём systemd-сервис для автоматического применения fq после перезагрузки
    info "Создаём systemd-сервис для автозапуска..."

    tee /usr/local/bin/apply-fq.sh > /dev/null <<'EOT'
#!/bin/bash
# Убираем CAKE если провайдер навязал; default_qdisc=fq делает остальное
for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do
    if tc qdisc show dev "$iface" 2>/dev/null | grep -iq cake; then
        tc qdisc del dev "$iface" root 2>/dev/null || true
        tc qdisc replace dev "$iface" root fq 2>/dev/null || true
    fi
done
EOT
    chmod +x /usr/local/bin/apply-fq.sh

    tee /etc/systemd/system/tc-fq-optimize.service > /dev/null <<EOF
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

    systemctl daemon-reload
    systemctl enable --now tc-fq-optimize.service
    ok "Сервис tc-fq-optimize создан и включён"
}

# =============================================================================
# ФУНКЦИЯ 6 — Создание Swap-файла (размер на выбор)
# =============================================================================
fn_swap() {
    sep
    echo -e "${BOLD}💾 Создание Swap-файла${RESET}"
    sep

    # Swap — «виртуальная RAM» на диске. Нужен когда RAM заканчивается,
    # чтобы система не падала, а использовала диск как запасную память.

    # Показываем свободное место на диске, чтобы помочь с выбором размера
    echo ""
    echo -e "  ${CYAN}Свободное место на диске:${RESET}"
    df -h / | awk 'NR==2 {printf "  Всего: %s | Занято: %s | Свободно: %s\n", $2, $3, $4}'
    echo ""
    echo -e "  ${CYAN}Выбери размер Swap:${RESET}"
    echo -e "  ${GREEN}1)${RESET} 512 МБ  ${YELLOW}— минимум, для VPS с 1+ ГБ RAM${RESET}"
    echo -e "  ${GREEN}2)${RESET} 1 ГБ    ${YELLOW}— рекомендуется для 1-2 ГБ RAM${RESET}"
    echo -e "  ${GREEN}3)${RESET} 2 ГБ    ${YELLOW}— для 2-4 ГБ RAM${RESET}"
    echo -e "  ${GREEN}4)${RESET} 4 ГБ    ${YELLOW}— для 4+ ГБ RAM${RESET}"
    echo -e "  ${GREEN}5)${RESET} ✏️  Свой размер ${YELLOW}(введи в МБ)${RESET}"
    echo ""
    read -rp "  Выбери размер [1-5, Enter=2]: " swap_choice
    swap_choice="${swap_choice:-2}"

    # Определяем размер в МБ и метку для вывода
    case "$swap_choice" in
        1) SWAP_MB=512;  SWAP_LABEL="512 МБ"  ;;
        2) SWAP_MB=1024; SWAP_LABEL="1 ГБ"    ;;
        3) SWAP_MB=2048; SWAP_LABEL="2 ГБ"    ;;
        4) SWAP_MB=4096; SWAP_LABEL="4 ГБ"    ;;
        5)
            echo ""
            read -rp "  Введи размер в МБ (например 768, 3072): " custom_mb
            # Проверяем что введено число от 128 до 32768 МБ (32 ГБ)
            if [[ "$custom_mb" =~ ^[0-9]+$ ]] && \
               [ "$custom_mb" -ge 128 ] && [ "$custom_mb" -le 32768 ]; then
                SWAP_MB=$custom_mb
                # Красиво отображаем в ГБ если больше 1024 МБ
                if [ "$SWAP_MB" -ge 1024 ]; then
                    SWAP_LABEL="$(echo "scale=1; $SWAP_MB/1024" | bc) ГБ"
                else
                    SWAP_LABEL="${SWAP_MB} МБ"
                fi
            else
                warn "Некорректный размер. Используем 1 ГБ по умолчанию."
                SWAP_MB=1024
                SWAP_LABEL="1 ГБ"
            fi
            ;;
        *)
            warn "Некорректный выбор. Используем 1 ГБ."
            SWAP_MB=1024
            SWAP_LABEL="1 ГБ"
            ;;
    esac

    info "Создаём Swap: ${SWAP_LABEL} (${SWAP_MB} МБ)"

    # Деактивируем старый swap перед пересозданием
    info "Деактивируем старый swap (если есть)..."
    swapoff /swapfile 2>/dev/null || true

    # fallocate — быстрое выделение блока на диске (мгновенно, без записи нулей)
    if fallocate -l "${SWAP_MB}M" /swapfile; then
        ok "Файл /swapfile выделен"
    else
        # Некоторые ФС (например btrfs) не поддерживают fallocate для swap
        warn "fallocate не поддерживается, используем dd (медленнее)..."
        dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=progress
    fi

    # Права 600 = только root может читать/писать (обязательно для swap!)
    chmod 600 /swapfile
    mkswap /swapfile    # Форматируем файл как swap-раздел
    swapon /swapfile    # Включаем swap прямо сейчас (без перезагрузки)

    # Добавляем в /etc/fstab для автозапуска после перезагрузки
    if ! grep -qE '^\s*/swapfile\s' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
        ok "Запись в /etc/fstab добавлена (swap будет активен после reboot)"
    else
        info "Запись в /etc/fstab уже существует"
    fi

    echo ""
    swapon --show
    free -h
    ok "Swap ${SWAP_LABEL} активен!"
}

# =============================================================================
# ФУНКЦИЯ 9 — Отключение / включение IPv6
# =============================================================================
fn_ipv6() {
    sep
    echo -e "${BOLD}🌐 Управление IPv6${RESET}"
    sep

    # Проверяем текущее состояние: 1 = отключён, 0 = включён
    CURRENT=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")

    if [[ "$CURRENT" == "1" ]]; then
        echo -e "  Статус: ${RED}IPv6 отключён${RESET}"
        echo ""
        read -rp "  Включить IPv6 обратно? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 2>/dev/null || true
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 2>/dev/null || true
            sysctl -w net.ipv6.conf.lo.disable_ipv6=0 2>/dev/null || true
            # Удаляем строки из sysctl-файла
            sed -i '/disable_ipv6/d' /etc/sysctl.d/99-xanmod.conf 2>/dev/null || true
            ok "IPv6 включён"
        else
            info "Отменено."
        fi
    else
        echo -e "  Статус: ${GREEN}IPv6 включён${RESET}"
        echo ""
        echo -e "  ${YELLOW}Зачем отключать IPv6?${RESET}"
        echo "  • Некоторые прокси/Xray конфиги работают только через IPv4"
        echo "  • Исключает утечки через IPv6 если VPN не поддерживает его"
        echo "  • Упрощает отладку сетевых проблем"
        echo ""
        read -rp "  Отключить IPv6? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            # Применяем сразу для всех интерфейсов
            sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
            sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
            sysctl -w net.ipv6.conf.lo.disable_ipv6=1 2>/dev/null || true
            # Сохраняем постоянно
            SYSCTL_FILE="/etc/sysctl.d/99-xanmod.conf"
            # Удаляем старые строки чтобы не дублировать
            sed -i '/disable_ipv6/d' "$SYSCTL_FILE" 2>/dev/null || true
            cat >> "$SYSCTL_FILE" <<EOF
# Отключение IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
            ok "IPv6 отключён (применится и после перезагрузки)"
        else
            info "Отменено."
        fi
    fi
}

# =============================================================================
# ВСПОМОГАТЕЛЬНАЯ ФУНКЦИЯ — Компактная строка статуса для шапки меню
# =============================================================================
# Возвращает строку вида: XanMod ✅  BBR ✅  TFO ✅  fq ✅  MSS ✅  Swap: нет  IPv6: вкл
fn_show_statusbar() {
    # --- XanMod ---
    if uname -r 2>/dev/null | grep -qi xanmod; then
        S_XANMOD="${GREEN}✅ XanMod${RESET}"
    else
        S_XANMOD="${RED}❌ XanMod${RESET}"
    fi

    # --- BBR ---
    if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q '^bbr'; then
        S_BBR="${GREEN}✅ BBR${RESET}"
    else
        S_BBR="${RED}❌ BBR${RESET}"
    fi

    # --- TFO ---
    TFO_VAL=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "0")
    if [[ "$TFO_VAL" == "3" ]]; then
        S_TFO="${GREEN}✅ TFO${RESET}"
    else
        S_TFO="${RED}❌ TFO${RESET}"
    fi

    # --- fq qdisc ---
    if sysctl -n net.core.default_qdisc 2>/dev/null | grep -qE '^fq$'; then
        S_FQ="${GREEN}✅ fq${RESET}"
    else
        S_FQ="${RED}❌ fq${RESET}"
    fi

    # --- MSS Clamping (nftables) ---
    if nft list ruleset 2>/dev/null | grep -q mangle; then
        S_MSS="${GREEN}✅ MSS${RESET}"
    else
        S_MSS="${RED}❌ MSS${RESET}"
    fi

    # --- Swap ---
    SWAP_INFO=$(swapon --show=SIZE,NAME --noheadings 2>/dev/null | awk '/swapfile/{print $1}')
    if [[ -n "$SWAP_INFO" ]]; then
        S_SWAP="${GREEN}Swap:${SWAP_INFO}${RESET}"
    else
        S_SWAP="${YELLOW}Swap:нет${RESET}"
    fi

    # --- IPv6 ---
    IPV6_DIS=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    if [[ "$IPV6_DIS" == "1" ]]; then
        S_IPV6="${YELLOW}IPv6:выкл${RESET}"
    else
        S_IPV6="${GREEN}IPv6:вкл${RESET}"
    fi

    echo -e "  ${S_XANMOD}  ${S_BBR}  ${S_TFO}  ${S_FQ}  ${S_MSS}  ${S_SWAP}  ${S_IPV6}"
}

# =============================================================================
# ФУНКЦИЯ 10 — Краткая проверка статуса
# =============================================================================
fn_status() {
    sep
    echo -e "${BOLD}📊 Статус оптимизации${RESET}"
    sep
    echo ""

    # Вспомогательная функция: рисует строку таблицы с цветом
    # Использование: status_row "Название" <ok|warn|err> "Значение"
    status_row() {
        local name="$1"
        local state="$2"   # ok / warn / err
        local value="$3"
        local icon color
        case "$state" in
            ok)   icon="✅"; color="$GREEN"  ;;
            warn) icon="⚠️ "; color="$YELLOW" ;;
            err)  icon="❌"; color="$RED"    ;;
        esac
        printf "  %-20s %b%-5s%b  %s\n" "$name" "$color" "$icon" "$RESET" "$value"
    }

    # --- XanMod ---
    KERNEL=$(uname -r 2>/dev/null)
    if echo "$KERNEL" | grep -qi xanmod; then
        status_row "XanMod Kernel" ok "$KERNEL"
    else
        status_row "XanMod Kernel" err "$KERNEL (не xanmod)"
    fi

    # --- BBR ---
    BBR_VAL=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "недоступно")
    if [[ "$BBR_VAL" == "bbr" ]]; then
        status_row "BBRv3" ok "$BBR_VAL"
    else
        status_row "BBRv3" err "$BBR_VAL (нужен bbr)"
    fi

    # --- TFO ---
    TFO_VAL=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "0")
    if [[ "$TFO_VAL" == "3" ]]; then
        status_row "TCP Fast Open" ok "3 (клиент + сервер)"
    elif [[ "$TFO_VAL" == "1" || "$TFO_VAL" == "2" ]]; then
        status_row "TCP Fast Open" warn "частично ($TFO_VAL, нужно 3)"
    else
        status_row "TCP Fast Open" err "выключен ($TFO_VAL)"
    fi

    # --- qdisc ---
    QDISC_VAL=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
    if [[ "$QDISC_VAL" == "fq" ]]; then
        status_row "Default qdisc" ok "fq"
    else
        status_row "Default qdisc" warn "$QDISC_VAL (рекомендован fq)"
    fi

    # --- MSS Clamping ---
    if nft list ruleset 2>/dev/null | grep -q mangle; then
        # Получаем значение MSS из конфига если есть
        MSS_VAL=$(grep -o 'maxseg size set [0-9]*' /etc/nftables.conf 2>/dev/null | head -1 | awk '{print $NF}')
        [[ -n "$MSS_VAL" ]] && status_row "MSS Clamping" ok "nftables (MSS=$MSS_VAL)" \
                             || status_row "MSS Clamping" ok "nftables (rt mtu)"
    else
        status_row "MSS Clamping" err "nftables не настроен"
    fi

    # --- Conntrack ---
    CT_VAL=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "—")
    if [[ "$CT_VAL" != "—" ]]; then
        status_row "Conntrack max" ok "$CT_VAL"
    else
        status_row "Conntrack max" warn "модуль не загружен"
    fi

    # --- CAKE ---
    CAKE_FOUND=0
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$'); do
        tc qdisc show dev "$iface" 2>/dev/null | grep -qi cake && CAKE_FOUND=1 && break
    done
    if [[ $CAKE_FOUND -eq 0 ]]; then
        status_row "CAKE qdisc" ok "не обнаружен (хорошо)"
    else
        status_row "CAKE qdisc" warn "обнаружен! Запусти пункт 7"
    fi

    # --- Swap ---
    SWAP_LINE=$(swapon --show=NAME,SIZE,USED --noheadings 2>/dev/null | grep swapfile | head -1)
    if [[ -n "$SWAP_LINE" ]]; then
        SWAP_SZ=$(echo "$SWAP_LINE" | awk '{print $2}')
        SWAP_USED=$(echo "$SWAP_LINE" | awk '{print $3}')
        status_row "Swap" ok "${SWAP_SZ} (использовано: ${SWAP_USED})"
    else
        status_row "Swap" warn "не активен"
    fi

    # --- IPv6 ---
    IPV6_DIS=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    if [[ "$IPV6_DIS" == "1" ]]; then
        status_row "IPv6" warn "отключён"
    else
        status_row "IPv6" ok "включён"
    fi

    # --- Сервис tc-fq ---
    if systemctl is-active --quiet tc-fq-optimize.service 2>/dev/null; then
        status_row "tc-fq сервис" ok "активен"
    else
        status_row "tc-fq сервис" warn "не установлен"
    fi

    echo ""
    sep
}

# =============================================================================
# ФУНКЦИЯ 11 — Полная установка (все шаги по порядку)
# =============================================================================
fn_full_install() {
    sep
    echo -e "${BOLD}🏆 Полная установка — выполняем все шаги${RESET}"
    sep
    warn "Это займёт несколько минут. Убедись, что сделал снапшот VPS!"
    echo ""
    read -rp "Продолжить полную установку? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Отменено."; return; }

    echo ""
    info "Шаг 1/7: Обновление пакетов..."
    fn_update

    echo ""
    info "Шаг 2/7: Установка XanMod ядра..."
    fn_xanmod

    echo ""
    info "Шаг 3/7: Включение BBRv3..."
    fn_bbr

    echo ""
    info "Шаг 4/7: Включение TFO..."
    fn_tfo

    echo ""
    info "Шаг 5/7: Настройка sysctl..."
    fn_sysctl

    echo ""
    info "Шаг 6/7: MSS Clamping..."
    fn_mss

    echo ""
    info "Шаг 7/7: Отключение CAKE → fq..."
    fn_cake

    sep
    ok "=== Полная установка завершена! ==="
    sep
    echo ""
    warn "Необходима перезагрузка для загрузки нового ядра XanMod!"
    echo ""
    read -rp "Перезагрузить сейчас? [y/N]: " reboot_confirm
    if [[ "$reboot_confirm" =~ ^[Yy]$ ]]; then
        info "Перезагружаемся..."
        reboot
    else
        info "Перезагрузи вручную командой: sudo reboot"
    fi
}

# =============================================================================
# ГЛАВНОЕ МЕНЮ (цикличное — возвращается после каждого действия)
# =============================================================================
main_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════╗${RESET}"
        echo -e "${CYAN}${BOLD}║       ⚡ VPS Network Optimizer  v2.2          ║${RESET}"
        echo -e "${CYAN}${BOLD}║      github.com/anqqu/optimizer               ║${RESET}"
        echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════╝${RESET}"
        echo ""

        # Системная информация
        echo -e "  ${BLUE}Ядро:${RESET} $(uname -r)  ${BLUE}|${RESET}  ${BLUE}ОС:${RESET} $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
        echo -e "  ${BLUE}RAM:${RESET}  $(free -h | awk '/^Mem:/{print $2}')  ${BLUE}|${RESET}  ${BLUE}CPU:${RESET} $(nproc) ядра  ${BLUE}|${RESET}  ${BLUE}Диск:${RESET} $(df -h / | awk 'NR==2{print $4}') свободно"

        # Строка статуса компонентов (✅/❌ прямо в меню)
        echo ""
        fn_show_statusbar
        echo ""
        sep

        echo -e "  ${BOLD}Ядро и сеть:${RESET}"
        echo -e "  ${GREEN} 1)${RESET} 🔄 Обновить пакеты ${YELLOW}(apt + зеркало-фоллбэк)${RESET}"
        echo -e "  ${GREEN} 2)${RESET} 🚀 Установить XanMod Kernel"
        echo -e "  ${GREEN} 3)${RESET} 📡 Включить BBRv3 + fq qdisc"
        echo -e "  ${GREEN} 4)${RESET} ⚡ Включить TCP Fast Open ${YELLOW}(TFO)${RESET}"
        echo -e "  ${GREEN} 5)${RESET} 🔧 Настроить sysctl ${YELLOW}(conntrack, буферы, лимиты)${RESET}"
        echo -e "  ${GREEN} 6)${RESET} 🔒 MSS Clamping ${YELLOW}(авто / адаптивный MTU / ручной)${RESET}"
        echo -e "  ${GREEN} 7)${RESET} 📦 Отключить CAKE → fq qdisc"
        echo ""
        echo -e "  ${BOLD}Система:${RESET}"
        echo -e "  ${GREEN} 8)${RESET} 🌐 IPv6 ${YELLOW}(вкл/выкл)${RESET}"
        echo -e "  ${GREEN} 9)${RESET} 💾 Создать Swap ${YELLOW}(512МБ / 1 / 2 / 4 ГБ / свой)${RESET}"
        echo -e "  ${GREEN}10)${RESET} 📊 Проверить статус"
        echo ""
        echo -e "  ${BOLD}Быстрый старт:${RESET}"
        echo -e "  ${GREEN}11)${RESET} 🏆 ${BOLD}Полная установка (все шаги сразу)${RESET}"
        sep
        echo -e "  ${RED} 0)${RESET} ❌ Выход"
        echo ""

        read -rp "  Выбери пункт [0-11]: " choice
        echo ""

        case "$choice" in
            1)  fn_update       ;;
            2)  fn_xanmod       ;;
            3)  fn_bbr          ;;
            4)  fn_tfo          ;;
            5)  fn_sysctl       ;;
            6)  fn_mss          ;;
            7)  fn_cake         ;;
            8)  fn_ipv6         ;;
            9)  fn_swap         ;;
            10) fn_status       ;;
            11) fn_full_install ;;
            0)
                echo -e "${GREEN}Удачи! 👋${RESET}"
                exit 0
                ;;
            *)
                warn "Неверный выбор: '$choice'. Введи число от 0 до 11."
                ;;
        esac

        echo ""
        read -rp "  Нажми Enter чтобы вернуться в меню..." _
    done
}

# =============================================================================
# ТОЧКА ВХОДА — с этого места начинается выполнение скрипта
# =============================================================================
check_root   # Проверяем права root
check_os     # Проверяем ОС
main_menu    # Запускаем главное меню
