#!/bin/sh
# ================================================================
#  SSClash Installer / Updater for OpenWrt
#  Поддерживаемые версии: 21.x / 23.05.x / 24.10.x / 25.12.x
#  Архитектуры: arm64, armv7, mipsel, mips, amd64, i386
#  https://github.com/zerolabnet/SSClash
#
#  Использование:
#    sh install-ssclash.sh            # установка / обновление
#    sh install-ssclash.sh --force    # принудительное обновление
#    sh install-ssclash.sh --help
# ================================================================

SSCLASH_API="https://api.github.com/repos/zerolabnet/SSClash/releases/latest"
MIHOMO_BASE="https://github.com/MetaCubeX/mihomo/releases"
CLASH_BIN="/opt/clash/bin/clash"
CLASH_SVC="clash"

# Заполняются позже
SSCLASH_VER=""
SSCLASH_APK_URL=""
SSCLASH_IPK_URL=""
MIHOMO_VER=""
MIHOMO_ARCH=""
PKG_MGR=""
TPROXY_PKG=""
PKG_UPDATED=0
FORCE=0
CLASH_WAS_RUNNING=0

# ── цвета ────────────────────────────────────────────────────────
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
    R=$(printf '\033[0;31m') G=$(printf '\033[0;32m') Y=$(printf '\033[1;33m')
    C=$(printf '\033[0;36m') B=$(printf '\033[1m')    N=$(printf '\033[0m')
else
    R='' G='' Y='' C='' B='' N=''
fi
log()  { printf "%s[+]%s %s\n"      "$G" "$N" "$*"; }
info() { printf "%s[i]%s %s\n"      "$C" "$N" "$*"; }
warn() { printf "%s[!]%s %s\n"      "$Y" "$N" "$*"; }
ok()   { printf "%s[✓]%s %s\n"      "$G" "$N" "$*"; }
die()  { printf "%s[✗] %s%s\n"      "$R" "$*" "$N" >&2; exit 1; }
skip() { printf "%s[~]%s %s\n"      "$C" "$N" "$*"; }
sep()  { printf "%s%s%s\n"          "$C" "────────────────────────────────────────" "$N"; }

# ================================================================
#  Аргументы
# ================================================================
parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --force|-f) FORCE=1 ;;
            --help|-h)
                printf "Использование: %s [--force] [--help]\n" "$0"
                printf "  (без флагов)  — установка или обновление до последних версий\n"
                printf "  --force, -f   — обновить даже если версии совпадают\n"
                exit 0
                ;;
            *) warn "Неизвестный аргумент: $arg (игнорирую)" ;;
        esac
    done
}

# ================================================================
#  0. Гарантируем наличие curl
# ================================================================
ensure_curl() {
    if command -v curl >/dev/null 2>&1; then
        info "curl: $(curl --version | head -1 | cut -d' ' -f1-2)"
        return 0
    fi
    warn "curl не найден — устанавливаю..."
    if [ "$PKG_MGR" = "apk" ]; then
        apk update   || die "apk update завершился с ошибкой"
        apk add curl || die "Не удалось установить curl"
    else
        opkg update       || die "opkg update завершился с ошибкой"
        opkg install curl || die "Не удалось установить curl"
    fi
    command -v curl >/dev/null 2>&1 || die "curl всё равно недоступен после установки"
    log "curl установлен"
    PKG_UPDATED=1
}

# ================================================================
#  1. Версия OpenWrt и пакетный менеджер
# ================================================================
detect_openwrt() {
    [ -f /etc/openwrt_release ] || die "Не найден /etc/openwrt_release — это OpenWrt?"
    . /etc/openwrt_release

    OW_RELEASE="${DISTRIB_RELEASE:-unknown}"
    OW_MAJOR=$(echo "$OW_RELEASE" | cut -d. -f1)

    info "OpenWrt: ${B}${OW_RELEASE}${N}"

    if [ "${OW_MAJOR:-0}" -ge 25 ] 2>/dev/null; then
        PKG_MGR="apk"
    else
        PKG_MGR="opkg"
    fi
    info "Пакетный менеджер: ${B}${PKG_MGR}${N}"

    if [ "${OW_MAJOR:-0}" -le 21 ] 2>/dev/null; then
        TPROXY_PKG="iptables-mod-tproxy"
    else
        TPROXY_PKG="kmod-nft-tproxy"
    fi
    info "Пакет tproxy: ${B}${TPROXY_PKG}${N}"
}

