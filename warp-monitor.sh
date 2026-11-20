#!/usr/bin/env bash
#
# warp-monitor.sh — универсальный мониторинг Cloudflare WARP + egress-тесты.
#
# Что делает:
#   * проверяет статус warp-cli и сам чинит соединение (connect) при обрыве;
#   * тестирует egress через WARP SOCKS-прокси на список сайтов
#     (Google, Яндекс, Рамблер + ещё 5 — настраивается в конфиге);
#   * показывает IP выхода напрямую и через WARP;
#   * пишет лог и текстовый отчёт, опционально шлёт алерты в Telegram;
#   * "install" ставит почасовую проверку в cron.
#
# Использование:
#   warp-monitor.sh [check|egress|status|report|setup-proxy|install|uninstall|test-alert|help]
#
#   check        — полный цикл: статус WARP + авто-лечение + egress-тесты (по умолчанию)
#   egress       — только egress-тесты (без переподключения WARP)
#   status       — статус WARP + последний отчёт
#   report       — распечатать последний отчёт
#   setup-proxy  — включить режим WarpProxy (warp-cli mode proxy + порт из конфига)
#   install      — установить почасовой cron + logrotate
#   uninstall    — удалить cron и logrotate
#   test-alert   — отправить тестовое уведомление в Telegram
#   --quiet      — без вывода в stdout (для cron; лог и отчёт пишутся всё равно)
#
# Конфиг: /etc/warp-monitor.conf (переменные KEY=VALUE, владелец root, 600).
# Коды выхода: 0 = всё OK, 1 = деградация (часть сайтов недоступна), 2 = критично
#              (WARP выключен/не зарегистрирован/не установлен).
#
# Поддерживает Ubuntu/Debian/CentOS/Alma/Rocky с установленным warp-cli
# (Cloudflare WARP client). Сам warp-cli НЕ устанавливает.

set -u
set -o pipefail

VERSION="1.0.0"

# ---------- пути ----------
CONF="${WARP_MONITOR_CONF:-/etc/warp-monitor.conf}"
LOG_DIR="${WARP_MONITOR_LOG_DIR:-/var/log/warp-monitor}"
STATE_DIR="${WARP_MONITOR_STATE_DIR:-/var/lib/warp-monitor}"
LOG_FILE="$LOG_DIR/warp-monitor.log"
REPORT_FILE="$STATE_DIR/last-report.txt"
STATE_FILE="$STATE_DIR/last-state"

# ---------- настройки по умолчанию (перекрываются из /etc/warp-monitor.conf) ----------
WARP_CLI="${WARP_CLI:-warp-cli --accept-tos}"   # команда warp-cli (флаг --accept-tos нужен на свежих установках)
WARP_SOCKS="${WARP_SOCKS:-127.0.0.1:40000}"     # адрес WarpProxy SOCKS5
CURL_TIMEOUT="${CURL_TIMEOUT:-15}"              # таймаут одного HTTP-запроса, сек
IP_TIMEOUT="${IP_TIMEOUT:-10}"                  # таймаут определения IP выхода, сек
CONNECT_RETRIES="${CONNECT_RETRIES:-3}"         # попыток переподключения WARP
CONNECT_WAIT="${CONNECT_WAIT:-6}"               # ожидание между попытками, сек
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"           # упавших сайтов >= N => деградация
RUN_DIRECT_TEST="${RUN_DIRECT_TEST:-1}"         # 1 = дополнительно тестить сайты напрямую (мимо WARP)
ALERT_ON_RECOVER="${ALERT_ON_RECOVER:-1}"       # 1 = слать уведомление и о восстановлении
TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}"            # токен бота (опционально)
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"        # chat_id (опционально)

# Сайты для egress-тестов: Google, Яндекс, Рамблер + 5 дополнительных.
SITES="${SITES:-https://www.google.com https://ya.ru https://www.rambler.ru https://www.cloudflare.com https://github.com https://www.youtube.com https://www.wikipedia.org https://www.amazon.com}"

QUIET=0

# ---------- служебное ----------
_ts()  { date '+%Y-%m-%d %H:%M:%S %Z'; }
log()  { printf '%s %s\n' "$(_ts)" "$*" | tee -a "$LOG_FILE" >&2; }
out()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

load_conf() {
    if [ -r "$CONF" ]; then
        # shellcheck disable=SC1090
        . "$CONF"
    fi
}

