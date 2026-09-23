#!/bin/bash
# mali-check.sh — проверяет драйвер Mali на пригодность для этого устройства.
#
# Зачем. Наш /vendor/lib64/egl/libGLES_mali.so версии g7p1-01bet0 содержит две
# функции, резервирующие 192 КБ стека одним кадром. Приложение, которое даёт
# своему потоку отрисовки меньше (Shantae and the Seven Sirens — 128 КБ),
# падает с переполнением стека при первом же создании изображения. В сборках
# посвежее этого нет. Скрипт отвечает на два вопроса сразу: подходит ли блоб
# по семейству и версии, и есть ли в нём та самая беда.
#
# Что проверяем:
#   * семейство GPU - нужен Bifrost (Mali-G52 на RK3562). Valhall от RK3588
#     не подойдёт, это другая архитектура.
#   * версию - строку arm_release_ver. Нужно новее g7p1 и не новее g25p0:
#     ядерная часть (kbase) у нас g25p0-00eac0, и пользовательская не должна
#     её обгонять.
#   * кадры стека - ищем инструкции `sub sp, sp, #N, lsl #12` с N от 64 КБ.
#     Именно такой пролог и роняет игру.
#
# Использование: mali-check.sh <файл.so> [файл.so ...]

set -u
[ $# -ge 1 ] || { echo "использование: mali-check.sh <libGLES_mali.so> [...]"; exit 1; }

for F in "$@"; do
    echo "=== $F"
    if [ ! -f "$F" ]; then echo "   нет файла"; echo; continue; fi

    echo "   размер:   $(stat -c %s "$F") байт"
    echo "   sha256:   $(sha256sum "$F" | cut -d' ' -f1)"

    VER=$(strings -a "$F" | grep -oE "g[0-9]+p[0-9]+-[0-9a-z]+" | sort -u | head -1)
    FAM=$(strings -a "$F" | grep -woE "Bifrost|Valhall|Midgard" | sort -u | head -1)
    echo "   версия:   ${VER:-не найдена}"
    echo "   семейство: ${FAM:-не определено}"

    # Android-сборку от линуксовой отличаем по функциям Android WSI: у сборок
    # для GBM/X11 их нет, и в vendor такую не положить.
    if strings -a "$F" | grep -q "vkGetSwapchainGrallocUsage"; then
        echo "   сборка:   Android (есть Android WSI)"
    else
        echo "   сборка:   НЕ Android (нет vkGetSwapchainGrallocUsage*) - в vendor не годится"
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
    print("   ВЕРДИКТ: та же беда, что у нас - брать нет смысла")
else:
    print("   кадры стека >=64 КБ: нет")
    print("   ВЕРДИКТ: по этой части чисто")
PY
    echo
done
