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

# Интерактивная оболочка на отладочном порту после загрузки плюс подстраховка от
# чёрного экрана в nano - подробности в самом rg52-console.rc.
PRODUCT_COPY_FILES += \
    device/rg52mini/rg52-console.rc:system/etc/init/rg52-console.rc

# Восстановление домашнего экрана, если он остался не назначен: без него
# система показывает диалог выбора лаунчера, а он на этом устройстве
# недосягаем - висит под меню выключателя и не принимает ни кнопки, ни курсор.
# Так вышло после перезагрузки в безопасный режим. Подробности в самом скрипте.
PRODUCT_COPY_FILES += \
    device/rg52mini/rg52-home.sh:system/bin/rg52-home.sh \
    device/rg52mini/rg52-home.rc:system/etc/init/rg52-home.rc

# microG: вход в Google-аккаунт и проверка покупок без сервисов Google.
#
# Почему это вообще работает. microG выдаёт себя за Google Play Services, и для
# этого системе надо соглашаться подменять подпись пакета. В этом дереве такая
# поддержка уже есть и сделана узко (ComputerEngine.generateFakeSignature):
# подменяется только пакетам com.google.android.gms и com.android.vending,
# только при точном совпадении подписи с зашитым ключом microG и только на одну
# конкретную подпись Google. Правка фреймворка нам не понадобилась - проверено,
# что скачанные apk подписаны ровно тем ключом.
#
# Ставим привилегированными: иначе microG теряет часть возможностей. Для этого
# обязателен список разрешений в /system/etc/permissions, он собран из самих
# apk, см. privapp-permissions-microg.xml.
#
# Самих apk в репозитории нет, они качаются microg/fetch.sh с фиксированными
# версиями и контрольными суммами. GmsCore весит около 103 МБ - на столько же
# вырастает образ.
PRODUCT_COPY_FILES += \
    device/rg52mini/microg/com.google.android.gms-252432032.apk:system/priv-app/GmsCore/GmsCore.apk \
    device/rg52mini/microg/com.android.vending-84022632.apk:system/priv-app/GmsCompanion/GmsCompanion.apk \
    device/rg52mini/microg/privapp-permissions-microg.xml:system/etc/permissions/privapp-permissions-microg.xml

PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.rg52.console=shell

# Гашение служб, которым на этом устройстве нечего делать (сейчас —
# cameraserver: камер ноль). Почему не убрать из образа насовсем, написано
# в самом rg52-trim.rc: PRODUCT_REMOVE_PACKAGES в этом дереве не объявлена и
# ни на что не влияет, а править готовый system нельзя из-за
# BOARD_EXT4_SHARE_DUP_BLOCKS.
PRODUCT_COPY_FILES += \
    device/rg52mini/rg52-trim.rc:system/etc/init/rg52-trim.rc


# Штатный геймпад-демон GammaOS вместо vendor-овского rgp2pad. Умеет то же и
# больше: режим мыши (оба стика удержать 2 с), отображение в тачскрин,
# переназначение кнопок и калибровка с интерфейсом в настройках, вибрация.
# Виртуальную мышь создаёт только на время режима, поэтому курсор не залипает.
# Запускается по этому свойству, см. frameworks/native/services/gammapad.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.gammaos.gamepad.enable=1

# Режим мыши переключается нажатием на оба стика (BTN_THUMBL + BTN_THUMBR), как
# было в rgp2pad, — по умолчанию у gammapad это SELECT+R1. Коды проверены
# захватом с виртуального устройства: стики отдают именно 317 и 318, а L2 и R2
# на этом корпусе цифровых кодов не имеют вовсе, они аналоговые оси.
#
# Аккорд ловится по почти одновременному нажатию - механика перенесена из
# rgp2pad, см. MouseMode::handleChordButton. Удержание на секунды, как было у
# gammapad, убрано: оно пропускало нажатия в приложение всё время отсчёта.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.gammaos.gamepad.mouse_combo1=317 \
    persist.gammaos.gamepad.mouse_combo2=318

# Крестовина в режиме мыши остаётся крестовиной. По умолчанию gammapad водит ею
# курсор с фиксированной скоростью, но на этом корпусе курсором удобнее править
# левым стиком, а крестовина нужнее по прямому назначению — в эмуляторе или
# в меню поверх режима мыши.
#
# Нулевая скорость трактуется как «не эмулировать»: события крестовины не
# съедаются, а уходят на виртуальный геймпад как обычно (MouseMode::processEvent,
# ветки ABS_HAT0X/Y и BTN_DPAD_*). Заодно пропускается SYN этого кадра — иначе
# ядро не отдало бы событие потребителю, потому что в режиме мыши SYN тоже
# съедается.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.gammaos.gamepad.mouse_dpad_speed=0

