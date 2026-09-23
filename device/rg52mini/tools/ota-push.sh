#!/bin/bash
# ota-push.sh — заливает готовый пакет обновления на устройство и запускает
# прошивку штатным механизмом GammaOS, без извлечения SD карты.
#
# Запускается из Git Bash на Windows: adb живёт здесь, а пакет собирается в
# WSL и лежит на T:, общем для обеих сторон.
#
# Что происходит на устройстве. /system/bin/gammaos-ota копирует себя и нужные
# ему библиотеки в /data, перезапускается оттуда, останавливает zygote,
# подменяет /system/bin и /system/lib64 на tmpfs (чтобы во время записи
# ничего не читалось с перезаписываемого раздела), распаковывает образ в
# /data/gammaos_ota/staging и пишет его в /dev/block/by-name/system с
# O_DIRECT. Потом перезагрузка. Корень при этом смонтирован с того самого
# раздела — так и задумано, см. OTA-SYSTEM.md в дереве.
#
# Пакет передаём распакованным (manifest.json + *.img.xz) прямо в
# /data/gammaos_ota/package: zip нужен только для выкладки, а на устройстве
# он всё равно был бы распакован в этот же каталог — лишние 700 МБ записи.

set -euo pipefail

# Git Bash переписывает аргументы, похожие на пути Unix, в пути Windows:
# /data/gammaos_ota превращается в C:/Program Files/Git/data/gammaos_ota, и
# adb push молча уезжает не туда. Полностью это преобразование отключать
# нельзя - тогда перестанут переводиться пути к файлам на T:. Исключаем
# только то, что адресует устройство.
export MSYS2_ARG_CONV_EXCL='/data;/system;/sdcard'

ADB=${ADB:-/t/Dump/tool/platform-tools/adb.exe}
PKGDIR=/data/gammaos_ota/package
DEVICE_NAME=${DEVICE_NAME:-rg52mini}

SRC=${1:-}
[ -n "$SRC" ] || { echo "использование: ota-push.sh <каталог пакета>"; exit 1; }
[ -f "$SRC/manifest.json" ] || { echo "нет $SRC/manifest.json" >&2; exit 1; }

echo "== устройство"
"$ADB" wait-for-device
"$ADB" shell id | grep -q 'uid=0' || { echo "!! adb shell не root" >&2; exit 1; }

# Свойство, по которому флешер сверяет совместимость пакета. В сборках до
# этой доработки его нет; ro.* можно выставить один раз, пока оно пустое.
CUR=$("$ADB" shell getprop ro.gammaos.device | tr -d '\r')
if [ -z "$CUR" ]; then
    echo "   ro.gammaos.device пусто, выставляю $DEVICE_NAME"
    "$ADB" shell "setprop ro.gammaos.device $DEVICE_NAME"
fi

echo "== место на /data"
"$ADB" shell 'df -h /data | tail -1'

echo "== заливаю пакет"
"$ADB" shell "mkdir -p $PKGDIR && rm -f $PKGDIR/*"
for f in "$SRC"/manifest.json "$SRC"/*.img.xz; do
    echo "   $(basename "$f")"
    "$ADB" push "$f" "$PKGDIR/"
done

echo "== запускаю прошивку"
# Пишем logcat в файл на /data: он переживёт прошивку и перезагрузку, а
# кольцевой буфер в памяти - нет. Один раз это уже понадобилось, когда экран
# во время записи гас и надо было понять, кто его забрал.
"$ADB" shell 'rm -f /data/gammaos_ota/ota.log /data/local/tmp/flash.log'
"$ADB" shell 'nohup logcat -b all -v time > /data/local/tmp/flash.log 2>&1 &' &
sleep 1
"$ADB" shell 'setprop sys.gammaos.ota.autoinstall 1'
"$ADB" shell 'setprop sys.gammaos.ota.package ""'
"$ADB" shell 'start gammaos-ota'

cat <<'EOF'

Дальше на экране устройства появится ход прошивки, в конце — обратный отсчёт
и перезагрузка. Связь по adb оборвётся, это нормально: zygote остановлен.

Посмотреть журнал после перезагрузки:
  adb shell cat /data/gammaos_ota/ota.log
EOF
