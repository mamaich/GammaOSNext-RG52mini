#!/system/bin/sh
# Повторная инициализация встроенного экрана в конце загрузки - только на
# платах ревизии A.
#
# На ревизии A (Wi-Fi RK915, без контроллера Type-C HUSB311) после логотипа
# u-boot экран бывает чёрным при горящей подсветке, а система работает;
# возвращает картинку сон и пробуждение (двойное нажатие кнопки питания).
# Причина на этой ревизии не доказана: быстрое выключение-включение панели
# (его теперь закрывают паузы выключения в дереве и rg52_min_off_ms в ядре),
# неудачный перехват работающей панели у u-boot или бросок тока при
# включении RK915 около 16-й секунды загрузки, когда панель уже работает.
# Сон и пробуждение лечат любой из этих случаев, поэтому здесь делается
# ровно то, что владельцу приходилось делать вслепую: в конце загрузки экран
# гаснет на две секунды и включается снова. Разбор - doc/rg52mini/
# 02-план.md, «Чёрный экран после логотипа на ревизии A».
#
# Когда. Сначала цикл шёл через 3 с после sys.boot_completed, и на очень
# быстрых картах (100-150 МБ/с) жалоба вернулась. sys.boot_completed сам
# запускает волну наших одноразовых служб (частоты, оболочка, BIOS, zram...),
# и цикл попадал в её середину: если что-то из волны задевает экран, на
# быстрой карте оно может прийти уже после цикла. Теперь ждём, пока все эти
# службы отработают и 3 с подряд ни одна не запущена (не дольше 30 с), и
# только тогда гасим экран.
#
# Ревизию A узнаём по дереву устройства: наш u-boot, не найдя HUSB311 на
# i2c@ffa10000 по адресу 0x4e, ставит его узлу status = "disabled".
#
# persist.rg52.panel_kick: 1 - делать на любой ревизии (проверка), 0 - не
# делать никогда, пусто - только на ревизии A.

TAG=rg52-panel-kick
NODE=/sys/firmware/devicetree/base/i2c@ffa10000/husb311@4e/status
LOCK=rg52_panel_kick

# Одноразовые службы, которые init запускает по sys.boot_completed или сразу
# за ним (rg52-*.rc, rg52-trim.rc, rg52-zram.rc, rg52-perf.rc).
BOOT_SERVICES="rg52_bios rg52_bootmenu rg52_daijisho rg52_home rg52_ime
rg52_retroarch rg52_zram rg52_disable_rkpd rg52_nas_off rg52_perf_boot
rg52_perf_apply rg52_gpucap setclock_stock setclock_max setclock_powersave
setclock_3d_game setclock_overclock rg52_hdmi_unplug"
QUIET_S=3
MAX_WAIT_S=30
OFF_S=2

# Журнал и в logcat, и в журнал ядра: в dmesg видно время рядом с событиями
# драйверов (DSI, RK915).
say() {
    log -t $TAG "$*"
    echo "$TAG: $*" > /dev/kmsg 2>/dev/null
}

uptime_s() {
    cut -d' ' -f1 /proc/uptime
}

mode=$(getprop persist.rg52.panel_kick)
[ "$mode" = 0 ] && exit 0
if [ "$mode" != 1 ]; then
    [ "$(tr -d '\0' < $NODE 2>/dev/null)" = disabled ] || exit 0
fi

say "boot completed at $(uptime_s) s, waiting for the boot-time services"

# Ждём тишины: QUIET_S секунд подряд ни одна из служб не в состоянии running.
quiet=0
waited=0
last=""
while [ $waited -lt $MAX_WAIT_S ]; do
    busy=""
    for s in $BOOT_SERVICES; do
        [ "$(getprop init.svc.$s)" = running ] && busy="$busy $s"
    done
    if [ -n "$busy" ]; then
        quiet=0
        if [ "$busy" != "$last" ]; then
            say "at $(uptime_s) s still running:$busy"
            last=$busy
        fi
    else
        quiet=$((quiet + 1))
        [ $quiet -ge $QUIET_S ] && break
    fi
    sleep 1
    waited=$((waited + 1))
done
if [ $quiet -ge $QUIET_S ]; then
    say "boot-time services done, quiet for $QUIET_S s at $(uptime_s) s"
else
    say "gave up waiting after $MAX_WAIT_S s, still running:$busy"
fi

# С подключённым HDMI встроенный экран не показывается, переинициализировать
# нечего. Устройство спит - значит, его усыпили; будить без спроса нельзя.
if grep -qx "HDMI=1" /sys/class/extcon/extcon*/state 2>/dev/null; then
    say "HDMI connected, skipping"
    exit 0
fi
if ! dumpsys power | grep -q "mWakefulness=Awake"; then
    say "device is not awake, skipping"
    exit 0
fi

say "board revision A (no HUSB311): sleep/wake to re-init the panel, off for $OFF_S s"
# Wakelock ядра на время цикла, с тайм-аутом на случай гибели скрипта: без
# USB к ПК ядро могло бы уснуть по-настоящему, и пробуждение не наступило бы.
# sys.rg52.panel_kick.busy=1 не даёт rg52_audio_sleep (rg52-audio-standby.rc)
# остановить audioserver: он делает это через 2 с после гашения экрана, а
# экран здесь погашен как раз на две.
echo "$LOCK 15000000000" > /sys/power/wake_lock
setprop sys.rg52.panel_kick.busy 1
input keyevent KEYCODE_SLEEP
sleep $OFF_S
input keyevent KEYCODE_WAKEUP
setprop sys.rg52.panel_kick.busy 0
echo $LOCK > /sys/power/wake_unlock
say "done at $(uptime_s) s"
