#!/bin/bash
# Пересборка ядра RG52 Mini с CONFIG_USERFAULTFD, CONFIG_CRYPTO_LZ4 и
# CONFIG_MEMTEST.
#
# Модули Wi-Fi собираются тем же проходом, и это обязательно: CONFIG_USERFAULTFD
# меняет разметку vm_area_struct, ядро собрано с modversions, и старые .ko
# откажутся грузиться - "disagrees about version of symbol module_layout".
#
# Нужны оба драйвера, а не только aic8800. Плата ревизии A несёт RK915, ревизии
# B - AIC8800D80, оба чипа сидят на одном слоте SDIO и делят вывод питания.
# Загружается по факту железа: сперва rk915 (из init.insmod.cfg), и только если
# интерфейс не появился - aic8800 (из /vendor/bin/wifi_pick.sh). Незагружаемый
# rk915.ko эту логику ломает молча: на ревизии A интерфейс не появляется, дальше
# грузится aic8800, не находит своего чипа и гасит питание шины - Wi-Fi нет.
set -e
RG=/home/mamaich/rg52
SRC=$RG/kernel_rk3562_rg52mini
OUT=$RG/out-kernel-uffd
TCBIN=$(echo "$RG"/toolchain/arm-gnu-toolchain-*-x86_64-aarch64-none-linux-gnu/bin)
export PATH="$TCBIN:$PATH" ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu-
cd "$SRC"
cp "$RG/config.new" .config
make olddefconfig >/dev/null
echo "=== KERNELRELEASE = $(make -s kernelrelease)"
grep -E "^CONFIG_USERFAULTFD|^CONFIG_CRYPTO_LZ4|^CONFIG_MEMTEST|^CONFIG_RK915" .config
echo "=== сборка на $(nproc) ядрах, $(date -Is)"
make -j"$(nproc)" Image modules
mkdir -p "$OUT"
cp -v arch/arm64/boot/Image "$OUT"/
cp -v arch/arm64/boot/dts/rockchip/rk3562-rg52mini.dtb "$OUT"/ 2>/dev/null || true
for d in drivers/net/wireless/aic8800 drivers/net/wireless/rockchip_wlan/rk915; do
    find "$d" -name "*.ko" -exec cp -v {} "$OUT"/ \;
done
# rk915.ko собирается с отладочными символами - 1,4 МБ вместо 412 КБ. Раздел
# vendor заполнен на 98 %, свободно порядка 7 МБ, поэтому символы снимаем: это
# ровно то, что делает само ядро при INSTALL_MOD_STRIP=1, модуль после этого
# грузится так же (проверено на устройстве), и размер сходится байт в байт с
# модулем из эталонного образа.
#
# Модули aic8800 оставлены как есть: они проверены в этом виде и лежат на
# устройстве. Если vendor когда-нибудь упрётся в предел - здесь есть ещё около
# 2,5 МБ запаса, снять символы и с них.
[ -f "$OUT/rk915.ko" ] && "${CROSS_COMPILE}strip" --strip-debug "$OUT/rk915.ko"

echo "=== vermagic собранных модулей:"
for m in "$OUT"/*.ko; do echo -n "$(basename $m): "; strings "$m" | grep -m1 "^vermagic="; done
echo "=== готово $(date -Is)"
ls -la "$OUT"