# ================================================================
#  2. Архитектура
# ================================================================
detect_arch() {
    ARCH_RAW=$(uname -m)
    . /etc/openwrt_release
    TARGET="${DISTRIB_TARGET:-}"
    ARCH_PKG="${DISTRIB_ARCH:-}"

    info "CPU (uname -m): ${B}${ARCH_RAW}${N}"
    info "OpenWrt target: ${B}${TARGET}${N}"
    info "DISTRIB_ARCH:   ${B}${ARCH_PKG}${N}"

    case "$ARCH_RAW" in
        aarch64)        MIHOMO_ARCH="arm64"           ;;
        armv7l|armv6l)  MIHOMO_ARCH="armv7"           ;;
        mipsel)         MIHOMO_ARCH="mipsle-softfloat" ;;
        mips)           MIHOMO_ARCH="mips-softfloat"   ;;
        x86_64)         MIHOMO_ARCH="amd64-compatible" ;;
        i686|i386)      MIHOMO_ARCH="386"              ;;
        *)
            warn "Неизвестная архитектура: ${ARCH_RAW}"
            warn "Доступные ядра: ${MIHOMO_BASE}/latest"
            MIHOMO_ARCH=""
            ;;
    esac

    [ -n "$MIHOMO_ARCH" ] && info "Ядро mihomo: ${B}mihomo-linux-${MIHOMO_ARCH}${N}"
}

