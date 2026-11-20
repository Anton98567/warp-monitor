# warp-monitor

Универсальный скрипт мониторинга **Cloudflare WARP** на Linux-серверах:
**100% проверка работоспособности + автоматический перезапуск при сбое**
+ почасовые egress-тесты на основные сайты. Без личных данных, работает на любом
сервере с установленным `warp-cli` (Ubuntu/Debian/CentOS/Alma/Rocky).

## 100% проверка «WARP работает»

Скрипт не доверяет одному только статусу `warp-cli`. Все 5 пунктов обязательны:

1. сервис `warp-svc` активен (systemd);
2. `warp-cli status` = Connected;
3. SOCKS-прокси (WarpProxy) реально отвечает;
4. через прокси `https://www.cloudflare.com/cdn-cgi/trace` возвращает **`warp=on`**
   — железное доказательство, что трафик выходит через WARP (напрямую тот же URL
   даёт `warp=off`);
5. IP выхода через WARP отличается от прямого IP сервера.

## Автоперезапуск при сбое

Если провалился хотя бы один пункт — скрипт автоматически делает **перезапуск**:

```
warp-cli disconnect → systemctl restart warp-svc → warp-cli mode proxy →
warp-cli connect → повторная полная проверка (до 3 кругов)
```

После успешного перезапуска egress-тесты подтверждают, что туннель реально работает.
Если поднять не удалось — критический статус (exit 2) и детальный отчёт.

## Egress-тесты

Каждый час (cron) тестируется подключение через WARP к 8 сайтам:
**Google, Яндекс, Рамблер** + Cloudflare, GitHub, YouTube, Wikipedia, Amazon
(список настраивается). Опционально те же сайты тестируются напрямую — для сравнения.
Любой HTTP-ответ сервера (в т.ч. 4xx/5xx антибота) означает, что туннель работает;
FAIL — только при полном отсутствии ответа.

## Установка одной командой

```bash
curl -fsSL https://raw.githubusercontent.com/Anton98567/warp-monitor/main/install.sh | bash
```

Установщик скачает скрипт в `/usr/local/bin/warp-monitor.sh`, создаст конфиг
`/etc/warp-monitor.conf`, поставит почасовой cron (проверка в HH:17) и logrotate
и выполнит пробную проверку.

Опции:

```bash
curl -fsSL https://raw.githubusercontent.com/Anton98567/warp-monitor/main/install.sh | bash -s -- --no-cron   # без cron
curl -fsSL https://raw.githubusercontent.com/Anton98567/warp-monitor/main/install.sh | bash -s -- --no-check  # без пробного запуска
```

## Требования

* Linux с `curl` и `bash`;
* клиент Cloudflare WARP (`warp-cli`) — сам НЕ устанавливается скриптом;
* режим WarpProxy: `warp-monitor.sh setup-proxy` (включит `warp-cli mode proxy`).

## Команды

| Команда | Действие |
|---|---|
| `warp-monitor.sh` / `check` | 100% верификация + перезапуск при сбое + egress-тесты |
| `warp-monitor.sh egress` | только egress-тесты (без перезапуска) |
| `warp-monitor.sh status` | статус WARP + последний отчёт |
| `warp-monitor.sh report` | распечатать полный отчёт |
| `warp-monitor.sh setup-proxy` | включить WarpProxy (порт из конфига) |
| `warp-monitor.sh install` | поставить cron + logrotate |
| `warp-monitor.sh uninstall` | удалить cron + logrotate |
| `warp-monitor.sh --quiet` | без вывода в stdout (для cron) |

Коды выхода: `0` — WARP работает, `1` — WARP работает, но часть сайтов недоступна,
`2` — WARP НЕ работает (после всех перезапусков) / не установлен / не зарегистрирован.

## Конфигурация

`/etc/warp-monitor.conf` (root:root, 600). Все переменные необязательны:

```bash
WARP_CLI="warp-cli --accept-tos"     # команда warp-cli
WARP_SOCKS="127.0.0.1:40000"         # адрес WarpProxy SOCKS5
WARP_PROXY_PORT=40000                # порт WarpProxy (для перезапуска/настройки)
CURL_TIMEOUT=15                      # таймаут HTTP-запроса, сек
HEAL_ROUNDS=3                        # кругов перезапуска при сбое
HEAL_WAIT=8                          # ожидание после перезапуска, сек
RUN_DIRECT_TEST=1                    # 1 = тестировать сайты и напрямую
SITES="https://www.google.com https://ya.ru https://www.rambler.ru ..."
```

## Файлы

| Путь | Назначение |
|---|---|
| `/usr/local/bin/warp-monitor.sh` | сам скрипт |
| `/etc/warp-monitor.conf` | настройки (600) |
| `/etc/cron.d/warp-monitor` | почасовой cron (HH:17) |
| `/var/log/warp-monitor/warp-monitor.log` | лог (авто-ротация 6 × 5 МБ + logrotate) |
| `/var/lib/warp-monitor/last-report.txt` | последний отчёт |

## Лицензия

MIT. Публичный репозиторий, личных данных не содержит.
