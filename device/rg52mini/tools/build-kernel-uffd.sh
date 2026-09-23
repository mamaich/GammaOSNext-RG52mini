#!/bin/bash
# Пересборка ядра RG52 Mini с CONFIG_USERFAULTFD и CONFIG_CRYPTO_LZ4.
# Модули aic8800 собираются тем же проходом: CONFIG_USERFAULTFD меняет
# разметку vm_area_struct, а ядро собрано с modversions - старые .ko
# откажутся грузиться.
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
grep -E "^CONFIG_USERFAULTFD|^CONFIG_CRYPTO_LZ4" .config
echo "=== сборка на $(nproc) ядрах, $(date -Is)"
make -j"$(nproc)" Image modules
mkdir -p "$OUT"
cp -v arch/arm64/boot/Image "$OUT"/
cp -v arch/arm64/boot/dts/rockchip/rk3562-rg52mini.dtb "$OUT"/ 2>/dev/null || true
find drivers/net/wireless/aic8800 -name "*.ko" -exec cp -v {} "$OUT"/ \;
echo "=== vermagic собранных модулей:"
for m in "$OUT"/*.ko; do echo -n "$(basename $m): "; strings "$m" | grep -m1 "^vermagic="; done
echo "=== готово $(date -Is)"
ls -la "$OUT"