prepare_dirs() {
    mkdir -p "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true
    # встроенная ротация лога (5 файлов по 5 МБ) — не требует logrotate
    if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt 5242880 ]; then
        local i
        for i in 5 4 3 2 1; do
            [ -f "$LOG_FILE.$i" ] && mv -f "$LOG_FILE.$i" "$LOG_FILE.$((i+1))"
        done
        mv -f "$LOG_FILE" "$LOG_FILE.1"
    fi
}

# ---------- warp-cli ----------
warp_cli_ok() { command -v ${WARP_CLI%% *} >/dev/null 2>&1; }

warp_status() {
    # echo: connected | disconnected | unregistered | missing | unknown
    if ! warp_cli_ok; then echo "missing"; return; fi
    local out
    out=$($WARP_CLI status 2>&1) || true
    case "$out" in
        *Disconnected*)                echo "disconnected" ;;   # проверять до Connected!
        *Connected*)                   echo "connected" ;;
        *"Registration Missing"*|*Unregistered*|*"not registered"*|*"Terms of Service"*) echo "unregistered" ;;
        *"No such"*|*Error*|*error*)   echo "unknown" ;;
        *)                             echo "unknown" ;;
    esac
}

warp_connect() {
    local st i
    for i in $(seq 1 "$CONNECT_RETRIES"); do
        log "warp: попытка подключения $i/$CONNECT_RETRIES ..."
        $WARP_CLI connect >/dev/null 2>&1 || true
        sleep "$CONNECT_WAIT"
        st=$(warp_status)
        if [ "$st" = "connected" ]; then
            log "warp: подключён"
            return 0
        fi
    done
    log "warp: НЕ удалось подключиться (статус: $(warp_status))"
    return 1
}

# ---------- egress-тесты ----------
# $1 = url, $2 = "" (через WARP socks) или "direct" (напрямую)
# печатает: "<код> <сек>"
probe_site() {
    local url="$1" mode="${2:-}" args=()
    if [ "$mode" != "direct" ]; then
        args+=(--socks5-hostname "$WARP_SOCKS")
    fi
    curl -sS -o /dev/null -w '%{http_code} %{time_total}' \
         --max-time "$CURL_TIMEOUT" "${args[@]}" "$url" 2>/dev/null || echo "000 0"
}

egress_ip() {
    # $1 = "" (через WARP) или "direct"
    local mode="${1:-}" args=()
    if [ "$mode" != "direct" ]; then
        args+=(--socks5-hostname "$WARP_SOCKS")
    fi
    curl -s --max-time "$IP_TIMEOUT" "${args[@]}" \
         https://api.ipify.org 2>/dev/null || echo "недоступен"
}

run_egress_tests() {
    # $1 = "" (через WARP) или "direct"; наполняет EG_OK / EG_FAIL и печатает строки
    local mode="${1:-}" label url code t name
    if [ "$mode" = "direct" ]; then label="напрямую"; else label="через WARP ($WARP_SOCKS)"; fi
    echo "egress-тесты $label:"
    for url in $SITES; do
        name=$(printf '%s' "$url" | sed -e 's|^https\?://||' -e 's|/$||')
        read -r code t < <(probe_site "$url" "$mode")
        if [ "$code" = "000" ] || [ "$code" = "0" ]; then
            printf '  %-28s FAIL (нет ответа за %ss)\n' "$name" "$CURL_TIMEOUT"
            if [ "$mode" != "direct" ]; then EG_FAIL=$((EG_FAIL+1)); fi
        elif [ "$code" -ge 200 ] && [ "$code" -lt 400 ]; then
            printf '  %-28s %s  %ss  OK\n' "$name" "$code" "$t"
            if [ "$mode" != "direct" ]; then EG_OK=$((EG_OK+1)); fi
        elif [ "$code" -ge 400 ] && [ "$code" -lt 500 ]; then
            # 4xx = сайт ответил (туннель работает), но контент/защита
            printf '  %-28s %s  %ss  OK (HTTP %s от сервера)\n' "$name" "$code" "$t" "$code"
            if [ "$mode" != "direct" ]; then EG_OK=$((EG_OK+1)); fi
        else
            printf '  %-28s %s  %ss  FAIL\n' "$name" "$code" "$t"
            if [ "$mode" != "direct" ]; then EG_FAIL=$((EG_FAIL+1)); fi
        fi
    done
}

