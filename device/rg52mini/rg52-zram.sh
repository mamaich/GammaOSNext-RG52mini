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
#   persist.rg52.zram.size_mb          размер zram в МБ, 0 — zram выключен;
#                                      можно долей памяти: 100%, 50%
#   persist.rg52.zram.algo             алгоритм сжатия, пусто — как в ядре
#   persist.rg52.zram.backing_mb       подложка zram на карте в МБ, 0 — без неё
#   persist.rg52.zram.wb_threshold_mb  порог вытеснения, см. rg52-zram-wb.sh
#
# Обычный файл подкачки (persist.gammaos.swap.size_mb, gammaos-swap.sh) живёт
# отдельно и не зависит от zram: их можно включать вместе, и тогда zram работает
# быстрым сжатым ярусом перед файлом (приоритет 2 против -2).
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

# --- zswap: сжатый ярус перед настоящей подкачкой ---
#
# Отличие от zram принципиальное. zram - это отдельное устройство подкачки,
# которое целиком живёт в памяти: что в него попало, там и осталось, и когда он
# полон, страницы идут дальше на карту мимо него. zswap же стоит перед
# настоящей подкачкой: сжимает страницы в памяти, а когда его пул заполнен,
# сам вытесняет самые давние на карту - уже разжатыми. То есть он экономит
# записи на карту, не занимая под себя фиксированный кусок памяти.
#
# Замеры на этом устройстве показали, что zram записи на карту не сокращает:
# сколько он принял, настолько же отнял памяти у игры, и ядру пришлось выгружать
# больше. У zswap таких качелей быть не должно - пул ограничен долей памяти и
# отдаёт её обратно, - но это надо проверить, поэтому по умолчанию выключен.
#
# Свойства:
#   persist.rg52.zswap.enabled           1 — включить
#   persist.rg52.zswap.max_pool_percent  какую долю памяти отдать пулу (20)
#   persist.rg52.zswap.algo              алгоритм сжатия (zstd)
ZSWAP_DIR=/sys/module/zswap/parameters
setup_zswap() {
    [ -d "$ZSWAP_DIR" ] || return 0
    local on algo pct
    on=$(getprop persist.rg52.zswap.enabled)
    case "$on" in 1|true|Y|y) on=Y ;; *) on=N ;; esac

    if [ "$on" = N ]; then
        [ "$(cat "$ZSWAP_DIR/enabled" 2>/dev/null)" = "Y" ] && echo N > "$ZSWAP_DIR/enabled" 2>/dev/null
        return 0
    fi

    algo=$(getprop persist.rg52.zswap.algo)
    [ -n "$algo" ] || algo=zstd
    pct=$(num "$(getprop persist.rg52.zswap.max_pool_percent)" 20)
    [ "$pct" -gt 0 ] 2>/dev/null || pct=20

    # Сперва настройка пула, потом включение: смена алгоритма на работающем
    # zswap заводит второй пул и оставляет старый до опустошения.
    echo "$algo" > "$ZSWAP_DIR/compressor" 2>/dev/null
    echo zsmalloc > "$ZSWAP_DIR/zpool" 2>/dev/null
    echo "$pct" > "$ZSWAP_DIR/max_pool_percent" 2>/dev/null
    echo Y > "$ZSWAP_DIR/enabled" 2>/dev/null
    log_i "zswap включён: $(cat "$ZSWAP_DIR/compressor" 2>/dev/null)/$(cat "$ZSWAP_DIR/zpool" 2>/dev/null), пул до ${pct}% памяти"
}
setup_zswap

[ -e "$SYS/disksize" ] || { log_i "zram в этом ядре нет"; exit 0; }

