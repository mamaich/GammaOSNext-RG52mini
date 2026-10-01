# HDMI на RG52 Mini

Как устроен выход HDMI в этой сборке GammaOS Next: что умеет железо, кто
выбирает режим, какие есть настройки и что из них работает. Собрано по
опытам на устройстве (30.09–01.10.2026), README апстрима GammaOS Next и
комментариям в исходниках.

## Железо

* **Мост rk628.** У RK3562 своего HDMI нет: видеоконтроллер (VOP) выводит
  параллельный RGB, мост rk628 на шине I2C (`i2c@ffa30000`, адрес 0x50)
  превращает его в HDMI. Узел моста в нашем дереве устройства байт в байт
  совпадает со стоковыми деревьями v1.0 и v1.4.
* **Потолок — 148,5 МГц пиксельной частоты**, то есть 1920×1080 при 60 Гц
  (`rk628_hdmi_connector_mode_valid`), и ядро не предлагает режимы больше
  1920×1080 (`rk628_hdmi_probe_single_connector_modes`). 4K не будет.
* **Видеоконтроллер один.** В `/sys/kernel/debug/dri/0/summary` есть только
  Video Port 0, и встроенный экран (DSI-1) и HDMI-A-1 сидят на одном CRTC.
  Два экрана одновременно не работают: HWC при подключении HDMI отдаёт
  контроллер телевизору, а встроенный экран отпускает — в его свойствах это
  видно как `vendor.hwc.device.display-0 = DSI-1:71:release`,
  `display-1 = HDMI-A-1:71:connected:compete`. Поэтому **встроенный экран
  гаснет, пока подключён HDMI** — так же и в стоковой прошивке. Это не
  поломка.
* **EDID без ответа.** Если EDID телевизора прочитать не удалось, драйвер
  берёт список Rockchip (`rockchip_drm_add_modes_noedid`): 1280×720@60
  (предпочтительный), 1920×1080@60 и @50, 1280×720@50, 1024×768, 720×576,
  720×480. Ядро про это пишет `failed to get edid`.

## Кто выбирает режим

Не наш код, а бинарный HWC от vendor (`hwcomposer.rk30board.so`). По порядку:

1. `persist.vendor.resolution.aux` (для встроенного экрана —
   `persist.vendor.resolution.main`);
2. без него — раздел `baseparameter` (настройки дисплеев Rockchip); на нашей
   карте его нет;
3. иначе — лучший режим из списка ядра, то есть предпочтительный режим
   телевизора по EDID.

Ещё HWC читает белый список режимов `/system/usr/share/resolution_white.xml`;
в нашей системе (GSI) его нет, и это ни на что не влияет.

Что выяснено опытами про значение свойства:

| Значение | Что делает HWC |
|---|---|
| пусто | автовыбор (как в п. 3) |
| `1280x720@60` | ищет режим в списке ядра; частота должна совпасть, целое число годится (`640x480@60` находит режим 59,94 Гц) |
| `720x576` или `720x576@60`, когда у телевизора он только на 50 Гц | молча берёт автовыбор |
| `1280x720@60.00-1390-1430-1650-725-730-750-5-74250` | строит режим сам по таймингам (ширина × высота @ частота - начало, конец и полная длина строки - то же для кадра - флаги синхроимпульсов hex - частота пикселей в кГц), даже если телевизор его не назвал |

**Применить без переподключения кабеля:** увеличить
`vendor.display.timeline` — HWC перечитывает режим на следующем кадре (так
делают настройки дисплея Rockchip). `sys.resolution.changed` на это не
влияет.

```
adb shell setprop persist.vendor.resolution.aux 1280x720@60
adb shell setprop vendor.display.timeline $RANDOM
```

Вернуть автовыбор — то же с пустым значением `""`.

### Выбор режима в GammaOS Toolbox

GammaOS Toolbox → External Display → **HDMI output mode** («Режим выхода
HDMI»). Делает ровно это: пишет свойство и увеличивает
`vendor.display.timeline`, режим меняется сразу.

* «Авто» — пустое свойство, по умолчанию;
* режимы, которые сообщил телевизор. Частоты берутся разбором самого EDID из
  `/sys/class/drm/card0-HDMI-A-1/edid` (установленные и стандартные
  тайминги, подробные описатели, короткие описатели видео CEA-861): в
  `/sys/class/drm/card0-HDMI-A-1/modes` есть только ширина и высота. Размеры,
  которые ядро отбросило, в список не попадают;
* всегда 640×480, 1024×768, 1280×720, 1920×1080 при 60 Гц — полной записью с
  таймингами, так что работают и без EDID;
* порядок — по высоте, потом по ширине.

Код — `packages/apps/Settings/src/com/android/settings/handheld/HdmiModes.java`.

## Что показывать на HDMI

Это уже логика GammaOS (`DisplayManagerService`, `DisplayContent`,
`RootWindowContainer`, `ActivityTaskManagerService`). Настройки — в трёх
местах с одними и теми же свойствами: GammaOS Toolbox → External Display,
меню Nano (Settings → External Display) и плитки быстрых настроек.