# ---------- Telegram ----------
tg_send() {
    local text="$1"
    [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || return 0
    curl -s --max-time 15 -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
         --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
         --data-urlencode "text=${text}" >/dev/null 2>&1 || true
}

# ---------- отчёт и алерты ----------
write_report() {
    {
        echo "=== warp-monitor v$VERSION — $(_ts) ==="
        echo "host: $(hostname 2>/dev/null || echo '?')"
        echo "warp-cli: $(warp_cli_ok && echo 'найден' || echo 'НЕ УСТАНОВЛЕН')"
        echo "warp статус: $WARP_ST"
        echo "IP выхода через WARP: $WARP_IP"
        echo "IP выхода напрямую:   $DIRECT_IP"
        echo
        printf '%s\n' "$EGRESS_BLOCK"
        echo
        echo "Итог: $SUMMARY"
    } > "$REPORT_FILE" 2>/dev/null || true
}

alert() {
    # $1 = уровень (OK|WARN|CRIT), $2 = текст
    local level="$1" text="$2" cur last
    cur="$level"
    last=""
    [ -f "$STATE_FILE" ] && last=$(cat "$STATE_FILE" 2>/dev/null || true)
    printf '%s\n' "$cur" > "$STATE_FILE" 2>/dev/null || true
    if [ "$cur" = "OK" ] && [ "$last" = "OK" ]; then
        return 0    # стабильно хорошо — не спамим
    fi
    if [ "$cur" = "OK" ] && [ "$ALERT_ON_RECOVER" != "1" ]; then
        return 0
    fi
    if [ "$cur" = "OK" ] && [ -z "$last" ]; then
        return 0    # первый успешный цикл — не шлём
    fi
    tg_send "warp-monitor [$(hostname 2>/dev/null || echo '?')] $level
$text"
}

# ---------- команды ----------
cmd_check() {
    prepare_dirs
    load_conf
    local st i
    st=$(warp_status)
    case "$st" in
        missing)
            WARP_ST="warp-cli НЕ УСТАНОВЛЕН"
            log "критично: warp-cli не установлен"
            WARP_IP=$(egress_ip) DIRECT_IP=$(egress_ip direct)
            EG_OK=0; EG_FAIL=0
            EGRESS_BLOCK=$(run_egress_tests direct 2>&1)
            SUMMARY="CRIT: warp-cli не установлен"
            write_report
            out "$SUMMARY"
            alert CRIT "warp-cli не установлен — мониторинг WARP невозможен"
            return 2
            ;;
        unregistered)
            WARP_ST="не зарегистрирован (Registration Missing)"
            log "критично: WARP не зарегистрирован"
            WARP_IP=$(egress_ip) DIRECT_IP=$(egress_ip direct)
            EG_OK=0; EG_FAIL=0
            EGRESS_BLOCK=$(run_egress_tests direct 2>&1)
            SUMMARY="CRIT: WARP не зарегистрирован (warp-cli registration new)"
            write_report
            out "$SUMMARY"
            alert CRIT "WARP не зарегистрирован — нужен: warp-cli --accept-tos registration new"
            return 2
            ;;
        disconnected|unknown)
            log "warp: статус '$st' — пробую переподключить"
            warp_connect || true
            st=$(warp_status)
            ;;
    esac

    if [ "$st" != "connected" ]; then
        WARP_ST="ВЫКЛЮЧЕН (после $(echo "$CONNECT_RETRIES") попыток)"
        log "критично: WARP не поднялся"
        WARP_IP=$(egress_ip) DIRECT_IP=$(egress_ip direct)
        EG_OK=0; EG_FAIL=0
        EGRESS_BLOCK=$(run_egress_tests direct 2>&1)
        SUMMARY="CRIT: WARP выключен, трафик идёт напрямую"
        write_report
        out "$SUMMARY"
        alert CRIT "WARP выключен и не поднимается — трафик идёт напрямую (IP: $DIRECT_IP)"
        return 2
    fi

    WARP_ST="Connected"
    log "warp: Connected, запускаю egress-тесты"
    WARP_IP=$(egress_ip)
    DIRECT_IP=$(egress_ip direct)
    EG_OK=0; EG_FAIL=0
    EGRESS_BLOCK=$(run_egress_tests 2>&1)
    if [ "$RUN_DIRECT_TEST" = "1" ]; then
        EGRESS_BLOCK="$EGRESS_BLOCK
$(run_egress_tests direct 2>&1)"
    fi

    if [ "$EG_FAIL" -ge "$FAIL_THRESHOLD" ]; then
        SUMMARY="WARN: через WARP доступно $EG_OK из $((EG_OK+EG_FAIL)) сайтов"
        write_report
        out "$SUMMARY"
        alert WARN "$SUMMARY
