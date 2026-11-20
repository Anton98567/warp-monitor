# warp-monitor

Универсальный скрипт мониторинга **Cloudflare WARP** на Linux-серверах + egress-тесты
на основные сайты. Без личных данных, работает на любом сервере с установленным
`warp-cli` (Ubuntu/Debian/CentOS/Alma/Rocky).

## Что делает

* проверяет статус `warp-cli` каждый час (cron) и **сам переподключает** WARP при обрыве;
* тестирует egress через WARP SOCKS-прокси (WarpProxy) на 8 сайтов:
  Google, Яндекс, Рамблер + Cloudflare, GitHub, YouTube, Wikipedia, Amazon (список настраивается);
  любой HTTP-ответ сервера (в т.ч. 4xx/5xx антибота) означает, что туннель работает —
  FAIL только при полном отсутствии ответа (обрыв/таймаут);
* дополнительно (опционально) проверяет те же сайты напрямую — видно, проблема в WARP или в сети;
* показывает IP выхода через WARP и напрямую;
* пишет лог (`/var/log/warp-monitor/`) и текстовый отчёт (`/var/lib/warp-monitor/last-report.txt`);
* опционально шлёт алерты в Telegram (только при сбое и восстановлении — не спамит);
* авто-ротация лога встроена (5 × 5 МБ) + logrotate.

## Установка одной командой

```bash
curl -fsSL https://raw.githubusercontent.com/Anton98567/warp-monitor/main/install.sh | bash
```

Установщик скачает скрипт в `/usr/local/bin/warp-monitor.sh`, создаст конфиг
`/etc/warp-monitor.conf`, поставит почасовой cron (проверка в HH:17) и выполнит
пробный запуск.

Опции:

```bash
curl -fsSL https://raw.githubusercontent.com/Anton98567/warp-monitor/main/install.sh | bash -s -- --no-cron   # без cron
curl -fsSL https://raw.githubusercontent.com/Anton98567/warp-monitor/main/install.sh | bash -s -- --no-check  # без пробного запуска
```

## Требования

* Linux с `curl` и `bash`;
* клиент Cloudflare WARP (`warp-cli`) — сам НЕ устанавливается скриптом;
* режим WarpProxy: `warp-monitor.sh setup-proxy` (включит `warp-cli mode proxy` на порту 40000).

## Команды

| Команда | Действие |
|---|---|
| `warp-monitor.sh` / `check` | полный цикл: статус WARP + авто-лечение + egress-тесты |
| `warp-monitor.sh egress` | только egress-тесты (без переподключения) |
| `warp-monitor.sh status` | статус WARP + последний отчёт |
| `warp-monitor.sh report` | распечатать полный отчёт |
| `warp-monitor.sh setup-proxy` | включить WarpProxy (порт из конфига) |
| `warp-monitor.sh install` | поставить cron + logrotate |
| `warp-monitor.sh uninstall` | удалить cron + logrotate |
| `warp-monitor.sh test-alert` | тест уведомления в Telegram |
| `warp-monitor.sh --quiet` | без вывода в stdout (для cron) |

Коды выхода: `0` — всё OK, `1` — деградация (часть сайтов недоступна),
`2` — критично (WARP выключен / не зарегистрирован / не установлен).

## Конфигурация

`/etc/warp-monitor.conf` (root:root, 600). Все переменные необязательны:

```bash
WARP_CLI="warp-cli --accept-tos"     # команда warp-cli
WARP_SOCKS="127.0.0.1:40000"         # адрес WarpProxy SOCKS5
CURL_TIMEOUT=15                      # таймаут HTTP-запроса, сек
CONNECT_RETRIES=3                    # попыток переподключения WARP
CONNECT_WAIT=6                       # пауза между попытками, сек
FAIL_THRESHOLD=2                     # упавших сайтов >= N => деградация
RUN_DIRECT_TEST=1                    # 1 = тестировать сайты и напрямую
ALERT_ON_RECOVER=1                   # 1 = уведомлять о восстановлении
SITES="https://www.google.com https://ya.ru https://www.rambler.ru ..."
TELEGRAM_TOKEN=""                    # токен Telegram-бота (опц.)
TELEGRAM_CHAT_ID=""                  # chat_id (опц.)
```

## Telegram-алерты (опционально)

Заполните в `/etc/warp-monitor.conf`:

```bash
TELEGRAM_TOKEN="<токен бота>"
TELEGRAM_CHAT_ID="<chat_id>"
```

Затем `warp-monitor.sh test-alert`. Уведомления уходят только при смене состояния
(сбой / восстановление), ежечасные успешные проверки молчат.

## Авто-лечение

Если WARP отвалился, скрипт при почасовой проверке сам чинит его по цепочке:

1. упал демон `warp-svc` → `systemctl start warp-svc`;
2. статус `Disconnected`/`unknown` → `warp-cli connect` (до 3 попыток с паузой);
3. после переподключения — egress-тесты подтверждают, что туннель реально работает.

Если поднять не удалось — критический алерт в Telegram и отчёт (трафик идёт
напрямую, IP виден). Максимальное время до авто-лечения — до 1 часа
(до следующего запуска cron); можно уменьшить интервал в `/etc/cron.d/warp-monitor`.

## Файлы

| Путь | Назначение |
|---|---|
| `/usr/local/bin/warp-monitor.sh` | сам скрипт |
| `/etc/warp-monitor.conf` | настройки (600) |
| `/etc/cron.d/warp-monitor` | почасовой cron (HH:17) |
| `/var/log/warp-monitor/warp-monitor.log` | лог |
| `/var/lib/warp-monitor/last-report.txt` | последний отчёт |
| `/var/lib/warp-monitor/last-state` | последнее состояние (для алертов) |

## Лицензия

MIT. Публичный репозиторий, личных данных не содержит.