# Раскладка режима мыши под этот корпус.
#
#   L3 - левая кнопка (нажатие эмулируется касанием тачскрина в точке курсора,
#        так это сделано в gammapad изначально и так работает в TV-приложениях)
#   R3 - правая кнопка
#   A, B, X, Y и всё остальное - обычные кнопки геймпада, как и вне режима мыши
#
# Кроме стиков режим мыши ни на что не завязан: замедление курсора убрано,
# скорость по кривой и так комфортна на всём ходу.
#
# Те же две кнопки остаются аккордом включения и выключения. Аккорд ловится по
# почти одновременному нажатию, как в rgp2pad, поэтому одиночное нажатие
# работает кнопкой мыши и ничего лишнего в приложение не уходит. Окно - 80 мс
# (persist.gammaos.gamepad.mouse_chord_ms), оно же задержка, с которой
# одиночное нажатие превращается в щелчок.
#
# mouse_btn_back=0 отключает привязку: код 0 не приходит никогда, поэтому B
# просто уходит в приложение. Кнопка "назад" на корпусе работает как обычно,
# она отдельная.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.gammaos.gamepad.mouse_btn_click=317 \
    persist.gammaos.gamepad.mouse_btn_rclick=318 \
    persist.gammaos.gamepad.mouse_btn_back=0

# Триггеры LT и RT у этого корпуса перепутаны местами. Железо отдаёт их двумя
# аналоговыми осями, ABS_GAS (0x09) и ABS_BRAKE (0x0a), обе 0..255 - проверено
# через getevent -p на самом джойстике; осей HAT2, о которых говорил старый
# комментарий в нашей раскладке, у него нет вовсе. Левый триггер приходит на
# ABS_GAS, а в Android газ - это правый триггер, отсюда и перестановка в играх.
#
# Меняем оси местами на выходе. Роли (role_lt/role_rt) для этого не годятся:
# они задают распределение целиком, и частичная установка уводит оси правого
# стика в триггеры - проверено на устройстве, стик ломается.
#
# Само свойство до этого не работало вовсе: перестановка применялась только к
# запасной глобальной карте, а при обработке событий берётся пер-девайсная.
# Исправлено в GamepadManager::rebuildGlobalMaps.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.gammaos.gamepad.remap_axis=9:10,10:9

# GammaToast из образа убран. Строка GammaToast удалена из PRODUCT_PACKAGES в
# device/phh/treble/base.mk и lineage_tv_arm64_bvN.mk: отсюда его не выключить,
# PRODUCT_REMOVE_PACKAGES в этом дереве не существует (не объявлена ни в
# product.mk, ни в product_config.mk, ни в main.mk), так что все такие строки в
# makefile-ах GammaOS - пустышки.
#
# На код ничего не завязано: во frameworks и в gammapad обращений к нему нет,
# всплывающие сообщения идут через обычный Toast API.

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
# Оверлей ресурсов платформы. Пока в нём одна правка - выключение zram
# writeback, которое нам включает RRO из vendor от DOOGEE. Подробности и способ
# проверки - в самом файле overlay/frameworks/base/core/res/res/values/config.xml.
#
# Оверлеи продукта перекрывают оверлеи vendor: порядок разделов в OverlayConfig
# - system, system_ext, vendor, odm, oem, product, и чем позже, тем выше
# приоритет. Из-за PRODUCT_ENFORCE_RRO_TARGETS := * оверлей станет отдельным
# RRO-пакетом (framework-res__lineage_tv_arm64_bvN__auto_generated_rro_product.apk
# в /system/product/overlay), а не вкомпилируется в framework-res.
PRODUCT_PACKAGE_OVERLAYS += device/rg52mini/overlay

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

# Имя устройства для штатного механизма обновлений GammaOS. По нему
# /system/bin/gammaos-ota сверяет поле device в manifest.json пакета и
# отказывается ставить чужую прошивку. В GammaOS свойство задаётся в
# конфигурации каждого устройства; у нас его не было, и проверка отвергала
# любой пакет («Device '' not compatible»).
#
# Механизм даёт перепрошивку без извлечения карты: пакет распаковывается в
# /data и пишется прямо в /dev/block/by-name/system, с которого в этот момент
# смонтирован корень. Разделов super на этом устройстве нет, поэтому в
# manifest.json они описываются как physical - подробности и сборка пакета в
# device/rg52mini/tools/make-ota.sh.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    ro.gammaos.device=rg52mini

