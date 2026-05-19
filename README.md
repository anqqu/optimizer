# XanMod Optimizer для VLESS Reality

![XanMod](https://img.shields.io/badge/XanMod-Latest-blue)
![BBRv3](https://img.shields.io/badge/BBRv3-Enabled-brightgreen)
![OS](https://img.shields.io/badge/OS-Debian%20%7C%20Ubuntu-blue)

**Мощная оптимизация сервера под VLESS Reality (1/1, 1/2, 2/4 и выше)**

### 🚀 Установка одной командой

```bash
sudo curl -fsSL https://raw.githubusercontent.com/ВАШ_НИК/xanmod-optimizer/main/install-xanmod.sh | sudo bash
```

### 📥 Скачать и запустить вручную

```bash
sudo curl -fsSL -O https://raw.githubusercontent.com/ВАШ_НИК/xanmod-optimizer/main/install-xanmod.sh
sudo chmod +x install-xanmod.sh
sudo sudo ./install-xanmod.sh
```

### ✨ Что делает скрипт

| Компонент                    | Статус              | Описание |
|-----------------------------|---------------------|----------|
| **XanMod Kernel**           | Авто (v2/v3/v4)     | Автоматический выбор под ваш CPU |
| **BBRv3**                   | ✅ Включён          | Современный алгоритм управления перегрузкой |
| **TCP Fast Open (TFO)**     | ✅ Включён          | Значительно ускоряет TCP-соединения |
| **MSS Clamping**            | ✅ Включён          | nftables (IPv4 + IPv6) |
| **Conntrack**               | Увеличен           | До 524288 одновременных соединений |
| **CAKE qdisc**              | ❌ Отключён        | Заменяется на mq + fq |
| **Автозапуск**              | ✅ Включён          | Настройки применяются после перезагрузки |

### После установки обязательно:
```bash
sudo reboot
```
### Проверка после перезагрузки:
```bash
uname -r; \
sudo sysctl net.ipv4.tcp_congestion_control; \
sudo tc qdisc show; \
sudo nft list ruleset
```
