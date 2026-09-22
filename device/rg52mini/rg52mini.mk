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

# Гашение служб, которым на этом устройстве нечего делать (сейчас —
# cameraserver: камер ноль). Почему не убрать из образа насовсем, написано
# в самом rg52-trim.rc: PRODUCT_REMOVE_PACKAGES в этом дереве не объявлена и
# ни на что не влияет, а править готовый system нельзя из-за
# BOARD_EXT4_SHARE_DUP_BLOCKS.
PRODUCT_COPY_FILES += \
    device/rg52mini/rg52-trim.rc:system/etc/init/rg52-trim.rc


# Штатный геймпад-демон GammaOS вместо vendor-овского rgp2pad. Умеет то же и
# больше: режим мыши (SELECT+R1 удержать 2 с), отображение в тачскрин,
# переназначение кнопок и калибровка с интерфейсом в настройках, вибрация.
# Виртуальную мышь создаёт только на время режима, поэтому курсор не залипает.
# Запускается по этому свойству, см. frameworks/native/services/gammapad.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.gammaos.gamepad.enable=1

# Визуальное подтверждение переключения режима мыши: экран коротко моргает
# инверсией. Всплывающая надпись gammapad в полноэкранной игре может быть не
# видна, а в rgp2pad, откуда сюда переходят, моргание было.
#
# Делаем службой init, а не правкой gammapad: вызов system("settings ...") из
# демона не срабатывает - оболочка запускается, а настройка не меняется, и
# причину не видно, потому что вывод уходит в /dev/null. Служба работает от
# shell в домене u:r:shell:s0, где эта команда заведомо работает, и пишет в
# лог, если что-то пошло не так. Подробности в самом скрипте.
PRODUCT_COPY_FILES += \
    device/rg52mini/rg52-mouseflash.sh:system/bin/rg52-mouseflash.sh \
    device/rg52mini/rg52-mouseflash.rc:system/etc/init/rg52-mouseflash.rc

# Кнопки HOME и BACK корпуса. Драйвер play_joystick отдаёт их как коды
# геймпада: BTN_MODE (316) для HOME и BTN_TRIGGER_HAPPY1 (704) для BACK.
#
# Раскладку Android подбирает по VID/PID устройства, а не по имени файла, и
# для 045e:0b13 подходящего Vendor_045e_Product_0b13.kl в системе нет — оба
# устройства, и физическое, и виртуальное, получают Generic.kl. А в ней 316
# значит BUTTON_MODE (то есть не HOME), кода 704 нет вовсе — поэтому BACK не
# работал совсем. Наш device/rg52mini/keylayout/rk3562-joystick.kl сюда не
# подходит: по этому имени Android раскладку не ищет.
#
# Своего .kl тут мало: gammapad читает ту же раскладку для физического
# устройства и переводит коды ещё до uinput, но виртуальный геймпад объявляет
# исходные коды, поэтому «key 704 BACK» превратился бы в KEY_BACK, которого у
# виртуального устройства нет, и событие потерялось бы в ядре.
#
# Переназначение самим gammapad такой проблемы не создаёт: цели remap_btn он
# добавляет в набор кнопок виртуального устройства (GamepadManager.cpp,
# computeRequiredCodes). Отдаём сразу KEY_HOMEPAGE (172) и KEY_BACK (158) —
# их Generic.kl уже знает как HOME и BACK.
#
# Заодно это чинит кнопку Guide на внешних Bluetooth-геймпадах: она тоже
# BTN_MODE и тоже станет HOME.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.gammaos.gamepad.remap_btn=316:172,704:158

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

