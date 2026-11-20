#!/usr/bin/env bash
#
# warp-monitor.sh — универсальный мониторинг Cloudflare WARP: 100% проверка
# работоспособности + автоматический перезапуск при сбое + egress-тесты.
#
# Проверка «WARP работает» проходит ПОЛНОСТЬЮ (все пункты обязательны):
#   1. сервис warp-svc активен (systemd);
#   2. warp-cli reports статус Connected;
#   3. SOCKS-прокси (WarpProxy) реально отвечает;
#   4. через прокси https://www.cloudflare.com/cdn-cgi/trace возвращает
#      "warp=on" — железное доказательство, что трафик выходит через WARP
#      (напрямую тот же URL даёт "warp=off");
#   5. IP выхода через WARP отличается от прямого IP сервера.
# Если хотя бы один пункт провален — скрипт ДЕЛАЕТ ПЕРЕЗАПУСК:
#   warp-cli disconnect → systemctl restart warp-svc → режим proxy →
#   warp-cli connect → повторная полная проверка (до 3 кругов).
#
# Использование:
#   warp-monitor.sh [check|egress|status|report|setup-proxy|install|uninstall|help]
#
#   check        — полный цикл: верификация + перезапуск при сбое + egress-тесты
#                  (по умолчанию; именно это запускает почасовой cron)
#   egress       — только egress-тесты на сайты (Google, Яндекс, Рамблер +5)
#   status       — статус WARP + последний отчёт
#   report       — распечатать последний отчёт
#   setup-proxy  — включить режим WarpProxy (warp-cli mode proxy + порт из конфига)
#   install      — установить почасовой cron (HH:17) + logrotate
#   uninstall    — удалить cron и logrotate
#   --quiet      — без вывода в stdout (для cron; лог и отчёт пишутся всё равно)
#
# Конфиг: /etc/warp-monitor.conf (KEY=VALUE, владелец root, 600).
# Коды выхода: 0 = WARP работает, 2 = WARP не работает (после всех перезапусков).
#
# Поддерживает Ubuntu/Debian/CentOS/Alma/Rocky с установленным warp-cli
# (клиент Cloudflare WARP). Сам warp-cli НЕ устанавливает.

set -u
set -o pipefail

VERSION="2.0.0"

# ---------- пути ----------
CONF="${WARP_MONITOR_CONF:-/etc/warp-monitor.conf}"
LOG_DIR="${WARP_MONITOR_LOG_DIR:-/var/log/warp-monitor}"
STATE_DIR="${WARP_MONITOR_STATE_DIR:-/var/lib/warp-monitor}"
LOG_FILE="$LOG_DIR/warp-monitor.log"
REPORT_FILE="$STATE_DIR/last-report.txt"
STATE_FILE="$STATE_DIR/last-state"

# ---------- настройки по умолчанию (перекрываются из /etc/warp-monitor.conf) ----------
WARP_CLI="${WARP_CLI:-warp-cli --accept-tos}"   # команда warp-cli
WARP_SOCKS="${WARP_SOCKS:-127.0.0.1:40000}"     # адрес WarpProxy SOCKS5
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"     # порт WarpProxy (для setup-proxy/перезапуска)
CURL_TIMEOUT="${CURL_TIMEOUT:-15}"              # таймаут одного HTTP-запроса, сек
IP_TIMEOUT="${IP_TIMEOUT:-10}"                  # таймаут определения IP выхода, сек
HEAL_ROUNDS="${HEAL_ROUNDS:-3}"                 # кругов перезапуска при сбое
HEAL_WAIT="${HEAL_WAIT:-8}"                     # ожидание после перезапуска, сек
RUN_DIRECT_TEST="${RUN_DIRECT_TEST:-1}"         # 1 = egress-тесты также напрямую (для сравнения)

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
    # встроенная ротация лога (6 файлов по 5 МБ) — не требует logrotate
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

warp_status_raw() {
    $WARP_CLI status 2>&1 || true
}

warp_status() {
    # echo: connected | disconnected | unregistered | missing | unknown
    if ! warp_cli_ok; then echo "missing"; return; fi
    local out
    out=$(warp_status_raw)
    case "$out" in
        *Disconnected*)                echo "disconnected" ;;   # проверять до Connected!
        *Connected*)                   echo "connected" ;;
        *"Registration Missing"*|*Unregistered*|*"not registered"*|*"Terms of Service"*) echo "unregistered" ;;
        *)                             echo "unknown" ;;
    esac
}

