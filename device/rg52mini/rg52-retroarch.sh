#!/system/bin/sh
# RetroArch из образа - на системы, установленные раньше.
#
# setup.sh ставит RetroArch из /system/etc/RetroArch_aarch64.apk один раз, на первой загрузке,
# поэтому новый APK в образе (v1.16: 1.22.1 -> 1.22.2) до систем, обновлённых по воздуху, сам
# не доходил. На загрузке: если установленный APK - не тот, что в образе, и с этим APK образа
# ещё не пробовали (persist.rg52.retroarch_apk - размер APK образа, с которым попытка уже
# была), он ставится поверх: pm install -r. Данные (ядра, настройки) остаются. Без -d:
# RetroArch, который пользователь сам обновил до более новой версии, не трогается
# (INSTALL_FAILED_VERSION_DOWNGRADE). Удалённый пользователем RetroArch не возвращается.
# Если RetroArch открыт - до следующей загрузки.
#
# Вывод - в logcat (тег rg52-retroarch), по-английски.

TAG=rg52-retroarch
APK=/system/etc/RetroArch_aarch64.apk
PKG=com.retroarch.aarch64

say() { log -t $TAG "$*" 2>/dev/null; echo "$*"; }
version() { dumpsys package $PKG | sed -n 's/^ *versionName=//p' | head -n1; }

[ -f $APK ] || exit 0
want=$(stat -c %s $APK)
[ "$(getprop persist.rg52.retroarch_apk)" = "$want" ] && exit 0

path=$(pm path $PKG 2>/dev/null | sed -n 's/^package://p' | head -n1)
if [ -z "$path" ]; then
    say "$PKG is not installed, nothing to update"
    setprop persist.rg52.retroarch_apk "$want"
    exit 0
fi
if [ "$(stat -c %s "$path" 2>/dev/null)" = "$want" ]; then
    setprop persist.rg52.retroarch_apk "$want"
    exit 0
fi

# Пусть загрузка уляжется: копирование 180 МБ не должно совпасть с запуском оболочки.
sleep 60
if pidof $PKG >/dev/null; then
    say "RetroArch is running, will retry on next boot"
    exit 0
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
# Как в setup.sh: после копирования в кэше страниц ~180 МБ грязных данных - на 1 ГБ памяти их
# лучше сбросить сразу.
sync
echo 1 > /proc/sys/vm/drop_caches
