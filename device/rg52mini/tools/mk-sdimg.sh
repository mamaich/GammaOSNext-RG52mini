#!/bin/bash
# Собирает полный образ SD-карты с GammaOS Core.
#
#   mk-sdimg.sh [system.img] [выход.img]
#
# По умолчанию берёт свежий system.img из out/home/build-output и кладёт
# результат в /home/mamaich/rg52/gamma/out/.
#
# Что откуда:
#   сектора 0..237567   — побайтно из рабочего образа SyachOS: защитный MBR,
#                         GPT, idbloader (RKNS с сектора 64), u-boot, resource
#                         и загрузочный FAT с ядром, DTB, initrd и extlinux
#   system  (p4)        — собранный GSI
#   vendor  (p5)        — побайтно из того же образа SyachOS
#   cache, metadata     — пустые ext4
#   misc                — нули
#   userdata            — оставлен пустым: init сам отформатирует его с теми
#                         параметрами, которых хочет Android 14, а служба
#                         rg52-resize растянет раздел на всю карту
#
# Разделы обязаны называться ровно так же, как в оригинале: fstab обращается
# к ним через /dev/block/by-name.

set -euo pipefail

SRC=${SRC:-/mnt/t/Dump/RG52Mini/android/SyachOS-RG52Mini-V1.0.317m6.3.img}

# Ядро и модули aic8800 берём из своей сборки, а не из эталонного образа.
# Эталон даёт загрузочный FAT и vendor побайтно, и там лежит ядро прошлого
# поколения. Если его не подменить, получится образ, где система собрана под
# уплотняющий сборщик мусора (ro.dalvik.vm.enable_uffd_gc=true), а ядро без
# CONFIG_USERFAULTFD — ART откатится на копирующий, это разойдётся с
# загрузочным образом, и boot classpath будет пересобираться при каждой
# холодной загрузке.
#
# Модули — та же история, только хуже: CONFIG_USERFAULTFD меняет разметку
# struct vm_area_struct, ядро собрано с modversions, и старые aic8800_*.ko с
# новым ядром просто не загрузятся. На свежей установке это означает отсутствие
# Wi-Fi и Bluetooth.
#
# Пусто или файлов нет — берём что было в эталоне и громко об этом говорим.
KERNELDIR=${KERNELDIR:-/home/mamaich/rg52/out-kernel-uffd}
TREE=/home/mamaich/rg52/GammaOSNext-RG52mini
WORK=/home/mamaich/rg52/gamma
OUTDIR=$WORK/out

# publish() — копия готового образа в T:\Dump\RG52Mini\GammaOSNext\img со сверкой
. "$WORK/scripts/publish-img.sh"

