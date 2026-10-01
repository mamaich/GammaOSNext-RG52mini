#!/system/bin/sh
#
# Восстановление наших правок в прошивке EmuELEC на внутреннем eMMC.
# Запускается ИЗ ANDROID, загруженного с SD-карты, с правами root.
#
#     adb push restore-emmc.sh /data/local/tmp/
#     adb shell "sh /data/local/tmp/restore-emmc.sh"
#
# Что делает:
#   1. общая с Android папка с ромами -- два systemd-юнита, после которых
#      /storage/roms в EmuELEC указывает на /storage/emulated/0/ROMs;
#   2. чинит пустое значение brightness.level, из-за которого подсветка
#      гаснет в ноль при каждой загрузке;
#   3. ставит флаги RGBox: раздел DOWNLOAD и пропуск экрана согласия.
#
# Ключ -u снимает пункт 1 (юниты) и больше ничего не трогает.
#
# Подробности и обоснование -- doc/rg52mini/06-emuelec-на-emmc.md.
# Всё, что печатается, - по-английски: в консоли устройства кириллица может не
# читаться.

set -u

MNT=/data/local/tmp/.ee-restore-mnt
MNTB=/data/local/tmp/.ee-restore-boot
RGBOX_REL=.config/emulationstation/applyCenter/RGBox
ANDROID_ROMS=/data/media/0/ROMs
# Путь к папке с ромами внутри userdata, каким его видит EmuELEC после
# монтирования раздела в /var/media/SDDATA.
ROMS_IN_UNIT=/var/media/SDDATA/media/0/ROMs
# Яркость в процентах, которую подставляем, ЕСЛИ значение пустое.
BRIGHT_DEFAULT=80

UNINSTALL=0
[ "${1:-}" = "-u" ] && UNINSTALL=1

ok()   { echo "  [ ok ] $*"; }
warn() { echo "  [ !! ] $*"; }
die()  { echo; echo "ERROR: $*"; cleanup; exit 1; }

cleanup() {
    umount "$MNTB" 2>/dev/null
    umount "$MNT"  2>/dev/null
    rmdir  "$MNTB" 2>/dev/null
    rmdir  "$MNT"  2>/dev/null
}

echo "=== restoring our EmuELEC tweaks on the eMMC ==="

# ---------------------------------------------------------------- проверки
[ "$(id -u)" = "0" ] || die "root is required (adb root or su)"

