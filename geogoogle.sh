#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

# Установщик для Linux: bash geogoogle.sh
# Docker должен быть установлен и запущен на этой ноде.
if [ "$#" -ne 0 ]; then
    echo "Запустите без аргументов: bash $0. Данные будут запрошены по очереди." >&2
    exit 1
fi

if [ "$(uname -s)" != "Linux" ] || [ "$(id -u)" -ne 0 ]; then
    echo "Запустите установщик от root на Linux-сервере." >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "Docker не установлен, не запущен или недоступен." >&2
    exit 1
fi

# Отдельный терминал позволяет спрашивать данные и при запуске curl ... | bash.
if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    echo "Для ввода токена, chat ID и имени ноды нужен интерактивный терминал." >&2
    exit 1
fi

TTY_SETTINGS=$(stty -g <&3)
restore_terminal() {
    stty "$TTY_SETTINGS" <&3 2>/dev/null || true
}
trap restore_terminal EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

read_required() {
    local variable="$1" prompt="$2" secret="${3:-0}" value
    if [ "$secret" -eq 1 ]; then
        stty -echo <&3
    fi
    while true; do
        if [ "$secret" -eq 1 ]; then
            if ! IFS= read -r -s -p "$prompt" value <&3; then
                printf '\nВвод прерван.\n' >&3
                exit 1
            fi
            printf '\n' >&3
        elif ! IFS= read -r -p "$prompt" value <&3; then
            printf '\nВвод прерван.\n' >&3
            exit 1
        fi
        if [[ "$value" =~ [^[:space:]] ]]; then
            printf -v "$variable" '%s' "$value"
            restore_terminal
            return 0
        fi
        printf 'Значение не должно быть пустым.\n' >&3
    done
}

read_required BOT_TOKEN 'Токен бота: ' 1
read_required CHAT_ID 'Chat ID: '
read_required NODE_NAME 'Имя ноды: '
restore_terminal
trap - EXIT INT TERM
exec 3>&-

INSTALL_DIR="/opt/geogoogle"
CONTAINER_NAME="geogoogle"
IMAGE_NAME="geogoogle:local"
MANAGED_LABEL="io.geogoogle.managed"
HAD_CONTAINER=0
OLD_WAS_RUNNING=0
OLD_STOPPED=0
BACKUP_CREATED=0
BACKUP_NAME="geogoogle-backup-$$"

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    if [ "$(docker inspect -f '{{ index .Config.Labels "io.geogoogle.managed" }}' "$CONTAINER_NAME")" != "true" ]; then
        echo "Контейнер geogoogle уже существует и создан другим способом. Переименуйте его перед установкой." >&2
        exit 1
    fi
    HAD_CONTAINER=1
    if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" = "true" ]; then
        OLD_WAS_RUNNING=1
    fi
fi

umask 077
mkdir -p "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR"

CONFIG_BACKUP=""
INSTALL_SUCCEEDED=0
if [ -f "$INSTALL_DIR/config.sh" ]; then
    CONFIG_BACKUP=$(mktemp "$INSTALL_DIR/.config-backup.XXXXXX")
    cp -p "$INSTALL_DIR/config.sh" "$CONFIG_BACKUP"
fi

restore_config() {
    if [ -n "$CONFIG_BACKUP" ]; then
        cp -p "$CONFIG_BACKUP" "$INSTALL_DIR/config.sh"
    else
        rm -f "$INSTALL_DIR/config.sh"
    fi
}

finish_installation() {
    local result=$?
    if [ "$INSTALL_SUCCEEDED" -eq 0 ]; then
        restore_config || true
        if [ "$BACKUP_CREATED" -eq 1 ]; then
            docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
            docker rename "$BACKUP_NAME" "$CONTAINER_NAME" || true
        fi
        if [ "$OLD_STOPPED" -eq 1 ]; then
            if docker start "$CONTAINER_NAME" >/dev/null; then
                echo "Предыдущий контейнер восстановлен." >&2
            else
                echo "Не удалось запустить предыдущий контейнер." >&2
            fi
        fi
    fi
    if [ -n "$CONFIG_BACKUP" ]; then
        rm -f "$CONFIG_BACKUP" || true
    fi
    return "$result"
}
trap finish_installation EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# %q сохраняет токен, ID и имя ноды без подстановки их содержимого в код.
# Конфигурация монтируется отдельно и не попадает в Docker-образ.
printf 'BOT_TOKEN=%q\nCHAT_ID=%q\nNODE_NAME=%q\n' \
    "$BOT_TOKEN" "$CHAT_ID" "$NODE_NAME" > "$INSTALL_DIR/config.sh"
