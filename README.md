# XanMod Optimizer для VLESS Reality

![XanMod](https://img.shields.io/badge/XanMod-Latest-blue)
![BBRv3](https://img.shields.io/badge/BBRv3-Enabled-brightgreen)
![OS](https://img.shields.io/badge/OS-Debian%20%7C%20Ubuntu-blue)

**Мощная оптимизация сервера под VLESS Reality (1/1, 1/2, 2/4 и выше)**

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

---

### 🚀 Установка одной командой

```bash
sudo curl -fsSL https://raw.githubusercontent.com/anqqu/optimizer/main/optimizer.sh | sudo bash
```

### 📥 Скачать и запустить вручную

```bash
sudo curl -fsSL -O https://raw.githubusercontent.com/anqqu/optimizer/main/optimizer.sh; \
sudo chmod +x install-xanmod.sh; \
sudo sudo ./install-xanmod.sh
```

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
---

### ⚠️ Важное предупреждение

> **Скрипт меняет ядро системы.** Используйте только на серверах, где вы готовы к перезагрузке и возможному даунтайму.

- Создайте **снапшот** перед запуском
- Убедитесь, что у вас есть доступ по SSH после перезагрузки
- После выполнения скрипта обязательно выполните `reboot`

---

### 📋 Рекомендации

- **Лучше всего подходит** для чистых VPS с VLESS Reality
- Рекомендуется **минимум 2 ядра и 2 ГБ RAM**
- Поддерживаемые дистрибутивы: **Debian 11/12**, **Ubuntu 22.04/24.04**
- После установки и перезагрузки проверьте:
  ```bash
  uname -r && sysctl net.ipv4.tcp_congestion_control
---
### 🎯 Для кого этот скрипт

- Серверы VLESS Reality с большим количеством пользователей
- Те, кто хочет максимальную сетевую производительность
- Администраторы, желающие удобную и быструю оптимизацию
