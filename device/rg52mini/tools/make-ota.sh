#!/bin/bash
# make-ota.sh — собирает пакет обновления GammaOS для RG52 Mini.
#
# Зачем. Перепрошивка через извлечение SD карты и запись образа целиком —
# долго и неудобно, а меняется при этом обычно один раздел system. На
# устройстве уже есть штатный механизм GammaOS (/system/bin/gammaos-ota):
# он распаковывает образ и пишет его прямо в живой раздел, включая тот, с
# которого сейчас работает корень. Ни recovery, ни fastboot не нужны.
# Этот скрипт готовит для него пакет.
#
# Чем отличается от gen_ota_package.sh из дерева GammaOS. Тот считает
# system/vendor/product логическими разделами внутри super — так устроены
# устройства, для которых GammaOS собирается штатно. У нас разделов super
# нет вовсе: system это mmcblk1p4, vendor — mmcblk1p5, обычные записи в
# GPT. Для флешера это тип "physical", и он пишет в /dev/block/by-name/<имя>
# напрямую. С типом "logical" он полез бы искать super и ничего бы не нашёл.
#
# Что получается на выходе:
#   <выходной каталог>/manifest.json
#   <выходной каталог>/system.img.xz   (и другие разделы, если заданы)
#   <выходной каталог>.zip             (только с -z)
#
# Каталог нужен для быстрой прошивки в обход zip: gammaos-ota умеет брать
# уже распакованный пакет из /data/gammaos_ota/package. Zip нужен для
# выкладки — его выбирают в меню обновления на самом устройстве.

set -euo pipefail

VERSION=""
VERSION_CODE=""
DEVICE="rg52mini"
OUTDIR=""
XZ_LEVEL=6
XZ_THREADS=0
MAKE_ZIP=0

# Все разделы этого устройства — обычные записи в GPT.
PART_TYPE="physical"

usage() {
    cat <<'EOF'
использование: make-ota.sh -v ВЕРСИЯ [ключи] образ.img [образ.img ...]

  -v ВЕРСИЯ     строка версии, например 1.1 или 20260923-1052   [обязательно]
  -c КОД        числовой код версии (по умолчанию из даты сборки)
  -d ИМЯ        имя устройства для проверки совместимости (по умолчанию rg52mini);
                -d "" убирает проверку вовсе
  -o КАТАЛОГ    куда положить пакет (по умолчанию рядом с первым образом)
  -l УРОВЕНЬ    степень сжатия xz 0..9 (по умолчанию 6; 1 — быстро, для отладки)
  -T ЧИСЛО      потоков xz (по умолчанию все ядра)
  -z            дополнительно упаковать в zip для выкладки
  -t ТЕГ        тег выпуска на гите: рядом с zip кладётся список сборок для
                приложения обновлений, со ссылкой на вложение этого выпуска
  -U АДРЕС      явная ссылка на zip вместо собираемой из тега
  -D ЧИСЛО      ro.build.date.utc образа (по умолчанию читается из самого образа)
  -h            эта справка

Имя раздела берётся из имени файла: system.img -> раздел system. Если файл
назван иначе (сборка выдаёт lineage-21.0-...-tv_arm64_bvN.img), имя раздела
задаётся явно через двоеточие:  system:путь/к/образу.img

примеры:
  # быстрый пакет для своей проверки
  make-ota.sh -v 20260923-1052 -l 1 system:out/home/build-output/lineage-21.0-....img

  # пакет для выкладки
  make-ota.sh -v 1.1 -c 110 -l 9 -z system.img
EOF
    exit "${1:-0}"
}

while getopts "v:c:d:o:l:T:t:U:D:zh" opt; do
    case "$opt" in
        v) VERSION="$OPTARG" ;;
        c) VERSION_CODE="$OPTARG" ;;
        d) DEVICE="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        l) XZ_LEVEL="$OPTARG" ;;
        T) XZ_THREADS="$OPTARG" ;;
        t) REL_TAG="$OPTARG" ;;
        U) UPD_URL="$OPTARG" ;;
        D) BUILD_UTC="$OPTARG" ;;
        z) MAKE_ZIP=1 ;;
        *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))

