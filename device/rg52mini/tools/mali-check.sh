#!/bin/bash
# mali-check.sh — проверяет драйвер Mali на пригодность для этого устройства.
#
# Зачем. Наш /vendor/lib64/egl/libGLES_mali.so версии g7p1-01bet0 содержит две
# функции, резервирующие 192 КБ стека одним кадром. Приложение, которое даёт
# своему потоку отрисовки меньше (Shantae and the Seven Sirens — 128 КБ),
# падает с переполнением стека при первом же создании изображения. В сборках
# посвежее этого нет. Скрипт отвечает сразу на все вопросы о кандидате: тот ли
# это тип драйвера, есть ли в нём та самая беда и сойдётся ли он с нашим
# окружением.
#
# Что проверяется:
#
#   1. Семейство GPU. Нужен Bifrost (Mali-G52 на RK3562). Valhall от RK3588 —
#      другая архитектура, не подойдёт.
#   2. Версия, строка arm_release_ver. Нужно новее g7p1 и не новее g25p0:
#      ядерная часть (kbase) у нас g25p0-00eac0, и пользовательская не должна
#      её обгонять — иначе запросит ioctl, которого в ядре нет.
#   3. Android это сборка или линуксовая. У сборок под GBM/X11 нет функций
#      Android WSI, и в vendor их не положить.
#   4. Кадры стека: ищем `sub sp, sp, #N, lsl #12` с N от 64 КБ. Именно такой
#      пролог и роняет игру.
#   5. С ключом -d — разрешаются ли все символы в нашем окружении. Блоб из
#      Android 14 собран против VNDK 34, а vendor у нас 13 и пространство имён
#      прибито к VNDK 33. Файлы, по которым сверяться, лежат в
#      T:\Dump\RG52Mini\GammaOSNext\mali-deps (собраны с устройства); на
#      заведомо рабочем блобе проверка даёт ноль неразрешённых.
#
# Использование:
#   mali-check.sh [-d КАТАЛОГ_ЗАВИСИМОСТЕЙ] <файл.so> [файл.so ...]

set -u

DEPS=""
while getopts "d:" opt; do
    case "$opt" in
        d) DEPS="$OPTARG" ;;
        *) echo "использование: mali-check.sh [-d КАТАЛОГ] <файл.so> [...]"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -ge 1 ] || { echo "использование: mali-check.sh [-d КАТАЛОГ] <файл.so> [...]"; exit 1; }

HAVE=""
if [ -n "$DEPS" ]; then
    HAVE=$(mktemp); trap 'rm -f "$HAVE"' EXIT
    nm -D --defined-only "$DEPS"/*.so 2>/dev/null \
        | awk 'NF>=3 {print $3}' | sed 's/@.*//' | sort -u > "$HAVE"
    echo "справочник символов: $(ls "$DEPS"/*.so 2>/dev/null | wc -l) библиотек, $(wc -l < "$HAVE") символов"
    echo
fi

for F in "$@"; do
    echo "=== $F"
    if [ ! -f "$F" ]; then echo "   нет файла"; echo; continue; fi

    echo "   размер:    $(stat -c %s "$F") байт"
    echo "   sha256:    $(sha256sum "$F" | cut -d' ' -f1)"

    VER=$(strings -a "$F" | grep -oE "g[0-9]+p[0-9]+-[0-9a-z]+" | sort -u | head -1)
    FAM=$(strings -a "$F" | grep -woE "Bifrost|Valhall|Midgard" | sort -u | head -1)
    API=$(readelf -n "$F" 2>/dev/null | grep -A4 "\.note\.android\.ident" | grep -oE "description data: [0-9a-f ]+" | awk '{print strtonum("0x" $3)}')
    echo "   версия:    ${VER:-не найдена}"
    echo "   семейство: ${FAM:-не определено}"
    [ -n "${API:-}" ] && echo "   собран под API: $API"

    # Android-сборку от линуксовой отличаем по функциям Android WSI: у сборок
    # для GBM/X11 их нет, и в vendor такую не положить.
    if strings -a "$F" | grep -q "vkGetSwapchainGrallocUsage"; then
        echo "   сборка:    Android (есть Android WSI)"
    else
        echo "   сборка:    НЕ Android (нет vkGetSwapchainGrallocUsage*) — в vendor не годится"
    fi

    echo "   зависимости:"
    readelf -dW "$F" 2>/dev/null | grep NEEDED | sed 's/.*\[\(.*\)\]/     \1/'

    if [ -n "$HAVE" ]; then
        NEED=$(mktemp)
        nm -D --undefined-only "$F" 2>/dev/null | awk '{print $NF}' | sed 's/@.*//' | sort -u > "$NEED"
        MISS=$(comm -23 "$NEED" "$HAVE")
        CNT=$(printf '%s' "$MISS" | grep -c . || true)
        if [ "$CNT" = "0" ]; then
            echo "   символы:   все $(wc -l < "$NEED") разрешаются в нашем окружении"
        else
            echo "   символы:   НЕ разрешается $CNT из $(wc -l < "$NEED"):"
            printf '%s\n' "$MISS" | head -15 | sed 's/^/     /'
        fi
        rm -f "$NEED"
    fi

    python3 - "$F" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
res = []
for i in range(0, len(data) - 4, 4):
    # sub sp, sp, #imm12, lsl #12  ->  маска 0xFFC003FF, значение 0xD14003FF
    if data[i] == 0xFF and data[i+3] == 0xD1 and (data[i+2] & 0xF0) == 0x40:
        w = struct.unpack_from("<I", data, i)[0]
        if (w & 0xFFC003FF) == 0xD14003FF:
            kb = ((w >> 10) & 0xFFF) * 4096 // 1024
            if kb >= 64:
                res.append((i, kb))
if res:
    print("   кадры стека >=64 КБ: " + ", ".join(f"0x{o:x} ({k} КБ)" for o, k in res))
    print("   ВЕРДИКТ: та же беда, что у нас — брать нет смысла")
else:
    print("   кадры стека >=64 КБ: нет")
    print("   ВЕРДИКТ: по этой части чисто")
PY
    echo
done
