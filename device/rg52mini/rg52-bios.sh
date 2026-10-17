#!/system/bin/sh
# Общая папка BIOS для GammaOS и dArkOS: системная папка RetroArch - ROMs/bios.
#
# dArkOS (общая карта dArkOS + GammaOS) держит BIOS в ROMs/bios нашего userdata и
# раскладывает их так же, как системная папка RetroArch: syscard3.pce,
# bios_CD_*.bin, dc/awbios.zip, fbneo/, mame2003-plus/ и т.д. RetroArch из GammaOS
# смотрел в RetroArch/system, где кроме наших файлов ничего нет, и без BIOS не
# запускались Sega CD, PC Engine CD, Atomiswave и прочие. Решение владельца
# 17.10.2026: одна папка на обе системы.
#
# Один раз на установку: файлы из RetroArch/system (то, что кладёт setup.sh из
# retroarch.tar.zst: PPSSPP, fbneo, mame2003, mame2003-plus) докладываются в
# ROMs/bios без перезаписи - у dArkOS там могут быть свои, - и в retroarch.cfg
# system_directory переключается на ROMs/bios. Только если там стоит прежнее
# значение GammaOS: свою папку пользователя не трогаем. RetroArch/system остаётся
# как был.
#
# Запуск - rg52-bios.rc: на каждой загрузке и по окончании setup.sh. На новой
# установке при первой загрузке RetroArch ещё не распакован - скрипт выходит, не
# ставя отметку, и срабатывает, когда setup.sh закончит. Если RetroArch открыт,
# тоже выходит: при закрытии он перепишет retroarch.cfg.
#
# Вывод - в logcat (тег rg52-bios), по-английски.

TAG=rg52-bios
MEDIA=/data/media/0
CFG=$MEDIA/Android/data/com.retroarch.aarch64/files/retroarch.cfg
OLD=/storage/emulated/0/RetroArch/system
NEW=/storage/emulated/0/ROMs/bios
SRC=$MEDIA/RetroArch/system
DST=$MEDIA/ROMs/bios

say() { log -t $TAG "$*" 2>/dev/null; echo "$*"; }

[ "$(getprop persist.rg52.bios_shared)" = 1 ] && exit 0
[ -f "$CFG" ] || { say "no retroarch.cfg yet, will retry"; exit 0; }
if pidof com.retroarch.aarch64 >/dev/null; then
    say "RetroArch is running, will retry on next boot"
    exit 0
fi

cur=$(sed -n 's/^system_directory = "\(.*\)"$/\1/p' "$CFG")
if [ "$cur" = "$OLD" ]; then
    if [ ! -d "$DST" ]; then
        mkdir -p "$DST"
        # владелец и права - как у самой ROMs (drwxrws--- ...:media_rw)
        chown "$(stat -c %u:%g $MEDIA/ROMs)" "$DST"
        chmod 2770 "$DST"
    fi
    if [ -d "$SRC" ]; then
        # -a: с владельцем и правами, -n: не перезаписывать файлы dArkOS
        cp -an "$SRC/." "$DST/" || say "copy from $SRC finished with errors"
    fi
    sed -i "s#^system_directory = \".*\"\$#system_directory = \"$NEW\"#" "$CFG"
    say "system_directory: $OLD -> $(sed -n 's/^system_directory = "\(.*\)"$/\1/p' "$CFG")"
else
    say "system_directory is '$cur' (not the GammaOS default), left as is"
fi
setprop persist.rg52.bios_shared 1