# ---------- верификация «WARP работает» (100%) ----------
# Заполняет массив VERIFY[] парами "проверка|OK/FAIL|детали" и
# возвращает 0 только если ВСЕ проверки прошли.
verify_warp() {
    VERIFY=()
    local ok=1 st trace warp_flag ip_warp ip_direct

    # 1. сервис warp-svc
    if command -v systemctl >/dev/null 2>&1 && systemctl cat warp-svc.service >/dev/null 2>&1; then
        if systemctl is-active --quiet warp-svc; then
            VERIFY+=("warp-svc активен|OK|")
        else
            VERIFY+=("warp-svc активен|FAIL|сервис остановлен")
            ok=0
        fi
    else
        VERIFY+=("warp-svc активен|OK|systemd не найден, пропущено")
    fi

    # 2. статус warp-cli
    st=$(warp_status)
    if [ "$st" = "connected" ]; then
        VERIFY+=("warp-cli статус Connected|OK|")
    else
        VERIFY+=("warp-cli статус Connected|FAIL|статус: $st")
        ok=0
    fi

    # 3. SOCKS-прокси отвечает + 4. warp=on в cdn-cgi/trace через прокси
    trace=$(curl -s --max-time "$CURL_TIMEOUT" --socks5-hostname "$WARP_SOCKS" \
                 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    if [ -z "$trace" ]; then
        VERIFY+=("SOCKS-прокси отвечает|FAIL|$WARP_SOCKS не отвечает")
        VERIFY+=("trace через прокси: warp=on|FAIL|нет ответа")
        ok=0
    else
        VERIFY+=("SOCKS-прокси отвечает|OK|$WARP_SOCKS")
        warp_flag=$(printf '%s\n' "$trace" | sed -n 's/^warp=//p' | head -1)
        if [ "$warp_flag" = "on" ]; then
            VERIFY+=("trace через прокси: warp=on|OK|трафик выходит через WARP")
        else
            VERIFY+=("trace через прокси: warp=on|FAIL|warp=${warp_flag:-?} — трафик НЕ через WARP")
            ok=0
        fi
    fi

    # 5. IP выхода через WARP отличается от прямого IP
    ip_warp=$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | head -1)
    ip_direct=$(curl -s --max-time "$IP_TIMEOUT" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
                | sed -n 's/^ip=//p' | head -1)
    VERIFY+=("IP выхода напрямую|INFO|${ip_direct:-недоступен}")
    if [ -n "$ip_warp" ] && [ -n "$ip_direct" ] && [ "$ip_warp" != "$ip_direct" ]; then
        VERIFY+=("IP через WARP != прямой IP|OK|warp: $ip_warp / direct: $ip_direct")
    elif [ -z "$ip_warp" ]; then
        VERIFY+=("IP через WARP != прямой IP|FAIL|IP через WARP не получен")
        ok=0
    else
        VERIFY+=("IP через WARP != прямой IP|FAIL|совпадают ($ip_warp) — трафик идёт мимо WARP")
        ok=0
    fi

    WARP_IP="${ip_warp:-недоступен}"
    DIRECT_IP="${ip_direct:-недоступен}"
    [ "$ok" -eq 1 ]
}

print_verify() {
    local row name res det
    for row in "${VERIFY[@]:-}"; do
        [ -n "$row" ] || continue
        IFS='|' read -r name res det <<< "$row"
        if [ -n "$det" ]; then
            printf '  [%s] %-32s %s\n' "$res" "$name" "$det"
        else
            printf '  [%s] %-32s\n' "$res" "$name"
        fi
    done
}

