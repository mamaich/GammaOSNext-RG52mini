# GammaOS Next для карманной консоли AISLPC RG52 Mini

Форк [TheGammaSqueeze/GammaOSNextDistribution-14](https://github.com/TheGammaSqueeze/GammaOSNextDistribution-14)
— дерева исходников GammaOS Next (LineageOS 21 / Android 14), доработанного под
**AISLPC RG52 Mini** на Rockchip RK3562.

## Что здесь делается

На устройстве уже работает порт Android 13 (SyachOS), но исходников его
Android-части нет — автор по лицензии выложил только ядро. Дорабатывать дальше
нечего, поэтому система собирается заново из исходников.

Дерево собирает **только GSI**, то есть раздел `system`. Остальное берётся из
своих сборок и из проверенного образа:

| Часть образа | Откуда |
|---|---|
| `system` | **эта сборка** — GammaOS Core, Android 14 |
| `vendor` | из рабочего образа SyachOS: Wi-Fi/Bluetooth AIC8800D80, `rgp2pad`, HAL-ы Rockchip |
| ядро, DTB | [mamaich/kernel_rk3562_rg52mini](https://github.com/mamaich/kernel_rk3562_rg52mini) — Linux 5.10.226 |
| загрузчик | [mamaich/u-boot-rk3562-rg52mini](https://github.com/mamaich/u-boot-rk3562-rg52mini) |

Такая стыковка возможна потому, что порт Android 13 у этого устройства
Treble-совместимый (`ro.treble.enabled=true`, `ro.vndk.version=33`), а в дереве
есть снимок VNDK v33 для vendor-библиотек от Android 13.

## Почему именно GammaOS Next

У RG52 Mini **нет сенсорного экрана** — только геймпад, D-pad и несколько
кнопок. GammaOS Core (вариант на базе Android TV) рассчитан ровно на это:
интерфейс полностью проходится с геймпада, в образ уже вшиты RetroArch, PPSSPP,
Flycast, DraStic, mupen64plus, Daijishō, и вырезана телефония, которой на
устройстве без модема взяться неоткуда.

## С чего начать

| | |
|---|---|
| **Что за устройство, что за исходники и как это стыкуется** | [doc/rg52mini/01-разбор.md](doc/rg52mini/01-разбор.md) |
| **План работ, принятые решения и открытые вопросы** | [doc/rg52mini/02-план.md](doc/rg52mini/02-план.md) |
| **Собрать самому** | [doc/rg52mini/03-сборка.md](doc/rg52mini/03-сборка.md) |

## Состояние

Работа идёт. Готового образа пока нет.

| Этап | Состояние |
|---|---|
| Разбор устройства, vendor и загрузки | готово |
| Проверка совместимости Treble | готово |
| Дерево исходников развёрнуто | готово |
| Отдельный продукт сборки | **не нужен** — стандартная цель даёт нужную разметку |
| Устройство-зависимые добавки (`device/rg52mini/`) | готово, подключено к цели |
| Сборка `system.img` | прошла: 3 ч 24 мин первая, 8 мин повторная |
| Снимок VNDK 33 для vendor от Android 13 | в образе есть, `/system_ext/apex/com.android.vndk.v33.apex` |
| Образ SD-карты | собран и проверен, 5.09 ГБ |
| Загрузка на устройстве | **следующий шаг** |

## Сборка апстрима

Всё, что относится к самому GammaOS Next, не тронуто и работает как у автора:

    bash buildtv.sh nosync      # GammaOS Core (Android TV), ядра новее 5.7
    bash buildtv_cc.sh nosync   # то же, но boot-образ ART под ядра без userfaultfd
    bash build.sh nosync        # GammaOS Next Lite (обычный интерфейс)

Для RG52 Mini берётся `buildtv_cc.sh`: в ядре устройства выключен
`CONFIG_USERFAULTFD`, поэтому ART работает сборщиком мусора CC, и boot-образ
должен быть собран под него же. Подробности — в
[doc/rg52mini/02-план.md](doc/rg52mini/02-план.md).
