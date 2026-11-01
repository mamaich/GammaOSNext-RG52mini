#!/system/bin/sh
# RetroArch из образа и его настройки - на системы, установленные раньше.
#
# 1. APK. setup.sh ставит RetroArch из /system/etc/RetroArch_aarch64.apk один раз, на первой
#    загрузке, поэтому новый APK в образе (v1.16: 1.22.1 -> 1.22.2) до систем, обновлённых по
#    воздуху, сам не доходил. На загрузке: если установленный APK - не тот, что в образе, и с
#    этим APK образа ещё не пробовали (persist.rg52.retroarch_apk - размер APK образа, с которым
#    попытка уже была), он ставится поверх: pm install -r. Данные (ядра, настройки) остаются.
#    Без -d: RetroArch, который пользователь сам обновил до более новой версии, не трогается
#    (INSTALL_FAILED_VERSION_DOWNGRADE). Удалённый пользователем RetroArch не возвращается.
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
APK=/system/etc/RetroArch_aarch64.apk
PKG=com.retroarch.aarch64
CFG=/data/media/0/Android/data/$PKG/files/retroarch.cfg
PROF_SRC=${RG52_RA_PROFILES:-/system/etc/rg52-retroarch-autoconfig}
PROF_DST=/data/user/0/$PKG/autoconfig/android

say() { log -t $TAG "$*" 2>/dev/null; echo "$*"; }
version() { dumpsys package $PKG | sed -n 's/^ *versionName=//p' | head -n1; }

update_apk() {
    [ -f $APK ] || return 0
    want=$(stat -c %s $APK)
    [ "$(getprop persist.rg52.retroarch_apk)" = "$want" ] && return 0

    path=$(pm path $PKG 2>/dev/null | sed -n 's/^package://p' | head -n1)
    if [ -z "$path" ]; then
        say "$PKG is not installed, nothing to update"
        setprop persist.rg52.retroarch_apk "$want"
        return 0
    fi
    if [ "$(stat -c %s "$path" 2>/dev/null)" = "$want" ]; then
        setprop persist.rg52.retroarch_apk "$want"
        return 0
    fi

    # Пусть загрузка уляжется: копирование 180 МБ не должно совпасть с запуском оболочки.
    sleep 60
    if pidof $PKG >/dev/null; then
        say "RetroArch is running, will retry on next boot"
        return 0
    fi
    say "updating $PKG $(version) from $APK ($want bytes)"
    out=$(pm install -r $APK 2>&1)
    say "pm install: $out"
    case "$out" in
        *Success*|*VERSION_DOWNGRADE*)
            say "$PKG is now $(version)"
            setprop persist.rg52.retroarch_apk "$want" ;;
        *)
            say "will retry on next boot" ;;
    esac
    # Как в setup.sh: после копирования в кэше страниц ~180 МБ грязных данных - на 1 ГБ
    # памяти их лучше сбросить сразу.
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

update_apk
install_profiles
align_players