SYSIMG=${1:-}
if [ -z "$SYSIMG" ]; then
    SYSIMG=$(ls -t "$TREE"/out/home/build-output/*.img 2>/dev/null | head -1 || true)
fi
[ -n "$SYSIMG" ] && [ -f "$SYSIMG" ] || { echo "не найден system.img (укажи первым аргументом)" >&2; exit 1; }
[ -f "$SRC" ] || { echo "не найден исходный образ $SRC" >&2; exit 1; }

mkdir -p "$OUTDIR"
OUT=${2:-$OUTDIR/GammaOSCore-RG52Mini-$(date +%Y%m%d-%H%M).img}

# --- геометрия, всё в секторах по 512 байт ---
HEAD=237568                      # конец p3 + выравнивание, начало system
VENDOR_SECTORS=521576            # как в оригинале, чтобы образ vendor лёг байт в байт
CACHE_SECTORS=786432             # 384 МиБ
META_SECTORS=32768               # 16 МиБ
MISC_SECTORS=8192                # 4 МиБ
DATA_SECTORS=2097152             # 1 ГиБ, дальше растёт на первой загрузке
ALIGN=2048                       # 1 МиБ

align_up() { echo $(( ( ($1) + ALIGN - 1 ) / ALIGN * ALIGN )); }

SYSBYTES=$(stat -c %s "$SYSIMG")
SYS_SECTORS=$(align_up $(( (SYSBYTES + 511) / 512 + 2048 )))   # +1 МиБ запаса

P4=$HEAD
P4E=$(( P4 + SYS_SECTORS - 1 ))
P5=$(align_up $(( P4E + 1 )));  P5E=$(( P5 + VENDOR_SECTORS - 1 ))
P6=$(align_up $(( P5E + 1 )));  P6E=$(( P6 + CACHE_SECTORS - 1 ))
P7=$(align_up $(( P6E + 1 )));  P7E=$(( P7 + META_SECTORS - 1 ))
P8=$(align_up $(( P7E + 1 )));  P8E=$(( P8 + MISC_SECTORS - 1 ))
P9=$(align_up $(( P8E + 1 )));  P9E=$(( P9 + DATA_SECTORS - 1 ))
TOTAL=$(( P9E + 1 + 34 ))        # место под резервную копию GPT

echo "system.img: $SYSIMG ($(( SYSBYTES / 1024 / 1024 )) МиБ)"
echo "выход:      $OUT ($(( TOTAL * 512 / 1024 / 1024 )) МиБ)"
echo

# --- голова: MBR, GPT, idbloader, uboot, resource, загрузочный FAT ---
echo "== копирую первые $HEAD секторов из $(basename "$SRC")"
dd if="$SRC" of="$OUT" bs=512 count=$HEAD status=none
truncate -s $(( TOTAL * 512 )) "$OUT"

# --- vendor из исходного образа ---
VEN=$WORK/vendor.img
if [ ! -f "$VEN" ]; then
    echo "== вынимаю vendor из исходного образа"
    dd if="$SRC" of="$VEN" bs=512 skip=3317760 count=$VENDOR_SECTORS status=none
fi

# --- новая таблица разделов ---
echo "== переписываю GPT"
sgdisk --move-second-header "$OUT" > /dev/null
for n in 4 5 6 7 8 9; do sgdisk --delete=$n "$OUT" > /dev/null 2>&1 || true; done
sgdisk \
  --new=4:$P4:$P4E --change-name=4:system   --typecode=4:8300 \
  --new=5:$P5:$P5E --change-name=5:vendor   --typecode=5:8300 \
  --new=6:$P6:$P6E --change-name=6:cache    --typecode=6:8300 \
  --new=7:$P7:$P7E --change-name=7:metadata --typecode=7:8300 \
  --new=8:$P8:$P8E --change-name=8:misc     --typecode=8:8300 \
  --new=9:$P9:$P9E --change-name=9:userdata --typecode=9:8300 \
  "$OUT" > /dev/null
sgdisk --print "$OUT" | tail -12

# --- заливка разделов ---
LOOP=$(sudo losetup -P -f --show "$OUT")
trap 'sudo losetup -d "$LOOP" 2>/dev/null || true' EXIT
echo "== loop $LOOP"

echo "== system"
sudo dd if="$SYSIMG" of="${LOOP}p4" bs=4M status=none conv=fsync
echo "== vendor"
sudo dd if="$VEN" of="${LOOP}p5" bs=4M status=none conv=fsync

# --- убираем из vendor лаунчер Android 13 ---
# /vendor/app/syach1Home регистрируется как HOME и перехватывает экран: система
# грузится полностью, но показывает «starting SyachOS / Please wait» вместо
# оболочки GammaOS.
#
# Вместе с ним обязательно убрать syach1_validator: этот скрипт сверяет SHA-256
# апк и при несовпадении (в том числе если апк просто нет) **перезагружает
# устройство**, до трёх раз подряд. Удалить лаунчер и оставить сторожа — значит
# получить цикл перезагрузок.
echo "== правлю vendor"
sudo mkdir -p /mnt/imgven && sudo mount "${LOOP}p5" /mnt/imgven

# flydigi-mouse и flydigi-triggers — поддержка внешних геймпадов Flydigi. Обе
# службы безусловно создают постоянные виртуальные устройства, и мышиное из них
# имеет класс CURSOR. Android показывает курсор всё время, пока в системе есть
# хоть одно такое устройство, так что без этого курсор висит поверх интерфейса
# всегда, сколько ни правь rgp2pad. Flydigi здесь не нужен.
# Камеры в устройстве нет вовсе (dumpsys media.camera: Number of camera devices: 0),
# а vendor поднимает под неё HAL и объявляет возможности camera/autofocus/front —
# приложения считают, что камера есть. Вместе с cameraserver из GSI это около
# 21 МБ впустую.
#
# DRM для платного видео (widevine, clearkey, cas) на устройстве, где интернет
# нужен только для загрузки ROM-ов, не нужен.
#
# rgp2pad отключается: его место занимает штатный gammapad из GammaOS. Сам
# двоичный файл остаётся — если понадобится откатиться, его можно запустить
# руками: /vendor/bin/rgp2pad &
for p in app/syach1Home etc/init/syach1_validator.rc bin/syach1_validator.sh \
         etc/init/flydigi-mouse.rc etc/init/flydigi-reorder.rc \
         bin/flydigi-mouse bin/flydigi-triggers bin/flydigi-reorder \
         etc/init/android.hardware.camera.provider@2.4-service.rc \
         etc/permissions/android.hardware.camera.xml \
         etc/permissions/android.hardware.camera.autofocus.xml \
         etc/permissions/android.hardware.camera.front.xml \
         etc/init/android.hardware.drm-service.widevine.rc \
         etc/init/android.hardware.drm-service.clearkey.rc \
         etc/init/android.hardware.cas@1.2-service.rc \
         etc/init/rgp2pad.rc; do
    if [ -e "/mnt/imgven/$p" ]; then
        sudo rm -rf "/mnt/imgven/$p"
        echo "   удалено: /vendor/$p"
    fi
done

# rgp2pad своей сборки: создаёт виртуальную мышь только на время включённого
# режима (аккорд L3+R3) и уничтожает её при выключении — иначе курсор с экрана
# не уходит. Исходники в T:\Dump\RG52Mini\android\rgp2pad2.
RGP=/mnt/t/Dump/RG52Mini/android/rgp2pad2/out/rgp2pad2
if [ -f "$RGP" ] && [ -f /mnt/imgven/bin/rgp2pad ]; then
    sudo cp -f "$RGP" /mnt/imgven/bin/rgp2pad
    sudo chmod 755 /mnt/imgven/bin/rgp2pad
    echo "   заменён: /vendor/bin/rgp2pad ($(stat -c %s "$RGP") байт)"
fi

sync
# --- модули aic8800 из своей сборки ---
for m in aic8800_bsp.ko aic8800_fdrv.ko; do
    if [ -f "$KERNELDIR/$m" ]; then
        sudo cp "$KERNELDIR/$m" /mnt/imgven/lib/modules/"$m"
        sudo chmod 644 /mnt/imgven/lib/modules/"$m"
        echo "   модуль из своей сборки: /vendor/lib/modules/$m ($(stat -c %s "$KERNELDIR/$m") байт)"
    else
        echo "   !! нет $KERNELDIR/$m — в образе останется модуль из эталона"
    fi
done

sudo umount /mnt/imgven

# Раздел system править здесь нельзя: он собран с BOARD_EXT4_SHARE_DUP_BLOCKS
# (device/phh/treble/board-base.mk), такая ext4 монтируется только для чтения,
# а блоки в ней разделяются между файлами — удаление испортило бы соседние.
# Лишние системные службы гасятся через device/rg52mini/rg52-trim.rc.
echo "== cache, metadata"
sudo mke2fs -q -t ext4 -L cache    "${LOOP}p6" > /dev/null
sudo mke2fs -q -t ext4 -L metadata "${LOOP}p7" > /dev/null
echo "== misc (нули)"
sudo dd if=/dev/zero of="${LOOP}p8" bs=1M status=none conv=fsync 2>/dev/null || true
echo "== userdata оставлен пустым, отформатирует init"
sudo dd if=/dev/zero of="${LOOP}p9" bs=1M count=16 status=none conv=fsync

sync

# --- загрузочный раздел: своя строка загрузки ---
# Строка взята с работающего устройства (/proc/cmdline минус то, что дописывает
# сам u-boot: rw, earlycon, root=PARTUUID, androidboot.fwver). Единственное
# отличие — loglevel=7 вместо 5: консоль на 1.5 Мбод, лог того стоит.
#
# console=ttyFIQ0 и никакого console=tty1: тогда /dev/console — это uart0
# (узел fiq-debugger, rockchip,serial-id = 0, 1500000), и init сам поднимает на
# нём root-shell, а служба rg52logcat_con льёт туда же logcat.
echo "== правлю extlinux.conf"
sudo mkdir -p /mnt/imgboot && sudo mount "${LOOP}p3" /mnt/imgboot
sudo cp /mnt/imgboot/extlinux/extlinux.conf "$OUTDIR/extlinux.conf.orig" 2>/dev/null || true
sudo tee /mnt/imgboot/extlinux/extlinux.conf > /dev/null <<'EOF'
DEFAULT GammaOS
TIMEOUT 10
MENU TITLE RG52Mini GammaOS Core (Android 14)

LABEL GammaOS
    MENU LABEL GammaOS Core
    LINUX /Image
    FDT /rk3562-rg52mini.dtb
    INITRD /initrd.gz
    APPEND console=ttyFIQ0 firmware_class.path=/vendor/lib/firmware init=/init rootwait ro loop.max_part=7 8250.nr_uarts=10 storagemedia=sd androidboot.hardware=rk30board androidboot.boot_devices=ff880000.mmc androidboot.storagemedia=sd androidboot.mode=normal androidboot.force_normal_boot=1 androidboot.veritymode=disabled printk.devkmsg=on loglevel=7 fbcon=rotate:1 androidboot.selinux=permissive
EOF
sync
echo "== содержимое загрузочного раздела"
ls -la /mnt/imgboot | head -8
# --- ядро из своей сборки ---
# dtb намеренно оставляем из эталона: dts мы не меняли, а именно эта пара
# (новое ядро + прежний dtb) и проверена на устройстве.
if [ -f "$KERNELDIR/Image" ]; then
    sudo cp "$KERNELDIR/Image" /mnt/imgboot/Image
    echo "   ядро из своей сборки: $(stat -c %s "$KERNELDIR/Image") байт"
else
    echo "   !! нет $KERNELDIR/Image — в образе останется ядро из эталона"
fi
sync

sudo umount /mnt/imgboot

# --- проверки ---
echo
echo "== проверки"
sudo fsck.vfat -n "${LOOP}p3" 2>&1 | tail -2
for p in 4 5 6 7; do
    printf "p%s: " "$p"
    sudo e2fsck -fn "${LOOP}p$p" 2>&1 | tail -1
done

sudo losetup -d "$LOOP"; trap - EXIT
echo
echo "готово: $OUT"
ls -la "$OUT"

# --- копия в папку проекта на T: ---
publish "$OUT"