# ---------- перезапуск WARP ----------
warp_restart() {
    # $1 = номер круга
    log "перезапуск WARP (круг $1/$HEAL_ROUNDS): disconnect + restart warp-svc + connect"
    $WARP_CLI disconnect >/dev/null 2>&1 || true
    if command -v systemctl >/dev/null 2>&1 && systemctl cat warp-svc.service >/dev/null 2>&1; then
        systemctl restart warp-svc 2>/dev/null || systemctl start warp-svc 2>/dev/null || true
    fi
    sleep 3
    # на случай, если клиент оказался не в режиме прокси — вернуть WarpProxy
    $WARP_CLI mode proxy >/dev/null 2>&1 || true
    $WARP_CLI proxy port "$WARP_PROXY_PORT" >/dev/null 2>&1 || true
    $WARP_CLI connect >/dev/null 2>&1 || true
    sleep "$HEAL_WAIT"
}

# ---------- egress-тесты ----------
# $1 = url, $2 = "" (через WARP socks) или "direct" (напрямую)
probe_site() {
    local url="$1" mode="${2:-}" args=()
    if [ "$mode" != "direct" ]; then
        args+=(--socks5-hostname "$WARP_SOCKS")
    fi
    curl -sS -o /dev/null -w '%{http_code} %{time_total}' \
         --max-time "$CURL_TIMEOUT" "${args[@]}" "$url" 2>/dev/null || echo "000 0"
}

# строка в блок отчёта (без под-shell — счётчики EG_OK/EG_FAIL живут в текущем shell)
egress_line() {
    EGRESS_BLOCK="${EGRESS_BLOCK}$1
"
}

run_egress_tests() {
    # $1 = "" (через WARP) или "direct"; наполняет EGRESS_BLOCK и EG_OK / EG_FAIL
    local mode="${1:-}" label url code t name
    if [ "$mode" = "direct" ]; then label="напрямую"; else label="через WARP ($WARP_SOCKS)"; fi
    egress_line "egress-тесты $label:"
    for url in $SITES; do
        name=$(printf '%s' "$url" | sed -e 's|^https\?://||' -e 's|/$||')
        read -r code t < <(probe_site "$url" "$mode")
        if [ "$code" = "000" ] || [ "$code" = "0" ] || [ -z "$code" ]; then
            egress_line "$(printf '  %-28s FAIL (нет ответа за %ss)' "$name" "$CURL_TIMEOUT")"
            if [ "$mode" != "direct" ]; then EG_FAIL=$((EG_FAIL+1)); fi
        elif [ "$code" -ge 200 ] && [ "$code" -lt 400 ]; then
            egress_line "$(printf '  %-28s %s  %ss  OK' "$name" "$code" "$t")"
            if [ "$mode" != "direct" ]; then EG_OK=$((EG_OK+1)); fi
        elif [ "$code" -ge 400 ] && [ "$code" -lt 600 ]; then
            # 4xx/5xx = сервер ответил, туннель работает (антибот/контент — не проблема WARP)
            egress_line "$(printf '  %-28s %s  %ss  OK (туннель работает, HTTP %s от сервера)' "$name" "$code" "$t" "$code")"
            if [ "$mode" != "direct" ]; then EG_OK=$((EG_OK+1)); fi
        else
            egress_line "$(printf '  %-28s %s  %ss  FAIL' "$name" "$code" "$t")"
            if [ "$mode" != "direct" ]; then EG_FAIL=$((EG_FAIL+1)); fi
        fi
    done
}

# ---------- отчёт ----------
write_report() {
    {
        echo "=== warp-monitor v$VERSION — $(_ts) ==="
        echo "host: $(hostname 2>/dev/null || echo '?')"
        echo "warp-cli: $(warp_cli_ok && echo 'найден' || echo 'НЕ УСТАНОВЛЕН')"
        echo "IP выхода через WARP: $WARP_IP"
        echo "IP выхода напрямую:   $DIRECT_IP"
        echo
        echo "Верификация WARP:"
        print_verify
        echo
        printf '%s\n' "$EGRESS_BLOCK"
        echo
        echo "Итог: $SUMMARY"
    } > "$REPORT_FILE" 2>/dev/null || true
}

