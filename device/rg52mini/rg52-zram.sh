#!/system/bin/sh
# Подкачка на этом устройстве: zram со своей подложкой на карте.
#
# Почему не просто zram. zram — это не дополнительная память, а её уплотнение:
# сжатые страницы продолжают занимать ту же физическую память. Vendor заводит
# его на 100 % памяти (fstab.rk30board: zramsize=100%), и тогда ядро набивает
# только его, а до отдельного файла подкачки очередь не доходит никогда.
# Измерено на игре, которой нужно около 1,8 ГБ (память 2 ГБ, файл подкачки 2 ГБ):
#
#     zram 1,9 ГБ            — убита через 63–78 с, файл не тронут
#     zram 1 ГБ              — убита через 66 с, zram не заполнился
#     zram 512 МБ            — убита через 2 мин 55 с, файл дошёл до 456 МБ
#     zram 0 (выключен)      — играет, на карту ушло 938 МБ
#     zram 1,9 ГБ + подложка — играет, через подложку прошло 700 МБ за 2 минуты
#
# Последняя строка и есть то, что здесь настраивается: zram остаётся большим и
# принимает страницы первым, а когда памяти становится мало, его содержимое
# вытесняется на подложку и освобождает ОЗУ по-настоящему. Горячее остаётся в
# быстром сжатом ярусе, на карту уходит только холодное — в отличие от варианта
# с выключенным zram, где на карту идёт всё подряд.
#
# Свойства:
#   persist.rg52.zram.size_mb          размер zram в МБ, 0 — zram выключен
#   persist.gammaos.swap.size_mb       сколько места на карте отдано подкачке;
#                                      при включённом zram это его подложка, при
#                                      выключенном — обычный файл подкачки,
#                                      который делает gammaos-swap.sh
#   persist.rg52.zram.wb_threshold_mb  порог вытеснения, см. rg52-zram-wb.sh
#
# Размер меняется только целиком: swapoff, сброс устройства, подложка, disksize,
# mkswap, swapon. На загрузке это дёшево (zram почти пуст), в работе — тем
# дороже, чем больше в нём страниц: их придётся вернуть в память.

set -u

TAG=rg52-zram
SYS=/sys/block/zram0
DEV=/dev/block/zram0
BACKDIR=/data/gammaos_swap
BACKFILE=$BACKDIR/zram_backing.img

log_i() { log -p i -t "$TAG" "$1"; }

num() {   # $1 значение, $2 запасное — всё, что не цифры, считаем запасным
    case "$1" in
        ''|*[!0-9]*) echo "$2" ;;
        *) echo "$1" ;;
    esac
}

[ -e "$SYS/disksize" ] || { log_i "zram в этом ядре нет"; exit 0; }

ZSIZE=$(num "$(getprop persist.rg52.zram.size_mb)" 0)
CARD=$(num "$(getprop persist.gammaos.swap.size_mb)" 0)
WBTH=$(num "$(getprop persist.rg52.zram.wb_threshold_mb)" 0)

# Подложка имеет смысл только вместе со сторожем: ядро само на неё ничего не
# пишет, вытеснение происходит только по команде. Поэтому ноль в любом из двух
# полей означает одно и то же — вытеснения нет, — и состояние получается
# одинаковым: файла на карте нет, петля не занята, сторож не крутится впустую.
BACK=$CARD
[ "$WBTH" = 0 ] && BACK=0

detach_backing_loops() {
    # Петли на наш файл, оставшиеся от прошлой настройки.
    losetup -a 2>/dev/null | while IFS=: read -r dev rest; do
        case "$rest" in
            *"$BACKFILE"*) losetup -d "$dev" 2>/dev/null ;;
        esac
    done
}

# --- zram выключен: снять и уйти, файл подкачки сделает gammaos-swap.sh ---
if [ "$ZSIZE" = 0 ]; then
    if grep -q "^$DEV " /proc/swaps 2>/dev/null; then
        swapoff "$DEV" 2>/dev/null || { log_i "не удалось отключить zram"; exit 1; }
    fi
    echo 1 > "$SYS/reset" 2>/dev/null
    detach_backing_loops
    rm -f "$BACKFILE" 2>/dev/null
    log_i "zram выключен, подкачка идёт в обычный файл"
    exit 0
fi

WANT=$((ZSIZE * 1024 * 1024))
CUR=$(cat "$SYS/disksize" 2>/dev/null)
CURBACK=$(cat "$SYS/backing_dev" 2>/dev/null)
CURBACKSZ=0
[ -f "$BACKFILE" ] && CURBACKSZ=$(( $(stat -c %s "$BACKFILE" 2>/dev/null || echo 0) / 1048576 ))

# Уже настроено как надо — не трогаем: пересборка стоит возврата страниц в память.
if [ "$CUR" = "$WANT" ] && [ "$CURBACKSZ" = "$BACK" ]; then
    if [ "$BACK" = 0 ] || [ "$CURBACK" != "none" ]; then
        exit 0
    fi
fi

if grep -q "^$DEV " /proc/swaps 2>/dev/null; then
    if ! swapoff "$DEV" 2>/dev/null; then
        log_i "не удалось отключить zram (страницы некуда вернуть), оставляю как есть"
        exit 1
    fi
fi
echo 1 > "$SYS/reset" 2>/dev/null    # сброс отцепляет и подложку
detach_backing_loops

# --- подложка ---
if [ "$BACK" -gt 0 ]; then
    mkdir -p "$BACKDIR" 2>/dev/null
    chmod 700 "$BACKDIR" 2>/dev/null
    if [ ! -f "$BACKFILE" ] || [ "$CURBACKSZ" != "$BACK" ]; then
        rm -f "$BACKFILE" 2>/dev/null
        if ! fallocate -l "${BACK}M" "$BACKFILE" 2>/dev/null; then
            dd if=/dev/zero of="$BACKFILE" bs=1M count="$BACK" status=none 2>/dev/null
        fi
        chmod 600 "$BACKFILE" 2>/dev/null
    fi
    LOOP=$(losetup -f --show "$BACKFILE" 2>/dev/null)
    if [ -n "$LOOP" ]; then
        echo "$LOOP" > "$SYS/backing_dev" 2>/dev/null
    else
        log_i "не удалось подключить подложку, zram будет без вытеснения"
    fi
else
    rm -f "$BACKFILE" 2>/dev/null
fi

echo "$WANT" > "$SYS/disksize" 2>/dev/null
mkswap "$DEV" >/dev/null 2>&1
# Приоритет выше, чем у обычного файла подкачки, если тот вдруг есть: сперва
# быстрый сжатый ярус.
swapon -p 2 "$DEV" 2>/dev/null

log_i "zram ${ZSIZE} МБ, подложка $(cat "$SYS/backing_dev" 2>/dev/null) на ${BACK} МБ"
