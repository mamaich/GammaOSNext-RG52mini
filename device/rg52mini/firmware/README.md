# Прошивки USB-донглов Bluetooth Realtek

На плате ревизии A своего Bluetooth нет, и остаётся донгл по USB. Донгл на
Realtek ядро (`btusb` + `btrtl`) поднимает только с прошивкой: без файла
настройка `hci0` обрывается на `RTL: firmware file ... not found`.

Ищет прошивки ядро только по `firmware_class.path=/vendor/lib/firmware` (строка
`APPEND` в `tools/mk-sdimg.sh`). Такой папки в vendor от Android 13 нет, а
запасного пути через ueventd у ядра нет (`CONFIG_FW_LOADER_USER_HELPER`
выключен). Поэтому `mk-sdimg.sh` кладёт `rtl_bt/` отсюда в
`/vendor/lib/firmware/rtl_bt/`. Обновление по воздуху пишет раздел vendor
целиком, так что файлы приезжают и с ним.

## Что лежит

Ровно то, что для USB-чипов просит `drivers/bluetooth/btrtl.c` ядра 5.10:

| чип | файлы |
|---|---|
| RTL8723A | `rtl8723a_fw.bin` |
| RTL8723B | `rtl8723b_fw.bin` |
| RTL8723D(U) | `rtl8723d_fw.bin`, `rtl8723d_config.bin` |
| RTL8821A | `rtl8821a_fw.bin`, `rtl8821a_config.bin` |
| RTL8821C | `rtl8821c_fw.bin`, `rtl8821c_config.bin` |
| RTL8761A | `rtl8761a_fw.bin` |
| RTL8761B(U) | `rtl8761b_fw.bin`, `rtl8761b_config.bin` |
| RTL8822B | `rtl8822b_fw.bin`, `rtl8822b_config.bin` |
| RTL8822C(U) | `rtl8822cu_fw.bin`, `rtl8822cu_config.bin` |

Взяты из `lib/firmware/rtl_bt` дерева ядра `kernel_rk3562_rg52mini` (там они
из linux-firmware).

**RTL8761B лежит под чужим именем.** Ядро 5.10 просит для 8761B один и тот же
файл и на UART, и на USB — `rtl8761b_fw.bin`. В linux-firmware под этим именем
вариант для UART, а для USB — `rtl8761bu_fw.bin`, который так и просят ядра
посвежее. UART-исполнения 8761B на этой консоли нет, поэтому здесь
`rtl8761b_fw.bin` — это `rtl8761bu_fw.bin`, а `rtl8761b_config.bin` —
`rtl8761bu_config.bin`, без изменений внутри.

Не вошли UART-варианты (`*s_fw.bin`) и чипы, которых ядро 5.10 не знает
(8852A/B/C, 8851B, 8761C).

## Чего ещё не хватает

* **Донглы под чужими USB ID** (TP-Link UB500 `2357:0604`, ASUS USB-BT500 и
  т. п.) ядро 5.10 само не знало. С ядром `kernel_rk3562_rg52mini` после v1.14
  `btusb` узнаёт их по таблице из mainline, а неизвестное устройство общего
  класса USB спрашивает о производителе и, если это Realtek, настраивает как
  Realtek (`btusb_setup_generic()`). Донглы с идентификатором производителя
  Realtek (`0bda:xxxx`) ядро узнавало и раньше.
* С донглом пока не проверялось.

## Проверка без перепрошивки

Путь поиска ядро разрешает поменять на ходу:

    adb push rtl_bt /data/local/tmp/fw/rtl_bt
    adb shell "echo -n /data/local/tmp/fw > /sys/module/firmware_class/parameters/path"

После этого вставить донгл и смотреть `dmesg | grep -i -E 'rtl|hci'`: должны
быть `RTL: loading rtl_bt/...` и версия прошивки. На ревизии B донгл станет
`hci1` (`hci0` — AIC8800), так что проверяется только ядро: прослойка
`libbt-vendor` берёт `hci0`.

## Лицензия

`rtl_bt/LICENCE.rtlwifi_firmware.txt` — из linux-firmware (`LICENSES/`), по
WHENCE «Redistributable»: распространять можно без изменений, вместе с этим
уведомлением.