# Отбираем zram у vendor, иначе им управляют двое и оба мешают.
#
# В init.rk30board.rc есть правило
#
#     on sys-boot-completed-set && property:persist.sys.zram_enabled=1
#         swapon_all /vendor/etc/fstab.${ro.hardware}
#
# и fstab заводит zram размером во всю память (zramsize=100%). Из этого выходит
# сразу две беды.
#
# Первая: правило срабатывает позже нас (мы работаем на post-fs-data), поэтому
# любой выбранный здесь размер молча перекрывался стопроцентным. В журнале это
# видно как "zram: Cannot change disksize for initialized device", а на
# устройстве - как настройка, которая ничего не меняет: выключение zram не
# выключало его вовсе.
#
# Вторая, тяжёлая: "один раз за загрузку" в комментарии vendor означает "один
# раз на выставление sys.boot_completed", а оно выставляется снова при каждом
# перезапуске каркаса. Тогда swapon_all выполняет mkswap поверх работающего
# устройства подкачки:
#
#     zram: Cannot change disksize for initialized device
#     mkswap: xwrite: Text file busy
#     init: [libfs_mgr] mkswap failed for /dev/block/zram0
#
# Через несколько секунд после этого ядро дважды падало с повреждением учёта
# страниц - "BUG: Bad rss-counter state ... val:-38654706715" и следом
# обращение по разрушенному адресу в execve, а в другой раз - разыменование
# нуля в приёмной очереди сокетов. Оба раза при перезапуске каркаса, оба раза
# через 5-13 секунд после этих строк.
#
# Свойство persist.sys.zram_enabled наши настройки не используют, так что
# гасим его насовсем: подкачкой на этом устройстве распоряжается только этот
# скрипт.
if [ "$(getprop persist.sys.zram_enabled)" != 0 ]; then
    setprop persist.sys.zram_enabled 0
    log_i "vendor-овское управление zram отключено (persist.sys.zram_enabled=0)"
fi

# Размер принимается и долей памяти — так его задаёт меню подкачки, и так же
# устроен заводской fstab (zramsize=100%). Считаем от MemTotal.
ZRAW=$(getprop persist.rg52.zram.size_mb)
case "$ZRAW" in
    *%)
        ZPCT=$(num "${ZRAW%\%}" 0)
        MEMKB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
        ZSIZE=$(( MEMKB * ZPCT / 100 / 1024 ))
        ;;
    *)
        ZSIZE=$(num "$ZRAW" 0)
        ;;
esac
BACK=$(num "$(getprop persist.rg52.zram.backing_mb)" 0)
# Алгоритм сжатия. Замерено на этом устройстве, игра TMNT, одинаковый отрезок:
# zstd держит 268 МБ данных в 74 МБ памяти (3,63x), lz4 те же 268 МБ - в 105 МБ
# (2,55x). Разница в памяти уходит игре, а на карту за сеанс ушло на 17 %
# меньше. Процессорная цена zstd на этой нагрузке окупается: запись на карту
# втрое дороже по времени, чем сжатие.
ALGO=$(getprop persist.rg52.zram.algo)
CURALGO=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$SYS/comp_algorithm" 2>/dev/null)
WBTH=$(num "$(getprop persist.rg52.zram.wb_threshold_mb)" 0)

# Подложка имеет смысл только вместе со сторожем: ядро само на неё ничего не
# пишет, вытеснение происходит только по команде. Поэтому ноль в любом из двух
# полей означает одно и то же — вытеснения нет, — и состояние получается
# одинаковым: файла на карте нет, петля не занята, сторож не крутится впустую.
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
if [ "$CUR" = "$WANT" ] && [ "$CURBACKSZ" = "$BACK" ] \
   && { [ -z "$ALGO" ] || [ "$ALGO" = "$CURALGO" ]; }; then
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

# Алгоритм принимается только у сброшенного устройства, поэтому здесь.
if [ -n "$ALGO" ] && [ "$ALGO" != "$CURALGO" ]; then
    if ! echo "$ALGO" > "$SYS/comp_algorithm" 2>/dev/null; then
        log_i "алгоритм $ALGO ядром не принят, остаётся $CURALGO"
    fi
fi

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

# zswap стоит перед всеми устройствами подкачки, включая zram, - выйдет
# двойное сжатие одних и тех же страниц. Вместе включать незачем.
if [ "$(cat "$ZSWAP_DIR/enabled" 2>/dev/null)" = "Y" ]; then
    log_i "внимание: включены и zswap, и zram - страницы сожмутся дважды"
fi

log_i "zram ${ZSIZE} МБ ($(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$SYS/comp_algorithm" 2>/dev/null)), подложка $(cat "$SYS/backing_dev" 2>/dev/null) на ${BACK} МБ"
