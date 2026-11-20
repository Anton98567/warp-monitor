#!/usr/bin/env bash
#
# install.sh — установка warp-monitor одной командой:
#
#   curl -fsSL https://raw.githubusercontent.com/Anton98567/warp-monitor/main/install.sh | bash
#
# Что делает:
#   * скачивает warp-monitor.sh в /usr/local/bin/warp-monitor.sh;
#   * создаёт /etc/warp-monitor.conf (если нет) с настройками по умолчанию;
#   * ставит почасовой cron (HH:17) и logrotate;
#   * выполняет пробный запуск check.
#
# Опции (передавать через bash -s -- ...):
#   --no-cron        — не ставить cron (только скрипт и конфиг)
#   --no-check       — не выполнять пробный check
#   --path <dir>     — куда ставить скрипт (по умолчанию /usr/local/bin)
#
# Требования: curl, warp-cli (клиент Cloudflare WARP) — сам НЕ устанавливается.

set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/Anton98567/warp-monitor/main}"
INSTALL_DIR="/usr/local/bin"
CONF="/etc/warp-monitor.conf"
DO_CRON=1
DO_CHECK=1

while [ $# -gt 0 ]; do
    case "$1" in
        --no-cron)  DO_CRON=0; shift ;;
        --no-check) DO_CHECK=0; shift ;;
        --path)     INSTALL_DIR="$2"; shift 2 ;;
        *)          echo "неизвестная опция: $1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "Запустите от root (sudo)." >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "Нужен curl." >&2; exit 2; }

echo "[1/4] Скачиваю warp-monitor.sh ..."
mkdir -p "$INSTALL_DIR"
# cache-buster: raw.githubusercontent.com кэширует по URL — без параметра можно получить старую версию
curl -fsSL "$REPO_RAW/warp-monitor.sh?ts=$(date +%s)" -o "$INSTALL_DIR/warp-monitor.sh"
chmod 755 "$INSTALL_DIR/warp-monitor.sh"

echo "[2/4] Конфиг $CONF ..."
if [ ! -f "$CONF" ]; then
    cat > "$CONF" <<'EOF'
# warp-monitor — настройки (KEY=VALUE). Владелец root, права 600.
# Все значения ниже — значения по умолчанию; раскомментируйте для изменения.

# Команда warp-cli (флаг --accept-tos нужен на свежих установках клиента)
#WARP_CLI="warp-cli --accept-tos"

# Адрес WarpProxy SOCKS5 (warp-cli mode proxy)
#WARP_SOCKS="127.0.0.1:40000"

# Таймауты, сек
#CURL_TIMEOUT=15
#IP_TIMEOUT=10

# Авто-лечение WARP: попыток переподключения и ожидание между ними
#CONNECT_RETRIES=3
#CONNECT_WAIT=6

# Сколько упавших сайтов считать деградацией
#FAIL_THRESHOLD=2

# 1 = дополнительно тестировать сайты напрямую (мимо WARP)
#RUN_DIRECT_TEST=1

# Кругов перезапуска WARP при сбое и ожидание после перезапуска, сек
#HEAL_ROUNDS=3
#HEAL_WAIT=8

# Сайты для egress-тестов (через пробел)
#SITES="https://www.google.com https://ya.ru https://www.rambler.ru https://www.cloudflare.com https://github.com https://www.youtube.com https://www.wikipedia.org https://www.amazon.com"
EOF
    chmod 600 "$CONF"
    echo "      создан: $CONF"
else
    echo "      уже существует — не трогаю"
fi

if ! command -v warp-cli >/dev/null 2>&1; then
    echo "      ВНИМАНИЕ: warp-cli не найден — установите клиент Cloudflare WARP."
fi

echo "[3/4] Cron и logrotate ..."
if [ "$DO_CRON" -eq 1 ]; then
    "$INSTALL_DIR/warp-monitor.sh" install
else
    echo "      пропущено (--no-cron)"
fi

echo "[4/4] Пробный запуск ..."
if [ "$DO_CHECK" -eq 1 ]; then
    "$INSTALL_DIR/warp-monitor.sh" check || true
else
    echo "      пропущено (--no-check)"
fi
echo
echo "Готово. Команды:"
echo "  warp-monitor.sh check    — полная проверка WARP + перезапуск при сбое"
echo "  warp-monitor.sh status   — статус и последний отчёт"
echo "  warp-monitor.sh report   — полный отчёт"
echo "  warp-monitor.sh help     — все команды"
