#!/bin/bash
# Сборка прослойки libbt-vendor.so для AIC8800D80. Подробности — в README.md.
#
# Нужен Android NDK r27c: библиотека грузится в процесс с Bionic, а toolchain
# от ядра (aarch64-none-linux-gnu) слинкует её с glibc, и она не загрузится.
# NDK ставится распаковкой, root не нужен:
#     mkdir -p ~/rg52/ndk && cd ~/rg52/ndk && unzip android-ndk-r27c-linux.zip
#
# Путь к NDK можно задать переменной: NDK=/path/to/android-ndk-r27c bash build.sh
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
NDK=${NDK:-$(ls -d "$HOME"/rg52/ndk/android-ndk-* 2>/dev/null | sort -V | tail -1)}
OUT=${OUT:-$HERE/out}

CC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android33-clang
[ -x "$CC" ] || { echo "!! не найден компилятор NDK: $CC"; exit 1; }
echo "компилятор: $(basename "$CC")"

mkdir -p "$OUT"
"$CC" -shared -fPIC -O2 -Wall -Wextra -o "$OUT/libbt-vendor.so" "$HERE/btvendor_aic.c" -llog

sz=$(stat -c %s "$OUT/libbt-vendor.so")
ls -la "$OUT/libbt-vendor.so"

# Уровень API в имени компилятора (android33) влияет на результат: с r27c и
# android33 сборка воспроизводится побайтно, размер ровно 10056.
if [ "$sz" = 10056 ]; then
    echo "размер совпал с эталонным (10056)"
else
    echo "!! размер $sz, эталон 10056 — другой NDK или правка исходника"
fi

echo
echo "В образ файл попадает не отсюда: раздел vendor копируется целиком из"
echo "рабочего образа Android 13, где библиотека уже стоит. Чтобы подменить её"
echo "своей сборкой, правьте scripts/mk-sdimg.sh рядом с подменой rgp2pad."
