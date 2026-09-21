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

# logcat в последовательную консоль и в файл на /metadata — главный инструмент
# отладки, пока система не поднимется до adb.
PRODUCT_COPY_FILES += \
    device/rg52mini/rg52logcat.rc:system/etc/init/rg52logcat.rc

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
