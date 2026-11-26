#!/system/bin/sh
# RetroArch (и другие приложения из образа) и его настройки - на системы, установленные раньше.
#
# 1. APK. setup.sh ставит приложения из apps.list один раз, на первой загрузке, поэтому новый
#    APK в образе (v1.16: RetroArch 1.22.1 -> 1.22.2; v1.22: PPSSPP 1.20.4, Flycast 2.7, Aurora
#    Store 4.8.4) до систем, обновлённых по воздуху, сам не доходил. На загрузке, для каждого
#    пакета из UPDATE_PKGS: если установленный APK - не тот, что в образе, и с этим APK образа
#    ещё не пробовали (свойство-отметка persist.rg52.<имя>_apk - размер APK образа, с которым
#    попытка уже была), он ставится поверх: pm install -r. Данные приложения остаются. Путь к
#    APK берётся из apps.list: в именах APK стоит версия.
#    Без -d: приложение, которое пользователь сам обновил до более новой версии, не трогается
#    (INSTALL_FAILED_VERSION_DOWNGRADE). Поставленное из другого источника, с другой подписью
#    (INSTALL_FAILED_UPDATE_INCOMPATIBLE), тоже: отметка ставится, чтобы не пробовать на каждой
#    загрузке. Удалённое пользователем приложение не возвращается.
#
# 2. Профили геймпадов (каждую загрузку). Наши профили из /system/etc/rg52-retroarch-autoconfig
#    кладутся в каталог профилей RetroArch, если их там нет или они другие: ShanWan PS3/PC
#    (2563:0523) у RetroArch своего профиля не имеет, а SHANWAN Android gamepad (0079:181c)
#    без нашего получал по VID:PID чужой профиль Speedlink Competition Pro с четырьмя кнопками.
#    Владелец, группа и метка SELinux - как у профилей самого RetroArch.
#
# 3. Игроки 2-5 как игрок 1 (один раз, persist.rg52.retroarch_players=1). В retroarch.cfg от
#    GammaOS у игрока 1 задан полный набор кнопок (A и B, X и Y там наоборот против профилей
#    геймпадов) и "левый стик как крестовина", у игроков 2-5 - ничего. Поэтому второй игрок
#    стрелял другой кнопкой, а геймпад, у которого крестовина приходит левым стиком (ShanWan
#    PS3/PC без режима Analog), вторым игроком не ходил. Заполняются только незаданные кнопки
#    ("nul") и analog_dpad_mode "0": настроенное пользователем не трогается. Если RetroArch
#    открыт - до следующей загрузки (при закрытии он перепишет retroarch.cfg).
#
# Вывод - в logcat (тег rg52-retroarch), по-английски.

TAG=rg52-retroarch
APPS_LIST=/system/etc/gammaos/apps.list
# пакет:свойство-отметка
UPDATE_PKGS="com.retroarch.aarch64:persist.rg52.retroarch_apk
org.ppsspp.ppsspp:persist.rg52.ppsspp_apk
com.flycast.emulator:persist.rg52.flycast_apk
com.aurora.store:persist.rg52.aurora_apk"
PKG=com.retroarch.aarch64
CFG=/data/media/0/Android/data/$PKG/files/retroarch.cfg
PROF_SRC=${RG52_RA_PROFILES:-/system/etc/rg52-retroarch-autoconfig}
PROF_DST=/data/user/0/$PKG/autoconfig/android

say() { log -t $TAG "$*" 2>/dev/null; echo "$*"; }
version() { dumpsys package "$1" | sed -n 's/^ *versionName=//p' | head -n1; }
apk_of() { awk -F'|' -v p="$1" '$2 == p { print $3; exit }' $APPS_LIST 2>/dev/null; }