# ================================================================
#  3. Получение последних версий (GitHub API / releases)
# ================================================================
fetch_versions() {
    log "Проверяю актуальные версии..."

    # --- SSClash ---
    RELEASE_JSON=$(curl -sf -L "$SSCLASH_API") \
        || die "Не удалось получить данные релиза SSClash (GitHub API)"
    [ -z "$RELEASE_JSON" ] && die "GitHub API вернул пустой ответ"

    SSCLASH_VER=$(printf '%s' "$RELEASE_JSON" \
        | grep '"tag_name"' | head -1 \
        | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/')
    [ -z "$SSCLASH_VER" ] && die "Не удалось распарсить tag_name SSClash"

    SSCLASH_APK_URL=$(printf '%s' "$RELEASE_JSON" \
        | grep '"browser_download_url"' | grep '\.apk"' | head -1 \
        | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    SSCLASH_IPK_URL=$(printf '%s' "$RELEASE_JSON" \
        | grep '"browser_download_url"' | grep '\.ipk"' | head -1 \
        | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    # Берём полную версию с revision из имени файла asset (например 4.5.1-r1),
    # чтобы корректно сравнивать с тем что вернёт opkg/apk info.
    # apk:  luci-app-ssclash-4.5.1-r1.apk  → 4.5.1-r1
    # ipk:  luci-app-ssclash_4.5.1-r1_all.ipk → 4.5.1-r1
    if [ -n "$SSCLASH_APK_URL" ]; then
        SSCLASH_FULL_VER=$(basename "$SSCLASH_APK_URL" .apk \
            | sed 's/luci-app-ssclash-//')
    elif [ -n "$SSCLASH_IPK_URL" ]; then
        SSCLASH_FULL_VER=$(basename "$SSCLASH_IPK_URL" | cut -d_ -f2)
    else
        SSCLASH_FULL_VER="$SSCLASH_VER"
    fi

    info "SSClash последняя:    ${B}v${SSCLASH_FULL_VER}${N}"

    # --- mihomo ---
    if [ -n "$MIHOMO_ARCH" ]; then
        MIHOMO_VER=$(curl -sf -L "${MIHOMO_BASE}/latest" \
            | grep "title>Release" | head -1 | cut -d " " -f 4 | tr -d '\r\n')
        [ -z "$MIHOMO_VER" ] && die "Не удалось получить версию mihomo"
        info "mihomo последняя:    ${B}${MIHOMO_VER}${N}"
    fi
}

# ================================================================
#  4. Определение установленных версий
# ================================================================
get_installed_versions() {
    # SSClash: читаем из метаданных пакета
    INSTALLED_SSCLASH=""
    if [ "$PKG_MGR" = "apk" ]; then
        INSTALLED_SSCLASH=$(apk info luci-app-ssclash 2>/dev/null \
            | grep '^luci-app-ssclash-' | head -1 \
            | sed 's/luci-app-ssclash-\([0-9][^-]*\).*/\1/')
    else
        INSTALLED_SSCLASH=$(opkg list-installed luci-app-ssclash 2>/dev/null \
            | head -1 | awk '{print $3}')
    fi

    # mihomo: запускаем бинарник с флагом -v
    INSTALLED_MIHOMO=""
    if [ -x "$CLASH_BIN" ]; then
        INSTALLED_MIHOMO=$("$CLASH_BIN" -v 2>/dev/null \
            | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi

    if [ -n "$INSTALLED_SSCLASH" ]; then
        info "SSClash установлен:   ${B}v${INSTALLED_SSCLASH}${N}"
    else
        info "SSClash установлен:   ${B}нет${N}"
    fi

    if [ -n "$INSTALLED_MIHOMO" ]; then
        info "mihomo установлен:    ${B}${INSTALLED_MIHOMO}${N}"
    else
        info "mihomo установлен:    ${B}нет${N}"
    fi
}

# ================================================================
#  5. Обновление индекса пакетов
# ================================================================
pkg_update() {
    if [ "$PKG_UPDATED" = "1" ]; then
        skip "Индекс пакетов уже обновлён"
        return 0
    fi
    log "Обновление списка пакетов..."
    if [ "$PKG_MGR" = "apk" ]; then
        apk update  || die "apk update завершился с ошибкой"
    else
        opkg update || die "opkg update завершился с ошибкой"
    fi
    PKG_UPDATED=1
}

# ================================================================
#  6. Зависимости (только при первой установке SSClash)
# ================================================================
install_deps() {
    if [ -n "$INSTALLED_SSCLASH" ]; then
        skip "Зависимости уже установлены (пропускаю при обновлении)"
        return 0
    fi
    log "Установка зависимостей..."
    if [ "$PKG_MGR" = "apk" ]; then
        apk add curl "$TPROXY_PKG" kmod-tun coreutils-base64 \
            || die "Ошибка установки зависимостей"
    else
        opkg install curl "$TPROXY_PKG" kmod-tun coreutils-base64 \
            || die "Ошибка установки зависимостей"
    fi
}

# ================================================================
#  7. Управление сервисом clash
# ================================================================
clash_is_running() {
    # Проверяем через init.d — работает на всех версиях OpenWrt
    /etc/init.d/"$CLASH_SVC" status 2>/dev/null | grep -qi "running"
}

clash_stop() {
    log "Останавливаю сервис clash..."
    /etc/init.d/"$CLASH_SVC" stop 2>/dev/null || true
    # Ждём освобождения файла (до 5 секунд)
    i=0
    while [ $i -lt 5 ]; do
        # fuser недоступен в busybox; проверяем через /proc
        if ! grep -rl "$CLASH_BIN" /proc/*/exe 2>/dev/null | grep -q .; then
            break
        fi
        sleep 1
        i=$((i + 1))
    done
}

# ================================================================
#  8. Установка / обновление luci-app-ssclash
# ================================================================
install_ssclash() {
    # Проверка необходимости обновления
    if [ -n "$INSTALLED_SSCLASH" ] && [ "$INSTALLED_SSCLASH" = "$SSCLASH_FULL_VER" ] \
       && [ "$FORCE" = "0" ]; then
        ok "luci-app-ssclash уже актуален (v${SSCLASH_FULL_VER}) — пропускаю"
        return 0
    fi

    if [ -n "$INSTALLED_SSCLASH" ]; then
        log "Обновление luci-app-ssclash: v${INSTALLED_SSCLASH} → v${SSCLASH_FULL_VER}..."
    else
        log "Установка luci-app-ssclash v${SSCLASH_FULL_VER}..."
    fi

    if [ "$PKG_MGR" = "apk" ]; then
        [ -z "$SSCLASH_APK_URL" ] && die "Не найден .apk в assets релиза SSClash"
        curl -L "$SSCLASH_APK_URL" -o /tmp/luci-app-ssclash.apk \
            || die "Ошибка загрузки .apk"
        apk add --allow-untrusted /tmp/luci-app-ssclash.apk \
            || die "Ошибка установки .apk"
        rm -f /tmp/luci-app-ssclash.apk
    else
        [ -z "$SSCLASH_IPK_URL" ] && die "Не найден .ipk в assets релиза SSClash"
        curl -L "$SSCLASH_IPK_URL" -o /tmp/luci-app-ssclash.ipk \
            || die "Ошибка загрузки .ipk"
        # opkg update нужен для обновления существующего пакета
        if [ -n "$INSTALLED_SSCLASH" ]; then
            opkg upgrade /tmp/luci-app-ssclash.ipk \
                || opkg install /tmp/luci-app-ssclash.ipk \
                || die "Ошибка установки .ipk"
        else
            opkg install /tmp/luci-app-ssclash.ipk \
                || die "Ошибка установки .ipk"
        fi
        rm -f /tmp/luci-app-ssclash.ipk
    fi
    ok "luci-app-ssclash v${SSCLASH_FULL_VER} установлен"
}

# ================================================================
#  9. Установка / обновление ядра mihomo
# ================================================================
install_mihomo() {
    if [ -z "$MIHOMO_ARCH" ]; then
        warn "Архитектура не определена — пропускаю установку ядра"
        warn "Вручную: ${MIHOMO_BASE}/latest"
        return 0
    fi

    # Проверка необходимости обновления
    if [ -n "$INSTALLED_MIHOMO" ] && [ "$INSTALLED_MIHOMO" = "$MIHOMO_VER" ] \
       && [ "$FORCE" = "0" ]; then
        ok "mihomo уже актуален (${MIHOMO_VER}) — пропускаю"
        return 0
    fi

    if [ -n "$INSTALLED_MIHOMO" ]; then
        log "Обновление mihomo: ${INSTALLED_MIHOMO} → ${MIHOMO_VER}..."
    else
        log "Установка ядра mihomo ${MIHOMO_VER}..."
    fi

    MIHOMO_URL="${MIHOMO_BASE}/download/${MIHOMO_VER}/mihomo-linux-${MIHOMO_ARCH}-${MIHOMO_VER}.gz"
    info "URL: ${MIHOMO_URL}"

    # Запоминаем состояние сервиса — после замены ядра перезапустим если работал.
    # Останавливать сервис не нужно: mv из tmpfs не трогает работающий inode.
    if clash_is_running; then
        CLASH_WAS_RUNNING=1
    fi

    # Скачиваем архив в RAM (/tmp = tmpfs)
    curl -L "$MIHOMO_URL" -o /tmp/clash.gz || die "Ошибка загрузки ядра mihomo"

    # Распаковываем тоже в RAM — на флешке в этот момент только один экземпляр ядра
    gunzip -c /tmp/clash.gz > /tmp/clash.new || die "Ошибка распаковки"
    rm -f /tmp/clash.gz   # сразу освобождаем RAM от архива
    chmod +x /tmp/clash.new

    # mv между разными ФС (tmpfs → flash) = копирование + атомарное переименование.
    # Старый файл на флешке удаляется только после успешной записи нового —
    # двух копий на флешке одновременно не бывает.
    mkdir -p "$(dirname "$CLASH_BIN")"
    mv /tmp/clash.new "$CLASH_BIN" || die "Ошибка перемещения ядра на место"
    rm -f /tmp/clash.new 2>/dev/null || true   # подстраховка если mv не удалил

    ok "Ядро установлено: $("$CLASH_BIN" -v 2>/dev/null | head -1)"

    # Если бэкап ядра от Dashboard существует — удаляем.
    # Dashboard создаёт его при обновлении через UI и он становится
    # устаревшим после обновления скриптом.
    BACKUP_DIR="$(dirname "$CLASH_BIN")/meta-backup"
    if [ -d "$BACKUP_DIR" ]; then
        rm -rf "$BACKUP_DIR"
        ok "Устаревший бэкап Dashboard удалён (${BACKUP_DIR})"
    fi

    # Процесс держит старый inode — перезапускаем чтобы поднять новое ядро.
    # Пауза ~0.5-1 сек: TCP-сессии переживают её без разрыва.
    if [ "$CLASH_WAS_RUNNING" = "1" ]; then
        log "Перезапускаю clash с новым ядром (пауза ~1 сек)..."
        /etc/init.d/"$CLASH_SVC" restart 2>/dev/null || true
        ok "Сервис clash перезапущен"
    fi
}

# ================================================================
#  MAIN
# ================================================================
parse_args "$@"

sep
printf "  %sSSClash Installer / Updater%s\n" "$B" "$N"
[ "$FORCE" = "1" ] && printf "  %s(режим --force: принудительное обновление)%s\n" "$Y" "$N"
sep

detect_openwrt
ensure_curl
detect_arch
sep

fetch_versions
get_installed_versions
sep

pkg_update
install_deps
sep

install_ssclash
sep

install_mihomo
sep

# Итог
printf "\n"
ok "Готово!"
printf "\n"

# Подсказки только при первой установке
if [ -z "$INSTALLED_SSCLASH" ]; then
    info "Первая установка — следующие шаги:"
    echo "  1. Открой LuCI → Services → SSClash"
    echo "  2. Вставь конфигурацию Clash/Mihomo в редактор"
    printf "  3. Нажми %sSave & Apply%s\n" "$B" "$N"
    printf "  4. Запусти сервис: %s/etc/init.d/clash start%s\n" "$B" "$N"
fi

sep

