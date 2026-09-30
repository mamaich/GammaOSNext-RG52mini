#!/bin/sh
# Проверка логики подсветки на компьютере, без устройства и без сборки Android:
#   sh device/rg52mini/ledd/test/run.sh
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
OUT=${TMPDIR:-/tmp}/rg52-ledmap-test
cc -std=c11 -Wall -Wextra -Werror -O2 -o "$OUT" "$D/ledmap.c" "$D/test/ledmap_test.c"
"$OUT"