# eMMC - по типу в sysfs, а не по номеру: нумерация mmcblk зависит от порядка
# инициализации контроллеров (так же ищет install-ddr928.sh).
EMMC=""
for b in /sys/block/mmcblk*; do
    [ -e "$b/device/type" ] || continue
    [ "$(cat "$b/device/type")" = MMC ] || continue
    EMMC=/dev/block/${b##*/}
done
[ -n "$EMMC" ] && [ -b "$EMMC" ] || die "internal eMMC not found"
ok "eMMC: $EMMC"

# Раздел userdata нашего Android на карте: его же EmuELEC смонтирует как общую
# папку. Номер берём у работающей системы - /data смонтирован именно с него.
DATA_SRC=$(grep ' /data ' /proc/mounts | head -1 | cut -d' ' -f1)
DATA_DEV=$(readlink -f "$DATA_SRC" 2>/dev/null)
[ -n "$DATA_DEV" ] || DATA_DEV=$DATA_SRC
DATA_NAME=${DATA_DEV##*/}
DATA_PART=$(cat "/sys/class/block/$DATA_NAME/partition" 2>/dev/null)
DATA_DISK=${DATA_NAME%p*}
[ -n "$DATA_PART" ] || die "cannot tell which partition /data is on ($DATA_SRC)"
[ "$(cat "/sys/block/$DATA_DISK/device/type" 2>/dev/null)" = SD ] ||
    die "/data is not on the SD card ($DATA_DEV) - run this from Android booted from the card"
ok "Android userdata: $DATA_DEV (partition $DATA_PART of the SD card)"

# Раздел STORAGE ищем по метке, но только среди разделов eMMC: на нашей
# SD-сборке EmuELEC метка STORAGE тоже есть, и промахнуться было бы легко.
STOR=""
if command -v blkid >/dev/null 2>&1; then
    STOR=$(blkid 2>/dev/null | grep 'LABEL="STORAGE"' | grep "${EMMC}p" | cut -d: -f1 | head -1)
fi
[ -z "$STOR" ] && STOR="${EMMC}p5"
[ -b "$STOR" ] || die "partition $STOR not found - is the eMMC there?"
ok "STORAGE partition: $STOR"

mkdir -p "$MNT" || die "cannot create $MNT"
umount "$MNT" 2>/dev/null
mount -t ext4 -o rw "$STOR" "$MNT" || die "cannot mount $STOR"

CONF="$MNT/.config/emuelec/configs/emuelec.conf"
if [ ! -f "$CONF" ]; then
    die "no .config/emuelec/configs/emuelec.conf on $STOR.
Either this is the wrong partition, or the firmware has never been booted yet.
Boot EmuELEC once, let it create its settings, then run this again."
fi
ok "this is the EmuELEC STORAGE partition"

# -------------------------------------------------------------- деинсталляция
if [ "$UNINSTALL" = "1" ]; then
    echo
    echo "--- removing the shared-folder units ---"
    for u in storage-roms.mount var-media-SDDATA.mount; do
        if [ -f "$MNT/.config/system.d/$u" ]; then
            rm -f "$MNT/.config/system.d/$u" && ok "removed $u"
        else
            ok "$u is not there"
        fi
    done
    sync
    cleanup
    echo
    echo "Done. /storage/roms will be back on the internal partition."
    exit 0
fi

# ------------------------------------------- 1. общая папка с ромами
echo
echo "--- 1. ROMs folder shared with Android ---"

if [ ! -d "$ANDROID_ROMS" ]; then
    warn "$ANDROID_ROMS does not exist, creating it"
    mkdir -p "$ANDROID_ROMS" || warn "could not create it, check by hand"
else
    ok "collection is there: $ANDROID_ROMS"
fi

mkdir -p "$MNT/.config/system.d" || die "cannot create .config/system.d"

cat > "$MNT/.config/system.d/var-media-SDDATA.mount" <<UNIT_A
[Unit]
Description=Android userdata partition on the SD card
Documentation=man:systemd.mount(5)

[Mount]
# SD-карта в EmuELEC - всегда mmcblk1 (eMMC занимает mmcblk0); номер раздела
# userdata взят у нашего Android при запуске restore-emmc.sh. ext4 с флагом
# casefold: ядру нужен CONFIG_UNICODE, иначе раздел не смонтируется вовсе;
# скрипт это проверяет отдельно.
What=/dev/mmcblk1p$DATA_PART
Where=/var/media/SDDATA
Type=ext4
Options=rw,noatime,nodiratime

[Install]
WantedBy=multi-user.target
UNIT_A

cat > "$MNT/.config/system.d/storage-roms.mount" <<UNIT_B
[Unit]
Description=EmuELEC ROMs from the Android shared storage
Documentation=man:systemd.mount(5)
# Каталог лежит внутри userdata, поэтому раздел должен быть смонтирован
# раньше. mount_romfs.sh стартует только storage-roms.mount, а
# var-media-SDDATA.mount systemd подтянет сам по Requires=.
Requires=var-media-SDDATA.mount
After=var-media-SDDATA.mount

[Mount]
# /data/media/0/ROMs == /storage/emulated/0/ROMs в Android
What=$ROMS_IN_UNIT
Where=/storage/roms
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
UNIT_B

chmod 644 "$MNT/.config/system.d/var-media-SDDATA.mount" \
          "$MNT/.config/system.d/storage-roms.mount"
ok "units written to .config/system.d/ (SD partition mmcblk1p$DATA_PART)"

# ------------------------------------------------------ 2. яркость
echo
echo "--- 2. brightness ---"
CUR=$(grep '^brightness\.level=' "$CONF" 2>/dev/null | head -1 | cut -d= -f2)
if [ -n "$CUR" ]; then
    ok "brightness.level=$CUR - already set, leaving it"
else
    [ -f "$CONF.bak-restore" ] || cp "$CONF" "$CONF.bak-restore"
    TMP="$CONF.tmp.$$"
    grep -v '^brightness\.level=' "$CONF" > "$TMP" 2>/dev/null
    echo "brightness.level=$BRIGHT_DEFAULT" >> "$TMP"
    cat "$TMP" > "$CONF"
    rm -f "$TMP"
    ok "was empty -> brightness.level=$BRIGHT_DEFAULT (copy in emuelec.conf.bak-restore)"
    echo "       an empty value turns the backlight to zero on every boot:"
    echo "       odroidgoa_utils.sh bright '' makes awk write 0 to sysfs"
fi

# ------------------------------------------------------ 3. флаги RGBox
echo
echo "--- 3. RGBox flags ---"
R="$MNT/$RGBOX_REL"
if [ -d "$R" ]; then
    for f in ui_down ui_app down_disclaimer_accepted; do
        if [ -f "$R/$f" ]; then
            ok "$f already there"
        else
            : > "$R/$f" && chmod 664 "$R/$f" && ok "created $f"
        fi
    done
    # debug заставляет RGBox считать карту присутствующей, не проверяя размер.
    # С общей папкой проверка проходит честно, а флаг только маскировал бы
    # неудачное монтирование.
    if [ -f "$R/debug" ]; then
        rm -f "$R/debug" && ok "removed the stale debug flag"
    fi
else
    warn "no $RGBOX_REL - RGBox has not been started yet, flags skipped"
fi

# --------------------------------------- 4. проверка ядра на casefold
echo
echo "--- 4. check: can the EmuELEC kernel mount the Android partition ---"
BOOTP=""
if command -v blkid >/dev/null 2>&1; then
    BOOTP=$(blkid 2>/dev/null | grep 'LABEL="EMUELEC"' | grep "${EMMC}p" | cut -d: -f1 | head -1)
fi
[ -z "$BOOTP" ] && BOOTP="${EMMC}p3"
mkdir -p "$MNTB" 2>/dev/null
if mount -t vfat -o ro "$BOOTP" "$MNTB" 2>/dev/null && [ -f "$MNTB/KERNEL" ]; then
    if grep -aq "without CONFIG_UNICODE" "$MNTB/KERNEL" 2>/dev/null; then
        warn "the kernel is built WITHOUT CONFIG_UNICODE!"
        echo "       The Android partition has the casefold flag, and such a"
        echo "       kernel refuses to mount it. The shared folder will not"
        echo "       work, RGBox will say SD CARD NOT FOUND again."
    else
        ok "CONFIG_UNICODE present, the casefold partition will mount"
    fi
    umount "$MNTB" 2>/dev/null
else
    warn "could not check the kernel (partition $BOOTP), skipping"
fi
rmdir "$MNTB" 2>/dev/null

# ---------------------------------------------------------------- финал
sync
cleanup

echo
echo "=== done ==="
echo "Boot EmuELEC. Expected:"
echo "  * ES and RGBox see the collection from /storage/emulated/0/ROMs;"
echo "  * RGBox DOWNLOAD opens without SD CARD NOT FOUND;"
echo "  * the backlight stays on."
echo
echo "If /storage/roms is empty, the mount failed; check"
echo "journalctl -u storage-roms.mount and -u var-media-SDDATA.mount."