SETTLED=
# update_apk <пакет> <свойство-отметка>
update_apk() {
    pkg=$1
    mark=$2
    apk=$(apk_of "$pkg")
    [ -n "$apk" ] && [ -f "$apk" ] || return 0
    want=$(stat -c %s "$apk")
    [ "$(getprop "$mark")" = "$want" ] && return 0

    path=$(pm path "$pkg" 2>/dev/null | sed -n 's/^package://p' | head -n1)
    if [ -z "$path" ]; then
        say "$pkg is not installed, nothing to update"
        setprop "$mark" "$want"
        return 0
    fi
    if [ "$(stat -c %s "$path" 2>/dev/null)" = "$want" ]; then
        setprop "$mark" "$want"
        return 0
    fi

    # Пусть загрузка уляжется: копирование 180 МБ не должно совпасть с запуском оболочки.
    # Один раз за проход, а не перед каждым пакетом.
    if [ -z "$SETTLED" ]; then
        sleep 60
        SETTLED=1
    fi
    if pidof "$pkg" >/dev/null; then
        say "$pkg is running, will retry on next boot"
        return 0
    fi
    say "updating $pkg $(version "$pkg") from $apk ($want bytes)"
    out=$(pm install -r "$apk" 2>&1)
    say "pm install: $out"
    case "$out" in
        *Success*|*VERSION_DOWNGRADE*|*UPDATE_INCOMPATIBLE*)
            say "$pkg is now $(version "$pkg")"
            setprop "$mark" "$want" ;;
        *)
            say "will retry on next boot" ;;
    esac
    # Как в setup.sh: после копирования в кэше страниц десятки и сотни МБ грязных данных -
    # на 1 ГБ памяти их лучше сбросить сразу.
    sync
    echo 1 > /proc/sys/vm/drop_caches
}

install_profiles() {
    [ -d "$PROF_SRC" ] && [ -d "$PROF_DST" ] || return 0
    ref=$(ls "$PROF_DST"/*.cfg 2>/dev/null | head -n1)
    [ -n "$ref" ] || return 0
    own=$(stat -c %u:%g "$ref")
    ctx=$(stat -c %C "$ref")
    for f in "$PROF_SRC"/*.cfg; do
        [ -f "$f" ] || continue
        d="$PROF_DST/${f##*/}"
        cmp -s "$f" "$d" && continue
        if cp "$f" "$d" && chown "$own" "$d" && chmod 600 "$d" && chcon "$ctx" "$d"; then
            say "pad profile ${f##*/} installed"
        else
            say "pad profile ${f##*/}: install failed"
        fi
    done
}

align_players() {
    [ "$(getprop persist.rg52.retroarch_players)" = 1 ] && return 0
    [ -f "$CFG" ] || return 0
    if pidof $PKG >/dev/null; then
        say "RetroArch is running, players 2-5 left for next boot"
        return 0
    fi
    binds=$(grep -E '^input_player1_[a-z0-9_]+_(btn|axis) = "[^"]*"$' "$CFG" | grep -v '"nul"$')
    dpad=$(sed -n 's/^input_player1_analog_dpad_mode = "\(.*\)"$/\1/p' "$CFG")
    set --
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        key=${line%% = *}
        val=${line#* = }
        suf=${key#input_player1_}
        for p in 2 3 4 5; do
            set -- "$@" -e "s#^input_player${p}_${suf} = \"nul\"\$#input_player${p}_${suf} = ${val}#"
        done
    done <<EOF
$binds
EOF
    if [ -n "$dpad" ] && [ "$dpad" != 0 ]; then
        for p in 2 3 4 5; do
            set -- "$@" -e "s#^input_player${p}_analog_dpad_mode = \"0\"\$#input_player${p}_analog_dpad_mode = \"$dpad\"#"
        done
    fi
    if [ $# -gt 0 ]; then
        cp -p "$CFG" "$CFG.rg52-before-players"
        if sed -i "$@" "$CFG"; then
            n=$(grep -c -E '^input_player[2-5]_[a-z0-9_]+_(btn|axis) = "[^n]' "$CFG")
            say "players 2-5 now bound like player 1 ($n binds, analog_dpad_mode $dpad)"
        else
            say "players 2-5: editing retroarch.cfg failed"
            return 0
        fi
    fi
    setprop persist.rg52.retroarch_players 1
}

for e in $UPDATE_PKGS; do
    update_apk "${e%%:*}" "${e#*:}"
done
install_profiles
align_players
