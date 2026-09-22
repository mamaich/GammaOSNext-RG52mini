# AISLPC RG52 Mini — то, что в порте Android 13 лежало в разделе system и
# теряется вместе с ним при замене на GSI.
#
# Подключается одной строкой в конце device/phh/treble/lineage_tv_arm64_bvN.mk:
#     $(call inherit-product-if-exists, device/rg52mini/rg52mini.mk)
# Одна строка, чтобы её было легко переносить при обновлении апстрима.

# Раскладки ввода. Геймпад система видит как виртуальный Xbox-контроллер от
# vendor-демона rgp2pad, а вот кнопки громкости (adc-keys) без своей раскладки
# не работают.
PRODUCT_COPY_FILES += \
    device/rg52mini/keylayout/adc-keys.kl:system/usr/keylayout/adc-keys.kl \
    device/rg52mini/keylayout/rk3562-joystick.kl:system/usr/keylayout/rk3562-joystick.kl \
    device/rg52mini/keylayout/idroid_con.kl:system/usr/keylayout/idroid_con.kl \
    device/rg52mini/idc/rk3562-joystick.idc:system/usr/idc/rk3562-joystick.idc

# Расширение userdata на всю карту при первой загрузке. sgdisk есть в
# external/gptfdisk, но в GSI сам по себе не попадает.
PRODUCT_COPY_FILES += \
    device/rg52mini/rg52-resize.sh:system/bin/rg52-resize.sh \
    device/rg52mini/rg52-resize.rc:system/etc/init/rg52-resize.rc

PRODUCT_PACKAGES += \
    sgdisk

# Снимок VNDK 33 здесь намеренно НЕ перечислен: апексы com.android.vndk.v28...v34
# и так попадают в /system_ext/apex через PRODUCT_EXTRA_VNDK_VERSIONS. Проверять
# его наличие обязательно (см. scripts/check-sysimg.sh): без v33 не слинкуется ни
# один vendor-HAL — раздел vendor от Android 13 не носит своих копий
# libhidlbase/libutils/libcutils/libc++/libbase/libhardware.

# logcat в последовательную консоль и в файл на /metadata — главный инструмент
# отладки, пока система не поднимется до adb.
PRODUCT_COPY_FILES += \
    device/rg52mini/rg52logcat.rc:system/etc/init/rg52logcat.rc

# Root здесь даёт KernelSU-Next, вшитый в ядро (ядро само ищет /data/adb/ksud,
# а драйвер «коронует» менеджера по подписи — проверено на устройстве:
# «Crowning manager: com.rifsxd.ksunext»). Magisk на этом устройстве не работает
# вовсе: загрузочный образ им не патчен, и установленный Magisk лишь пишет
# «Magisk is not installed». Свойство читает gammaos/customization.sh: оно
# пропускает установку Magisk и ставит вместо неё менеджер KernelSU.
PRODUCT_COPY_FILES += \
    device/rg52mini/KernelSUNext.apk:system/etc/KernelSUNext.apk

PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    ro.rg52.root=kernelsu

# Экранная клавиатура. Штатная leanback-клавиатура Android TV рассчитана на
# пульт и на этом устройстве неудобна; LeanKey ходится по D-pad заметно лучше.
# Кладётся системным приложением, а rg52-ime.sh удерживает её как метод ввода
# по умолчанию: система возвращает свою уже после загрузки, когда поднимется
# служба ввода, поэтому одной записи не хватает.
PRODUCT_COPY_FILES += \
    device/rg52mini/LeanKeyKeyboard.apk:system/app/LeanKeyKeyboard/LeanKeyKeyboard.apk \
    device/rg52mini/rg52-ime.sh:system/bin/rg52-ime.sh \
    device/rg52mini/rg52-ime.rc:system/etc/init/rg52-ime.rc

# Панель физически портретная (720x1280), используется в альбомной ориентации.
# В Android 13 это стояло в /system/build.prop; vendor этого свойства не задаёт
# вовсе, так что без строки ниже SurfaceFlinger возьмёт ORIENTATION_0.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    ro.surface_flinger.primary_display_orientation=ORIENTATION_90

# Свойства, которые обязаны перебить vendor. Порядок загрузки в
# system/core/init/property_service.cpp: чем специфичнее раздел, тем выше
# приоритет, и product идёт после vendor. Ровно так это и было сделано в
# Android 13: /product/etc/build.prop перекрывал /vendor/build.prop.
#
#   ro.sf.lcd_density   — в vendor лежит 186, рабочее значение 213
#   ro.config.low_ram   — ATV-база GammaOS ставит true через vendor-свойства;
#                         у устройства 2 ГБ ОЗУ, режим Android Go тут вреден
PRODUCT_PRODUCT_PROPERTIES += \
    ro.sf.lcd_density=213 \
    ro.config.low_ram=false