| Свойство | Toolbox | Nano | Плитка | Что делает |
|---|---|---|---|---|
| `persist.gammaos.ext.force_mirror` | Force mirror mode | Force Mirror | [HDMI] Mirror internal screen | на HDMI — копия всего основного экрана, а не отдельный рабочий стол |
| `persist.gammaos.ext.mirror_resize` | Mirror resize | Mirror Resize / Resize to External Display | [HDMI] Resize to external display | основной экран подгоняется под размер телевизора, а не растягивается |
| `persist.gammaos.ext.primary` | External as primary | External as Primary | [HDMI] Internal Display Off | «док-станция»: основной экран подгоняется под телевизор и зеркалится на него, подсветка встроенного выключается; при отключении HDMI яркость возвращается |
| `persist.gammaos.ext.half_4k` | Halve 4K resolution | Half 4K | — | 4K-телевизор как 1080p; нам не нужно, rk628 выше 1080p не умеет |
| `persist.gammaos.sec_force_on` | Force secondary display on | Secondary Force On | — | не давать системе гасить второй дисплей |
| `persist.gammaos.secondary_home` | Secondary display home app | Secondary Home Package | — | лаунчер второго дисплея (по умолчанию `com.gammaos.secondaryhome`) |
| `persist.gammaos.secondary_display.enabled`, `.packages` | Route apps to secondary, Secondary display packages | Secondary Display Apps | — | запускать перечисленные приложения сразу на втором дисплее |
| `persist.gammaos.display.delay.external_frames`, `.primary_frames` | External/Primary display frame delay | — | — | задержка вывода в кадрах для синхронизации экранов (SurfaceFlinger) |

Все `ext.*` читаются **в момент подключения дисплея** (по комментарию в Nano —
«DMS/WM consume on the next HDMI/DP hotplug»): после переключения выньте и
вставьте кабель. Значения `true`/`false` и `1`/`0` равноценны.

README апстрима называет связку `ext.primary` + подгонку размера **HDMI
Docking Mode**: «при подключении HDMI встроенный экран может выключаться, а
система подгоняется под разрешение внешнего дисплея — как у приставки».

**У нас Force mirror mode включён по умолчанию** (`rg52mini.mk`, с 01.10.2026).
В заводском GammaOS он выключен, и тогда HDMI — **отдельный дисплей** (своя
группа дисплеев, своя плотность 320 dpi, лаунчер второго дисплея): туда уходит
приложение, а не копия экрана. На RG52 Mini это неудобно — встроенный экран
всё равно гаснет, — поэтому по умолчанию копия всего экрана. Если картинка
растягивается, включите ещё Mirror resize.

### Вопрос «Mirror to external display?»

Android 14 подключает новый внешний дисплей выключенным, пока пользователь
не ответит в диалоге SystemUI (`ConnectingDisplayViewModel`,
`MirroringConfirmationDialog`). На RG52 Mini диалог рисуется на встроенном
экране, который к этому времени уже погас, — его видно, только если дважды
нажать выключатель (усыпить и разбудить).

* В AOSP есть свойство, которое вместо вопроса сразу включает дисплей:
  `persist.sysui.disable_mirroring_confirmation_dialog=true`.
* Мы добавили к нему: при включённом Force mirror mode или External as
  primary вопрос тоже не задаётся — ответ всё равно «зеркалировать».
* **Не помогает** выключить сам механизм:
  `persist.sys.com.android.server.display.feature.flags.enable_connected_display_management-override=false`
  (переопределение флага на userdebug). Вопроса нет, но HDMI остаётся чёрным:
  дисплей так и висит в состоянии `UNKNOWN`, его некому включить. GammaOS
  рассчитывает на этот механизм.

## Диагностика

```
cat /sys/class/drm/card0-HDMI-A-1/status          # connected / disconnected
wc -c < /sys/class/drm/card0-HDMI-A-1/edid        # 0 - EDID не прочитан
cat /sys/class/drm/card0-HDMI-A-1/modes           # режимы, которые оставило ядро
grep -A6 "^Video Port" /sys/kernel/debug/dri/0/summary   # что реально выводится
getprop | grep -E "vendor.hwc.device|persist.vendor.resolution"
logcat -d | grep -E "hwc-drm-connector|BindConnectorAndCrtc|GammaOS:"
dumpsys display | grep "HDMI Screen"
dmesg | grep -iE "rk628|hdmi|edid"
```

В журнале HWC по строке `UpdateDisplayMode ... Find best mode-id=…` видно,
какой режим он выбрал и почему: номер строки 465 — полная запись с
таймингами, 494 — короткая запись, 536 — автовыбор.

## Открытые вопросы

* Жалоба «на телевизоре как будто 640×480» (устройство с неисправным, по
  словам владельца, контроллером HDMI) пока без данных. Без EDID ядро
  предлагает 1280×720, так что дело, видимо, не в пустом EDID; нужен вывод
  команд из «Диагностики» с того устройства. Обход — выбрать режим в Toolbox.
