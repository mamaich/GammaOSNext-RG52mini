# Выпуск v1.15

GammaOS Next (LineageOS 21 / Android 14) для карманной консоли **AISLPC RG52 Mini**
на Rockchip RK3562. Здесь перечислено то, что изменилось после
[v1.14](release-v1.14.md).

> Заготовка: пополняется по мере того, как правки попадают в тестовые сборки.
> Таблицу ниже заполнить при выпуске.

| | |
|---|---|
| Образ | … |
| sha256 архива | … |
| sha256 образа | … |
| Пакет обновления | … — для тех, кто уже на v1.3–v1.14 |
| Основа | GammaOS Next Core (вариант на базе Android TV), Android 14 |
| Ядро | Linux 5.10.226, [mamaich/kernel_rk3562_rg52mini](https://github.com/mamaich/kernel_rk3562_rg52mini); после v1.14 — донглы Bluetooth Realtek под чужими USB ID |
| Загрузчик | [mamaich/u-boot-rk3562-rg52mini](https://github.com/mamaich/u-boot-rk3562-rg52mini), тег `rg52mini-1.4` |
| Раздел vendor | от Android 13 (SyachOS), с вырезанным лишним и подменённым драйвером графики |

Общая карта с GammaOS Next и dArkOS обновляется тем же пакетом, см.
[RG52mini-dualboot](https://github.com/mamaich/RG52mini-dualboot/releases).

## Что нового

### Bluetooth через USB-донгл на Realtek

На платах первой ревизии (Wi-Fi RK915) своего Bluetooth нет, и остаётся донгл
по USB через переходник USB-C OTG. Донглам на Realtek нужна прошивка, а в
образе её не было, поэтому они не поднимались. Теперь прошивки для чипов
Realtek, которые знает ядро, лежат в разделе vendor: RTL8723A/B/D, RTL8821A/C,
RTL8761A/B, RTL8822B/C. В том числе RTL8761B — на нём многие донглы «Bluetooth
5.0».

Ядро узнаёт и донглы Realtek, которые продаются под чужими идентификаторами USB:
TP-Link UB500, ASUS USB-BT500, Edimax, Mercusys и другие. Если донгла нет в
списке, ядро спрашивает у самого чипа, кто его сделал, и для Realtek загружает
прошивку так же.

Донглы на CSR8510 A10 и Broadcom BCM20702 прошивки не требуют. Не заработают
RTL8761C и другие новые донглы «Bluetooth 5.3/5.4», донглы на Actions ATS2851 и на
MediaTek. Донгл лучше вставить до включения Bluetooth.

## Что стоит проверить

- **Bluetooth через USB-донгл на ревизии A** — с донглом пока не проверялось.
  Какой в донгле чип, видно по идентификатору USB: CSR — `0a12:0001`, Realtek —
  `0bda:xxxx`, TP-Link UB500 — `2357:0604`.