chmod 600 "$INSTALL_DIR/config.sh"

cat > "$INSTALL_DIR/.dockerignore" <<'EOF'
*
!Dockerfile
!monitor.sh
!parse-player.py
!healthcheck.sh
EOF

cat > "$INSTALL_DIR/Dockerfile" <<'EOF'
FROM alpine:3.22
RUN apk add --no-cache bash ca-certificates curl bind-tools jq python3
WORKDIR /app
COPY monitor.sh parse-player.py healthcheck.sh /app/
RUN chmod 700 /app/monitor.sh /app/healthcheck.sh
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD ["/bin/bash", "/app/healthcheck.sh"]
ENTRYPOINT ["/bin/bash", "/app/monitor.sh"]
EOF

cat > "$INSTALL_DIR/healthcheck.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

# Проверяем локальный процесс и его продвижение, не обращаясь к внешним API.
IFS=' ' read -r monitor_pid heartbeat < /tmp/geogoogle-health
[[ "$monitor_pid" =~ ^[1-9][0-9]*$ && "$heartbeat" =~ ^[0-9]+$ ]]
kill -0 "$monitor_pid" 2>/dev/null
IFS=' ' read -r uptime _ < /proc/uptime
age=$(( ${uptime%%.*} - heartbeat ))
# Ожидание часа обновляет heartbeat каждые 30 секунд. Сетевые проверки
# ограничены тайм-аутами; пять минут покрывают их суммарную длительность.
[ "$age" -ge 0 ] && [ "$age" -le 300 ]
EOF

cat > "$INSTALL_DIR/parse-player.py" <<'EOF'
import json
import re
import sys
from html.parser import HTMLParser


class ScriptParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.scripts = []
        self.current = None

    def handle_starttag(self, tag, attrs):
        if tag == "script":
            self.current = []

    def handle_data(self, data):
        if self.current is not None:
            self.current.append(data)

    def handle_endtag(self, tag):
        if tag == "script" and self.current is not None:
            self.scripts.append("".join(self.current))
            self.current = None


parser = ScriptParser()
parser.feed(sys.stdin.read())
decoder = json.JSONDecoder()
pattern = re.compile(
    r'''(?:\bytInitialPlayerResponse\b|window\s*\[\s*["']ytInitialPlayerResponse["']\s*\])\s*=\s*'''
    r'''|["']ytInitialPlayerResponse["']\s*:\s*'''
)
playable = False
for script in parser.scripts:
    for match in pattern.finditer(script):
        try:
            player, _ = decoder.raw_decode(script, match.end())
        except (ValueError, RecursionError):
            continue
        if not isinstance(player, dict):
            continue
        status = player.get("playabilityStatus")
        if not isinstance(status, dict) or status.get("status") != "OK":
            continue
        placements = player.get("adPlacements", [])
        if not isinstance(placements, list):
            continue
        if placements:
            print("ADS")
            sys.exit(0)
        playable = True
print("NOADS" if playable else "UNKNOWN")
EOF

cat > "$INSTALL_DIR/monitor.sh" <<'EOF'
#!/bin/bash
set -uo pipefail

# Файл создан установщиком через printf %q и смонтирован только для чтения.
# shellcheck source=/dev/null
source /run/geogoogle-config.sh
: "${BOT_TOKEN:?BOT_TOKEN не задан}"
: "${CHAT_ID:?CHAT_ID не задан}"
: "${NODE_NAME:?NODE_NAME не задан}"

DNS_SERVER="8.8.8.8"
DNS_SERVER_ALT="1.1.1.1"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
YT_COOKIE="CONSENT=YES+cb.20210328-17-p0.en+FX+000; SOCS=CAI"
AD_VIDEO_IDS="dQw4w9WgXcQ kJQP7kiw5Fk 9bZkp7q19f0"
IP_YOUTUBE=""
IP_TELEGRAM=""
IP_IPECHO=""
SLEEP_PID=""
HEALTH_FILE="/tmp/geogoogle-health"

log() {
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*"
}

shutdown() {
    if [ -n "$SLEEP_PID" ]; then
        kill "$SLEEP_PID" 2>/dev/null || true
    fi
    exit 0
}
trap shutdown TERM INT

update_health() {
    local uptime
    IFS=' ' read -r uptime _ < /proc/uptime || return 1
    printf '%s %s\n' "$$" "${uptime%%.*}" > "$HEALTH_FILE.tmp" \
        && mv "$HEALTH_FILE.tmp" "$HEALTH_FILE"
}

next_hour() {
    local now="$1"
    printf '%s' "$(( (now / 3600 + 1) * 3600 ))"
}