# Режимы производительности. В GammaOS это одно свойство
# persist.gammaos.performance_mode, а применяют его скрипты
# /vendor/bin/setclock_<режим>.sh вместе с init.gammaos_power.rc — и то и
# другое приходит с vendor каждого устройства. В нашем vendor (он от SyachOS)
# их нет, поэтому все три режима в меню не делали ничего: свойство менялось,
# регуляторы оставались на месте. Проверено на устройстве — переключение
# stock/max/powersave не меняло ни scaling_governor, ни границы частот, ни
# регулятор графики.
#
# rg52-perf.rc заводит службы с теми же именами (setclock_<режим>), что
# ожидает код GammaOS, и добавляет триггеры по свойству: меню выключателя,
# плитка быстрых настроек и оболочка nano только пишут свойство и ничего не
# запускают. Значения частот взяты из perf_apply.sh самой SyachOS, разбор —
# в rg52-perf.sh.
PRODUCT_COPY_FILES += \
    device/rg52mini/rg52-perf.sh:system/bin/rg52-perf.sh \
    device/rg52mini/rg52-perf.rc:system/etc/init/rg52-perf.rc

# Размер zram. Vendor заводит его на 100 % памяти (fstab.rk30board,
# zramsize=100%), и при таком объёме ядро набивает только его, а до файла
# подкачки очередь не доходит никогда: сжатые страницы продолжают занимать ту же
# физическую память. Мерили на игре, которой нужно около 1,8 ГБ (память 2 ГБ,
# файл подкачки 2 ГБ): при zram 1,9 ГБ её убивали через минуту, при 512 МБ — через
# три, при выключенном zram она играет. Разбор — в самом скрипте.
#
# 512 МБ и файл подкачки идут парой: по отдельности 512 МБ означали бы, что
# подкачки стало меньше, чем было (0,5 ГБ вместо 1,9), а вместе получается
# 2,5 ГБ, из которых память занимают только 512 МБ.
PRODUCT_COPY_FILES += \
    device/rg52mini/rg52-zram.sh:system/bin/rg52-zram.sh \
    device/rg52mini/rg52-zram-wb.sh:system/bin/rg52-zram-wb.sh \
    device/rg52mini/rg52-zram.rc:system/etc/init/rg52-zram.rc

# zram остаётся большим (как и заводил vendor), но получает подложку на карте и
# сторож, который сбрасывает на неё содержимое при нехватке памяти. Проверено:
# игра, которой нужно около 1,8 ГБ, при заводской настройке умирала через минуту,
# а с подложкой играет - за две минуты через неё прошло 700 МБ.
#
# Место под подложку берётся из той же настройки, что раньше задавала файл
# подкачки (persist.gammaos.swap.size_mb, строка «Virtual memory» в настройках):
# при включённом zram отдельный файл смысла не имеет, и gammaos-swap.sh в этом
# случае уступает.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.rg52.zram.size_mb=1900 \
    persist.rg52.zram.wb_threshold_mb=300 \
    persist.gammaos.swap.size_mb=2048

# Сжатие zram. Разбор — в device/rg52mini/rg52-zram.rc.
PRODUCT_COPY_FILES += \
    device/rg52mini/rg52-zram.rc:system/etc/init/rg52-zram.rc

PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.rg52.zram.algo=lz4

# Сборщик мусора ART с уплотнением (userfaultfd CMC) здесь не включается —
# у GammaOS для этого свой рычаг, и он снаружи.
#
# В device/phh/treble/lineage_tv_arm64_bvN.mk стоит развилка по GAMMAOS_BOOT_GC:
# пусто -> PRODUCT_ENABLE_UFFD_GC := true (уплотняющий), cc -> false
# (копирующий). Два варианта существуют потому, что GSI не несёт ядра, а
# сборщик выбирает ядро: с userfaultfd работает CMC, без него ART откатывается
# на копирующий с барьерами чтения. Загрузочный образ бывает только под один
# из них, и если он не совпал со средой выполнения, проверка ValidateOatFile
# падает и zygote пересобирает весь boot classpath при каждой загрузке.
#
# Выбирается это скриптом сборки: buildtv.sh — уплотняющий, buildtv_cc.sh —
# копирующий. Присваивать PRODUCT_ENABLE_UFFD_GC здесь бесполезно: значение из
# base.mk приходит раньше, а art_config.mk берёт firstword.

# Видимость телефонных приложений в магазинах. Разбор - в самом файле,
# device/rg52mini/rg52-features.xml. Свойство задаётся явно, чтобы состояние
# было видно в getprop, а не выводилось из отсутствия строки.
PRODUCT_COPY_FILES += \
    device/rg52mini/rg52-features.xml:system/etc/permissions/rg52-features.xml

PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.rg52.tv_only=false
