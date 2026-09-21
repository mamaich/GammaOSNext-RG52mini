#!/system/bin/sh
# RG52 Mini: растянуть userdata на всю SD-карту при первой загрузке.
#
# Заменяет собой rg52-resize-{grow,expand}.sh и APK RG52StorageResize из порта
# Android 13 — они лежали на /system и вместе с ним исчезают. Две ступени,
# потому что таблицу разделов ядро перечитывает только после перезагрузки:
#   ступень 1  растянуть девятый раздел до конца карты (sgdisk), перезагрузиться
#   ступень 2  дорастить файловую систему на уже смонтированном /data (resize2fs)
#
# Метки лежат на /metadata, чтобы стирание /data не заставляло всё повторять.
# Метка первой ступени пишется ДО перезагрузки: даже если sgdisk отработает
# неудачно, устройство не уйдёт в бесконечную перезагрузку, а просто останется
# с маленьким /data.
#
# Разбор вывода sgdisk намеренно сделан на sed + tr без классов и \x27:
# в Android sed от toybox, и расширенные конструкции GNU там не гарантированы.

DEV=/dev/block/mmcblk1
PART=${DEV}p9
GROWN=/metadata/rg52_resize_stage1_grown
DONE=/metadata/rg52_resize_done
LOG=/metadata/rg52_resize.log

log() { echo "rg52-resize: $*" > /dev/kmsg; echo "$(date) $*" >> "$LOG"; }

[ -e "$DONE" ] && exit 0
[ -b "$DEV" ] || { log "нет $DEV, делать нечего"; exit 0; }

TOTAL=$(blockdev --getsz "$DEV" 2>/dev/null)
START=$(cat /sys/class/block/mmcblk1p9/start 2>/dev/null)
SIZE=$(cat /sys/class/block/mmcblk1p9/size 2>/dev/null)
[ -z "$TOTAL" ] || [ "$TOTAL" = "0" ] && { log "blockdev вернул пусто"; exit 0; }
[ -z "$START" ] || [ -z "$SIZE" ] && { log "sysfs пуст"; exit 0; }
CUREND=$((START + SIZE - 1))

if [ ! -e "$GROWN" ]; then
    if [ "$CUREND" -ge $((TOTAL - 34)) ]; then
        log "раздел уже занимает всю карту ($CUREND из $TOTAL)"
        : > "$GROWN"; sync
    else
        log "ступень 1: растягиваю p9 с $CUREND до $((TOTAL - 34)) (карта $TOTAL секторов)"
        INFO=$(sgdisk --info=9 "$DEV" 2>/dev/null)
        TYPE=$(echo "$INFO" | sed -n "s/^Partition GUID code: //p" | cut -d' ' -f1)
        GUID=$(echo "$INFO" | sed -n "s/^Partition unique GUID: //p" | cut -d' ' -f1)
        NAME=$(echo "$INFO" | sed -n "s/^Partition name: //p" | tr -d "'")
        [ -z "$TYPE" ] && TYPE=0FC63DAF-8483-4772-8E79-3D69D8477DE4
        [ -z "$NAME" ] && NAME=userdata
        log "тип=$TYPE guid=$GUID имя=$NAME"

        # метку пишем первой: одна попытка, и никакого бутлупа
        : > "$GROWN"; sync

        sgdisk --move-second-header "$DEV" 2>&1 | while read -r l; do log "sgdisk-e: $l"; done
        if [ -n "$GUID" ]; then
            sgdisk --delete=9 --new=9:${START}:0 --typecode=9:${TYPE} \
                   --partition-guid=9:${GUID} --change-name=9:${NAME} "$DEV" 2>&1 |
                while read -r l; do log "sgdisk: $l"; done
        else
            log "ВНИМАНИЕ: не прочитался GUID раздела, by-partuuid может поехать"
            sgdisk --delete=9 --new=9:${START}:0 --typecode=9:${TYPE} \
                   --change-name=9:${NAME} "$DEV" 2>&1 |
                while read -r l; do log "sgdisk: $l"; done
        fi
        sync

        NEWEND=$(sgdisk --info=9 "$DEV" 2>/dev/null | sed -n "s/^Last sector: //p" | cut -d' ' -f1)
        if [ -n "$NEWEND" ] && [ "$NEWEND" -gt "$CUREND" ]; then
            log "ступень 1 готова: $CUREND -> $NEWEND, перезагружаюсь"
            sync
            setprop sys.powerctl reboot,resize
            exit 0
        fi
        log "ступень 1 НЕ УДАЛАСЬ: конец $NEWEND, был $CUREND; /data останется маленьким"
    fi
fi

# ступень 2
BEFORE=$(df -k /data 2>/dev/null | tail -1 | tr -s ' ' | cut -d' ' -f2)
OUT=$(resize2fs -f "$PART" 2>&1); RC=$?
echo "$OUT" | while IFS= read -r l; do log "resize2fs: $l"; done
AFTER=$(df -k /data 2>/dev/null | tail -1 | tr -s ' ' | cut -d' ' -f2)
log "ступень 2, код $RC, /data было ${BEFORE}K стало ${AFTER}K"
: > "$DONE"; sync
exit 0
