#!/bin/bash
# Собирает однофайловый установщик разгона памяти device/rg52mini/ddr/install-ddr928.sh
# из шаблона install-ddr928.sh.in и двух idblock:
#   emmc-idbloader-ddr928.bin - наш (928 МГц); берутся только первые 2048 секторов,
#                               две копии idblock, без остальной области;
#   emmc-idblock-stock.bin    - стоковый (798 МГц) той же версии, 1 МиБ, для --uninstall.
set -euo pipefail
D=$(cd "$(dirname "$0")/../ddr" && pwd)
OUT=${1:-$D/install-ddr928.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

head -c 1048576 "$D/emmc-idbloader-ddr928.bin" > "$T/patched.bin"
cp "$D/emmc-idblock-stock.bin" "$T/stock.bin"
for f in patched stock; do
    [ "$(stat -c %s "$T/$f.bin")" = 1048576 ] || { echo "$f: не 1 МиБ" >&2; exit 1; }
    [ "$(head -c 4 "$T/$f.bin")" = RKNS ] || { echo "$f: нет RKNS" >&2; exit 1; }
done
PS=$(sha256sum < "$T/patched.bin" | cut -d' ' -f1)
SS=$(sha256sum < "$T/stock.bin" | cut -d' ' -f1)

{
    sed -e "s/@PATCHED_SHA@/$PS/" -e "s/@STOCK_SHA@/$SS/" "$D/install-ddr928.sh.in"
    for f in PATCHED STOCK; do
        echo "__${f}_BEGIN__"
        gzip -9n < "$T/$(echo $f | tr A-Z a-z).bin" | base64 -w 76
        echo "__${f}_END__"
    done
} > "$OUT"
chmod 755 "$OUT"
echo "$OUT: $(stat -c %s "$OUT") байт"
echo "  наш:      $PS"
echo "  стоковый: $SS"