wait_for_hour() {
    local now previous delay
    previous=$(date +%s)
    NEXT_RUN=$(next_hour "$previous")
    while true; do
        update_health || return 1
        now=$(date +%s)
        if [ "$now" -lt "$previous" ]; then
            NEXT_RUN=$(next_hour "$now")
        fi
        previous="$now"
        if [ "$now" -ge "$NEXT_RUN" ]; then
            if [ "$((now % 3600))" -lt 60 ]; then
                # После паузы контейнера допускаем только начало текущего часа.
                NEXT_RUN=$((now / 3600 * 3600))
                return 0
            fi
            log "Начало часа пропущено; ждём следующего часа."
            NEXT_RUN=$(next_hour "$now")
        fi
        delay=$((NEXT_RUN - now))
        [ "$delay" -le 30 ] || delay=30
        sleep "$delay" &
        SLEEP_PID=$!
        wait "$SLEEP_PID" || true
        SLEEP_PID=""
    done
}

resolve_host() {
    local host="$1" ip=""
    ip=$(dig +short +time=3 +tries=2 "@$DNS_SERVER" A "$host" 2>/dev/null \
        | grep -m1 -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$')

    if [ -z "$ip" ]; then
        ip=$(curl -4 -fsS --connect-timeout 5 --max-time 10 \
            --resolve "dns.google:443:$DNS_SERVER" \
            "https://dns.google/resolve?name=$host&type=A" \
            | jq -r '[.Answer[]? | select(.type == 1) | .data][0] // empty')
    fi
    if [ -z "$ip" ]; then
        ip=$(curl -4 -fsS --connect-timeout 5 --max-time 10 \
            --resolve "cloudflare-dns.com:443:$DNS_SERVER_ALT" \
            -H 'accept: application/dns-json' \
            "https://cloudflare-dns.com/dns-query?name=$host&type=A" \
            | jq -r '[.Answer[]? | select(.type == 1) | .data][0] // empty')
    fi
    printf '%s' "$ip"
}

init_dns() {
    IP_YOUTUBE=$(resolve_host "www.youtube.com")
    IP_TELEGRAM=$(resolve_host "api.telegram.org")
    IP_IPECHO=$(resolve_host "ifconfig.me")
}

curl_dns() {
    local url="$1" host ip=""
    shift
    host=${url#https://}
    host=${host%%/*}
    case "$host" in
        www.youtube.com) ip="$IP_YOUTUBE" ;;
        api.telegram.org) ip="$IP_TELEGRAM" ;;
        ifconfig.me) ip="$IP_IPECHO" ;;
    esac
    local -a resolve_args=()
    if [ -n "$ip" ]; then
        resolve_args=(--resolve "$host:443:$ip")
    fi
    curl -4 -fsSL --connect-timeout 5 --max-time 20 "${resolve_args[@]}" "$@" "$url"
}

# Сохранён список стран без рекламы из предыдущей версии скрипта.
# Для регионов вне списка дополнительно проверяем рекламные блоки плеера.
is_ad_free_region() {
    case "$1" in
        RU|BY|AL|MD|AD|MC|MN|KH|LA|MM|MO|MV|BS|MG|CI|IR|SY|CU|KP|SD|AF) return 0 ;;
        *) return 1 ;;
    esac
}

get_region() {
    curl_dns "https://www.youtube.com" -A "$UA" -b "$YT_COOKIE" \
        | grep -oE '"GL"[[:space:]]*:[[:space:]]*"[A-Z]{2}"' \
        | head -n 1 | cut -d'"' -f4
}

check_ads() {
    local video html status playable=0
    for video in $AD_VIDEO_IDS; do
        if ! html=$(curl_dns "https://www.youtube.com/watch?v=$video" -A "$UA" -b "$YT_COOKIE"); then
            continue
        fi
        status=$(printf '%s' "$html" | python3 /app/parse-player.py)
        case "$status" in
            ADS) printf 'ADS'; return 0 ;;
            NOADS) playable=1 ;;
        esac
    done
    if [ "$playable" -eq 1 ]; then
        printf 'NOADS'
    else
        printf 'UNKNOWN'
    fi
}

send_telegram() {
    local response
    if ! response=$(curl_dns "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -X POST \
        --data-urlencode chat_id="$CHAT_ID" --data-urlencode text="$1"); then
        log "Ошибка отправки в Telegram; повторим при следующей проверке." >&2
        return 1
    fi
    if ! printf '%s' "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
        log "Telegram не подтвердил отправку; повторим при следующей проверке." >&2
        return 1
    fi
}

monitor_once() {
    local region ad_status server_ip
    init_dns
    region=$(get_region)
    if ! [[ "$region" =~ ^[A-Z]{2}$ ]]; then
        log "Регион YouTube не получен. Мониторинг продолжается." >&2
        return 0
    fi

    if is_ad_free_region "$region"; then
        log "Регион YouTube: $region — без рекламы по списку."
        return 0
    fi

    ad_status=$(check_ads)
    case "$ad_status" in
        ADS) log "Регион YouTube: $region — обнаружены рекламные блоки adPlacements." ;;
        NOADS) log "Регион YouTube: $region — рекламные блоки не обнаружены."; return 0 ;;
        *) log "Регион YouTube: $region — плеер недоступен, реклама не проверена." >&2; return 0 ;;
    esac

    server_ip=$(curl_dns "https://ifconfig.me")
    server_ip="${server_ip:-неизвестен}"
    send_telegram "⚠️ Нода: $NODE_NAME ($server_ip)
YouTube определяет регион: $region — страна вне списка регионов без рекламы.
В плеере видео обнаружены рекламные блоки adPlacements.
Следующая проверка в начале следующего часа. Пока реклама подтверждается, уведомления будут каждый час."
}

log "Мониторинг ноды $NODE_NAME запущен; проверки в 00 минут каждого часа."
while true; do
    if ! wait_for_hour; then
        log "Не удалось обновить состояние планировщика." >&2
        exit 1
    fi
    if ! monitor_once; then
        log "Проверка завершилась с ошибкой. Мониторинг продолжается." >&2
    fi
    update_health || exit 1
done
EOF

echo "Сборка образа $IMAGE_NAME..."
docker build -t "$IMAGE_NAME" "$INSTALL_DIR"

# Предыдущий контейнер сохраняется до успешного старта нового.
if [ "$HAD_CONTAINER" -eq 1 ]; then
    docker stop "$CONTAINER_NAME" >/dev/null
    OLD_STOPPED="$OLD_WAS_RUNNING"
    docker rename "$CONTAINER_NAME" "$BACKUP_NAME"
    BACKUP_CREATED=1
fi

start_container() {
    local attempt state running health
    docker run -d \
        --name "$CONTAINER_NAME" \
        --init \
        --label "$MANAGED_LABEL=true" \
        --restart unless-stopped \
        --network host \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --tmpfs /tmp:rw,noexec,nosuid,size=16m \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        --mount "type=bind,src=$INSTALL_DIR/config.sh,dst=/run/geogoogle-config.sh,readonly" \
        "$IMAGE_NAME" >/dev/null || return 1

    echo "Ожидание состояния healthy (до 90 секунд)..."
    for ((attempt=0; attempt<45; attempt++)); do
        state=$(docker inspect -f '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CONTAINER_NAME") || return 1
        read -r running health <<< "$state"
        [ "$running" = "true" ] || return 1
        case "$health" in
            healthy) return 0 ;;
            starting) sleep 2 ;;
            *) return 1 ;;
        esac
    done
    return 1
}

if ! start_container; then
    echo "Контейнер geogoogle не запустился или не прошёл healthcheck." >&2
    docker logs "$CONTAINER_NAME" >&2 || true
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    exit 1
fi

INSTALL_SUCCEEDED=1
if [ "$HAD_CONTAINER" -eq 1 ]; then
    docker rm "$BACKUP_NAME" >/dev/null
fi

# Отключаем старую проверялку только после запуска контейнера.
if command -v crontab >/dev/null 2>&1; then
    LEGACY_CRON=$(crontab -l 2>/dev/null || true)
    if [[ "$LEGACY_CRON" == *"/opt/yt-geo-monitoring.sh"* ]]; then
        if printf '%s\n' "$LEGACY_CRON" | awk 'index($0, "/opt/yt-geo-monitoring.sh") == 0' | crontab -; then
            rm -f /opt/yt-geo-monitoring.sh /opt/.yt-geo-monitoring.state /opt/.yt-geo-monitoring.lock
            echo "Старая проверялка удалена из cron."
        else
            echo "Не удалось удалить старую запись из cron; удалите её вручную." >&2
        fi
    fi
fi

echo "Контейнер geogoogle запущен: первая проверка в начале следующего часа, далее в HH:00."
echo "Telegram: каждый час, только если регион вне списка стран без рекламы и найдены adPlacements."
echo "Healthcheck: каждые 30 секунд; проверка процесса и heartbeat планировщика."
echo "Логи: docker logs -f geogoogle"
echo "Остановить: docker stop geogoogle; запустить: docker start geogoogle"
