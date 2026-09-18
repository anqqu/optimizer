# ⚡ VPS Network Optimizer v2.0

![XanMod](https://img.shields.io/badge/XanMod-Latest-blue)
![BBRv3](https://img.shields.io/badge/BBRv3-Enabled-brightgreen)
![OS](https://img.shields.io/badge/OS-Debian%20%7C%20Ubuntu-blue)
![Interactive](https://img.shields.io/badge/Menu-Interactive-orange)

**Интерактивный оптимизатор сетевого стека и ядра VPS с удобным меню выбора.**

> [!IMPORTANT]
> Скрипт заменяет ядро системы. Сделай **снапшот VPS** перед запуском!
> Работает только на **KVM**-виртуализации (не OpenVZ/LXC).

---

## 🎛️ Интерактивное меню

После запуска скрипт показывает меню — выбираешь нужное действие по номеру:

```
╔═══════════════════════════════════════════════╗
║       ⚡ VPS Network Optimizer  v2.0          ║
║      github.com/anqqu/optimizer               ║
╚═══════════════════════════════════════════════╝

  Ядро: 6.1.0-28-amd64
  ОС:   Debian GNU/Linux 12 (bookworm)
  RAM:  2.0G | CPU: 2 ядра

─────────────────────────────────────────────
  1) 🔄 Обновить пакеты (apt update + upgrade)
  2) 🚀 Установить XanMod + BBRv3 + TFO
  3) 🔧 Настроить sysctl (conntrack, буферы, лимиты)
  4) 🔒 MSS Clamping (nftables IPv4+IPv6)
  5) 📦 Отключить CAKE → fq qdisc
  6) 💾 Создать Swap 1 ГБ
  7) 📊 Проверить статус (uname, bbr, tc, nft, swap)
  8) 🏆 Полная установка (все шаги сразу)
─────────────────────────────────────────────
  0) ❌ Выход

  Выбери пункт [0-8]:
```

---

## ✨ Что делает каждый пункт

| # | Действие | Описание |
| :---: | :--- | :--- |
| **1** | 🔄 Обновить пакеты | `apt update + upgrade` + установка зависимостей |
| **2** | 🚀 XanMod + BBRv3 + TFO | Автовыбор ядра (v2/v3/v4), BBR алгоритм TCP, Fast Open |
| **3** | 🔧 sysctl | Conntrack, буферы TCP/UDP, лимиты — подбираются под RAM/CPU |
| **4** | 🔒 MSS Clamping | nftables правила для IPv4+IPv6 (решает path MTU black hole) |
| **5** | 📦 CAKE → fq | Замена CAKE qdisc на fq + systemd-сервис для автоприменения |
| **6** | 💾 Swap 1 ГБ | Создание и активация swap-файла (нужен для конфигов 1/1) |
| **7** | 📊 Статус | Проверка ядра, BBR, qdisc, conntrack, nftables, swap |
| **8** | 🏆 Всё сразу | Выполняет пункты 1–5 по порядку с запросом перезагрузки |

---

## 📋 Требования

* **ОС:** Debian 11/12, Ubuntu 22.04/24.04 LTS
* **Виртуализация:** KVM (не OpenVZ/LXC)
* **Права:** запуск от root или через `sudo`
* **RAM:** рекомендуется 2+ ГБ (на 1 ГБ нужен Swap — пункт 6)

---

## 🚀 Установка и запуск

### Вариант 1: Одной командой (curl)
```bash
sudo curl -fsSL https://raw.githubusercontent.com/anqqu/optimizer/main/optimizer.sh | sudo bash
```

### Вариант 2: Скачать и запустить
```bash
sudo curl -fsSL -O https://raw.githubusercontent.com/anqqu/optimizer/main/optimizer.sh
sudo chmod +x optimizer.sh
sudo ./optimizer.sh
```

---

## 🔄 После полной установки

Перезагрузи сервер (скрипт предложит сам):
```bash
sudo reboot
```

Затем проверь (или используй пункт **7** в меню):
```bash
uname -r                                    # должно быть xanmod
sysctl net.ipv4.tcp_congestion_control      # должно быть bbr
tc qdisc show                               # ищи fq
nft list ruleset                            # правила MSS clamping
```

---

## 🛠️ Бонус: Swap вручную (без меню)

```bash
sudo swapoff /swapfile 2>/dev/null || true && \
sudo fallocate -l 1G /swapfile && \
sudo chmod 600 /swapfile && \
sudo mkswap /swapfile && \
sudo swapon /swapfile && \
{ sudo grep -qE '^\s*/swapfile\s' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab; }
```

---

## 🎯 Для кого этот проект

Сделан для себя — для быстрой оптимизации свежих VPS под прокси/Xray.