IP выхода через WARP: $WARP_IP"
        return 1
    elif [ "$EG_FAIL" -gt 0 ]; then
        SUMMARY="WARN: $EG_FAIL сайтов(а) не ответили через WARP (доступно $EG_OK)"
        write_report
        out "$SUMMARY"
        alert WARN "$SUMMARY"
        return 1
    fi

    SUMMARY="OK: WARP Connected, все $EG_OK сайтов доступны через WARP (IP выхода: $WARP_IP)"
    write_report
    out "$SUMMARY"
    alert OK "$SUMMARY"
    return 0
}

cmd_egress() {
    prepare_dirs
    load_conf
    EG_OK=0; EG_FAIL=0
    run_egress_tests
    out "IP выхода через WARP: $(egress_ip)"
}

cmd_status() {
    load_conf
    echo "warp-cli:  $(warp_cli_ok && echo 'найден' || echo 'НЕ УСТАНОВЛЕН')"
    echo "warp:      $(warp_status)"
    echo "socks:     $WARP_SOCKS"
    if [ -f "$REPORT_FILE" ]; then
        echo
        echo "--- последний отчёт ($REPORT_FILE) ---"
        tail -n 20 "$REPORT_FILE"
    else
        echo "отчёта ещё нет — выполните: warp-monitor.sh check"
    fi
}

cmd_report() {
    [ -f "$REPORT_FILE" ] || die "отчёта нет: $REPORT_FILE"
    cat "$REPORT_FILE"
}

cmd_setup_proxy() {
    load_conf
    local port="${WARP_SOCKS##*:}"
    log "включаю режим WarpProxy на порту $port"
    $WARP_CLI mode proxy >/dev/null 2>&1 || true
    $WARP_CLI proxy port "$port" >/dev/null 2>&1 || true
    $WARP_CLI connect >/dev/null 2>&1 || true
    sleep 2
    echo "статус: $(warp_status); socks: $WARP_SOCKS"
}

cmd_install() {
    load_conf
    prepare_dirs
    local self cron_f logr_f
    self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    cron_f=/etc/cron.d/warp-monitor
    logr_f=/etc/logrotate.d/warp-monitor

    if [ ! -d /etc/cron.d ]; then
        die "нет каталога /etc/cron.d — добавьте в crontab вручную: 17 * * * * $self check --quiet"
    fi
    cat > "$cron_f" <<EOF
# warp-monitor — почасовая проверка WARP + egress-тесты
# ставится скриптом warp-monitor.sh install; удалить: warp-monitor.sh uninstall
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 * * * * root $self check --quiet >> $LOG_FILE 2>&1
EOF
    chmod 644 "$cron_f"
    log "установлен почасовой cron: $cron_f (проверка в HH:17)"

    if [ -d /etc/logrotate.d ]; then
        cat > "$logr_f" <<EOF
$LOG_FILE {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
EOF
        chmod 644 "$logr_f"
        log "установлен logrotate: $logr_f"
    fi

    out "Готово. Проверка выполняется каждый час (в HH:17)."
    out "Запустить сейчас:  $self check"
    out "Тест Telegram:     $self test-alert"
}

cmd_uninstall() {
    rm -f /etc/cron.d/warp-monitor /etc/logrotate.d/warp-monitor
    log "cron и logrotate удалены (логи и отчёты сохранены в $LOG_DIR / $STATE_DIR)"
    out "Удалено."
}

cmd_test_alert() {
    load_conf
    if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        die "Telegram не настроен: заполните TELEGRAM_TOKEN и TELEGRAM_CHAT_ID в $CONF"
    fi
    tg_send "warp-monitor [$(hostname 2>/dev/null || echo '?')] OK
Тестовое уведомление — алерты работают."
    out "Тестовое сообщение отправлено."
}

usage() {
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------- main ----------
main() {
    local cmd="check" a
    for a in "$@"; do
        case "$a" in
            --quiet)  QUIET=1 ;;
            --version) echo "warp-monitor $VERSION"; exit 0 ;;
            -h|--help|help) usage; exit 0 ;;
            *) cmd="$a" ;;
        esac
    done
    case "$cmd" in
        check)        cmd_check ;;
        egress)       cmd_egress ;;
        status)       cmd_status ;;
        report)       cmd_report ;;
        setup-proxy)  cmd_setup_proxy ;;
        install)      cmd_install ;;
        uninstall)    cmd_uninstall ;;
        test-alert)   cmd_test_alert ;;
        *)            usage; exit 2 ;;
    esac
}

main "$@"