[ -n "$VERSION" ] || { echo "make-ota.sh: не задана версия (-v)" >&2; usage 1; }
[ $# -ge 1 ] || { echo "make-ota.sh: не заданы образы" >&2; usage 1; }

# Разбираем аргументы вида  имя:путь  и  путь (имя из имени файла).
NAMES=()
PATHS=()
for arg in "$@"; do
    if [ -f "$arg" ]; then
        PATHS+=("$arg")
        NAMES+=("$(basename "$arg" .img)")
    elif [ -f "${arg#*:}" ]; then
        PATHS+=("${arg#*:}")
        NAMES+=("${arg%%:*}")
    else
        echo "make-ota.sh: нет файла ${arg#*:}" >&2
        exit 1
    fi
done

# Код версии. Он нужен флешеру только для сравнения «новее/старее», и если
# его не задали, берём цифры из строки версии: 20260923-1052 -> 202609231052,
# 1.1 -> 11. Так порядок сохраняется без ручного счётчика.
if [ -z "$VERSION_CODE" ]; then
    VERSION_CODE=$(printf '%s' "$VERSION" | tr -dc '0-9')
    VERSION_CODE=${VERSION_CODE:-0}
    # int32 в manifest: обрезаем до девяти знаков, иначе парсер переполнится.
    VERSION_CODE=${VERSION_CODE:0:9}
    VERSION_CODE=$((10#$VERSION_CODE))
fi

if [ -z "$OUTDIR" ]; then
    OUTDIR="$(cd "$(dirname "${PATHS[0]}")" && pwd)/ota-$VERSION"
fi
mkdir -p "$OUTDIR"

echo "== пакет обновления $VERSION (код $VERSION_CODE)"
echo "   устройство: ${DEVICE:-без проверки}"
echo "   каталог:    $OUTDIR"
echo "   сжатие:     xz -$XZ_LEVEL -T$XZ_THREADS"

PARTS_JSON=""
FILES=()

for i in "${!PATHS[@]}"; do
    img="${PATHS[$i]}"
    name="${NAMES[$i]}"
    xzname="$name.img.xz"
    xzpath="$OUTDIR/$xzname"
    size=$(stat -c '%s' "$img")

    echo
    echo "== $name ($PART_TYPE, $((size / 1024 / 1024)) МБ)"

    echo -n "   sha256 исходника... "
    sha_raw=$(sha256sum "$img" | cut -d' ' -f1)
    echo "$sha_raw"

    echo -n "   сжатие... "
    xz -c "-$XZ_LEVEL" "-T$XZ_THREADS" "$img" > "$xzpath"
    xzsize=$(stat -c '%s' "$xzpath")
    echo "готово, $((xzsize / 1024 / 1024)) МБ ($((xzsize * 100 / size))%)"

    echo -n "   sha256 архива... "
    sha_xz=$(sha256sum "$xzpath" | cut -d' ' -f1)
    echo "$sha_xz"

    entry=$(cat <<ENDJSON
        {
            "name": "$name",
            "type": "$PART_TYPE",
            "file": "$xzname",
            "sha256": "$sha_xz",
            "sha256_uncompressed": "$sha_raw",
            "size": $size
        }
ENDJSON
)
    if [ -n "$PARTS_JSON" ]; then
        PARTS_JSON="$PARTS_JSON,
$entry"
    else
        PARTS_JSON="$entry"
    fi
    FILES+=("$xzname")
done

# Поле device: пустой список означает «подходит любому устройству». Флешер
# сверяет его со свойством ro.gammaos.device.
if [ -n "$DEVICE" ]; then
    DEVICE_JSON="[\"$DEVICE\"]"
else
    DEVICE_JSON="[]"
fi

cat > "$OUTDIR/manifest.json" <<ENDJSON
{
    "version": "$VERSION",
    "version_code": $VERSION_CODE,
    "datetime": $(date +%s),
    "device": $DEVICE_JSON,
    "min_battery": 5,
    "partitions": [
$PARTS_JSON
    ]
}
ENDJSON

echo
echo "== manifest.json"
cat "$OUTDIR/manifest.json"

if [ "$MAKE_ZIP" = "1" ]; then
    zippath="$OUTDIR.zip"
    rm -f "$zippath"
    echo
    echo "== упаковка в $(basename "$zippath")"
    # -0: содержимое уже сжато xz, второй проход только тратит время.
    ( cd "$OUTDIR" && zip -0 -q "$zippath" manifest.json "${FILES[@]}" )
    echo "   $(stat -c '%s' "$zippath" | awk '{printf "%.2f ГиБ", $1/1073741824}')"
    echo -n "   sha256: "
    zip_sha=$(sha256sum "$zippath" | cut -d' ' -f1)
    echo "$zip_sha"

    # Список сборок для штатного приложения обновлений. Формат - тот же, что у
    # сервера LineageOS: приложение читает datetime, filename, id, romtype,
    # size, url, version и само решает, новее ли это установленного.
    if [ -n "$REL_TAG" ] || [ -n "$UPD_URL" ]; then
        # Свойства берём из самого образа. Дата обязательно его, а не времени
        # упаковки: приложение сравнивает её с ro.build.date.utc установленной
        # прошивки, и время упаковки всегда больше - тогда после установки оно
        # предлагало бы тот же пакет снова и снова.
        img_prop() {
            local key="$1" p v
            for p in /system/build.prop /build.prop /system/system/build.prop; do
                v=$(debugfs -R "cat $p" "${PATHS[0]}" 2>/dev/null \
                    | grep -m1 "^$key=" | cut -d= -f2- | tr -d '\r')
                if [ -n "$v" ]; then echo "$v"; return 0; fi
            done
            return 1
        }

        [ -n "$BUILD_UTC" ] || BUILD_UTC=$(img_prop ro.build.date.utc)
        romtype=$(img_prop ro.lineage.releasetype)
        androidver=$(img_prop ro.build.version.release)
        variant=$(img_prop ro.gammaos.variant)
        : "${romtype:=UNOFFICIAL}"
        : "${androidver:=14}"
        : "${variant:=core}"

        if [ -z "$BUILD_UTC" ]; then
            echo "   !! не удалось прочитать ro.build.date.utc из образа;" >&2
            echo "      задайте ключом -D, иначе приложение обновлений будет" >&2
            echo "      предлагать этот пакет и после его установки" >&2
        else
            if [ -z "$UPD_URL" ]; then
                UPD_URL="https://github.com/mamaich/GammaOSNext-RG52mini/releases/download/$REL_TAG/$(basename "$zippath")"
            fi
            updjson="$(dirname "$zippath")/${DEVICE:-rg52mini}-$variant.json"
            cat > "$updjson" <<ENDJSON
{
    "response": [
        {
            "datetime": $BUILD_UTC,
            "filename": "$(basename "$zippath")",
            "id": "$zip_sha",
            "romtype": "$romtype",
            "size": $(stat -c '%s' "$zippath"),
            "url": "$UPD_URL",
            "version": "$androidver"
        }
    ]
}
ENDJSON
            echo
            echo "== список сборок для приложения обновлений"
            echo "   $updjson"
            cat "$updjson"
            echo "   выложить в репозиторий как ota/${DEVICE:-rg52mini}-$variant.json"
        fi
    fi
fi

echo
echo "== готово"
echo "быстрая прошивка на устройство (пакет кладётся распакованным):"
echo "   adb push $OUTDIR/manifest.json $OUTDIR/*.img.xz /data/gammaos_ota/package/"
echo "   adb shell setprop sys.gammaos.ota.autoinstall 1"
echo "   adb shell start gammaos-ota"