# Оболочка GammaOS Nano (пункт «Boot nano» в меню выключателя) рисует напрямую
# через DRM/KMS, мимо SurfaceFlinger. Поворот установки она берёт из свойства
# выше и учитывает его правильно, но зеркальность сканирования панели строкой
# ORIENTATION_* не выражается — под неё в nano есть отдельные поправки
# (NanoMenuDrm.cpp, drmEarlySplash). Без этой строки экран в nano выходит
# перевёрнутым и отражённым слева направо, то есть зеркальным по вертикали.
#
# Для RG Vita Pro в исходниках nano описан ровно такой же случай: «270 install
# + drm_flip_v=1». Проверено на устройстве: с этой поправкой картинка верная.
# Обычного Android не касается — там всё рисует SurfaceFlinger.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.gammaos.nano.drm_flip_v=1

# Аппаратные кодеки Rockchip. Без этого свойства Codec2 идёт за буферами в
# legacy ION, а он на этом ядре не отвечает:
#
#   E/ion         : ioctl c0184900 failed with code -1: No such device
#   E/C2RKMpiEnc  : failed to fetch block for output, ret 0xe
#   E/MediaCodec  : Codec reported err 0xe/14, while in state 6/STARTED
#
# Со свойством Codec2 берёт буферы из /dev/dma_heap, и кодирование работает
# (проверено записью экрана через scrcpy). В порте Android 13 это свойство
# тоже стояло — потерялось вместе с его разделом system.
#
# media_vol_steps: 25 шагов громкости вместо 15, на карманной консоли заметно
# удобнее. Тоже было в Android 13.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    debug.c2.use_dmabufheaps=1 \
    ro.config.media_vol_steps=25

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
    ro.config.low_ram=false \
    persist.gammaos.lazy32=0

# Про persist.gammaos.lazy32=0 выше — из-за него не работал WebView.
#
# GammaOS экономит память «ленивым» 32-битным зиготом: atv_lowram_defaults.mk
# ставит ro.zygote.disable_secondary=1, init не поднимает zygote_secondary при
# загрузке, ZygoteProcess поднимает его при первом 32-битном форке, а AMS через
# 15 секунд после выхода последнего 32-битного приложения его убивает
# (ActivityManagerService.maybeScheduleSecondaryZygoteReap).
#
# WebView в этот расчёт не укладывается. PackageManager определяет apk WebView
# как armeabi-v7a (arm64 у него вторым), поэтому дочерний зигот WebView —
# 32-битный и форкается из zygote_secondary. Жнец его не видит: он считает
# только 32-битные процессы приложений (countLive32BitProcsLOSP), а дочерний
# зигот приложением не является. Через 15 секунд после загрузки родителя
# убивают, а осиротевший webview_zygote остаётся с дескрипторами, открытыми в
# уже отсоединённом пространстве монтирования: readlink отдаёт /null вместо
# /dev/null и /javalib/core-oj.jar вместо /apex/com.android.art/javalib/...
#
# При первом же форке рендерера зигот сверяет таблицу дескрипторов и падает:
#
#   Abort message: JNI FatalError called: (zygote) Not allowlisted (7): /null
#   FileDescriptorInfo::CreateFromFd -> FileDescriptorTable::RestatInternal
#
# Дальше хуже: system_server держит ссылку на мёртвый зигот и заново его не
# создаёт (WebViewZygote.getProcess возвращает ненулевой sZygote, не проверяя,
# жив ли тот), поэтому до перезагрузки каждая попытка кончается
# «Error connecting to zygote». Снаружи это чёрная страница без единой ошибки:
# в браузере GammaOS, в окне авторизации Aurora Store — везде, где рисует
# WebView. Firefox работает, потому что у него свой движок Gecko.
#
# Ставим 0 — zygote_secondary поднимается по требованию и больше не убивается.
# Цена по dumpsys meminfo: около 62 МБ приватной памяти, и только после того,
# как запустится первое 32-битное приложение. Проверено на устройстве: страница
# открывается, рендерер живёт (com.android.webview:sandboxed_process0).
#
# Свойство пишем в product: у GammaOS оно задано в PRODUCT_SYSTEM_PROPERTIES,
# то есть в /system/build.prop, а /product/etc/build.prop читается позже и
# перекрывает его (порядок в PropertyLoadBootDefaults: system -> system_ext ->
# vendor -> odm -> product).