# ---------- команды ----------
cmd_check() {
    prepare_dirs
    load_conf

    if ! warp_cli_ok; then
        WARP_IP="недоступен"; DIRECT_IP="недоступен"
        VERIFY=("warp-cli установлен|FAIL|warp-cli не найден в PATH")
        EG_OK=0; EG_FAIL=0; EGRESS_BLOCK=""
        run_egress_tests direct
        SUMMARY="CRIT: warp-cli не установлен — мониторинг невозможен"
        write_report
        log "$SUMMARY"
        out "$SUMMARY"
        return 2
    fi

    local st i
    st=$(warp_status)
    if [ "$st" = "unregistered" ]; then
        WARP_IP="недоступен"; DIRECT_IP="недоступен"
        VERIFY=("warp-cli зарегистрирован|FAIL|Registration Missing — нужен: warp-cli --accept-tos registration new")
        EG_OK=0; EG_FAIL=0; EGRESS_BLOCK=""
        run_egress_tests direct
        SUMMARY="CRIT: WARP не зарегистрирован — регистрацию нужно выполнить вручную"
        write_report
        log "$SUMMARY"
        out "$SUMMARY"
        return 2
    fi

    # --- верификация + перезапуск при сбое ---
    if verify_warp; then
        log "верификация WARP: все проверки OK — перезапуск не требуется"
    else
        log "верификация WARP: ЕСТЬ ПРОВАЛЫ — запускаю перезапуск"
        print_verify | tee -a "$LOG_FILE" >&2
        for i in $(seq 1 "$HEAL_ROUNDS"); do
            warp_restart "$i"
            if verify_warp; then
                log "перезапуск помог: WARP работает (круг $i/$HEAL_ROUNDS)"
                break
            fi
            log "круг $i/$HEAL_ROUNDS: WARP всё ещё не работает"
        done
    fi

    # --- egress-тесты ---
    EG_OK=0; EG_FAIL=0; EGRESS_BLOCK=""
    if printf '%s\n' "${VERIFY[@]:-}" | grep -q '|FAIL|'; then
        SUMMARY="CRIT: WARP НЕ работает после $HEAL_ROUNDS перезапусков (детали в отчёте)"
        run_egress_tests direct
        write_report
        log "$SUMMARY"
        out "$SUMMARY"
        return 2
    fi

    run_egress_tests
    if [ "$RUN_DIRECT_TEST" = "1" ]; then
        run_egress_tests direct
    fi

    if [ "$EG_FAIL" -gt 0 ]; then
        SUMMARY="WARN: WARP работает (warp=on), но $EG_FAIL из $((EG_OK+EG_FAIL)) сайтов не ответили через туннель"
        write_report
        log "$SUMMARY"
        out "$SUMMARY"
        return 1
    fi

    SUMMARY="OK: WARP работает (warp=on, IP выхода: $WARP_IP), все $EG_OK сайтов доступны через туннель"
    write_report
    log "$SUMMARY"
    out "$SUMMARY"
    return 0
}

cmd_egress() {
    prepare_dirs
    load_conf
    EG_OK=0; EG_FAIL=0; EGRESS_BLOCK=""
    run_egress_tests
    printf '%s' "$EGRESS_BLOCK"
    out "IP выхода через WARP: $(curl -s --max-time "$IP_TIMEOUT" --socks5-hostname "$WARP_SOCKS" https://api.ipify.org 2>/dev/null || echo недоступен)"
}

cmd_status() {
    load_conf
    echo "warp-cli:  $(warp_cli_ok && echo 'найден' || echo 'НЕ УСТАНОВЛЕН')"
    echo "warp:      $(warp_status)"
    echo "socks:     $WARP_SOCKS"
    if [ -f "$REPORT_FILE" ]; then
        echo
        echo "--- последний отчёт ($REPORT_FILE) ---"
        tail -n 30 "$REPORT_FILE"
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
    log "включаю режим WarpProxy на порту $WARP_PROXY_PORT"
    $WARP_CLI mode proxy >/dev/null 2>&1 || true
    $WARP_CLI proxy port "$WARP_PROXY_PORT" >/dev/null 2>&1 || true
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
# warp-monitor — почасовая проверка WARP (100% верификация) + egress-тесты
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
}

cmd_uninstall() {
    rm -f /etc/cron.d/warp-monitor /etc/logrotate.d/warp-monitor
    log "cron и logrotate удалены (логи и отчёты сохранены в $LOG_DIR / $STATE_DIR)"
    out "Удалено."
}

usage() {
    sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------- main ----------
main() {
    local cmd="check" a
    for a in "$@"; do
        case "$a" in
            --quiet)   QUIET=1 ;;
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
        *)            usage; exit 2 ;;
    esac
}

main "$@"
