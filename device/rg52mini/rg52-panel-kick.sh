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
# гаснет на полторы секунды и включается снова. Разбор - doc/rg52mini/
# 02-план.md, «Чёрный экран после логотипа на ревизии A».
#
# Когда. Сначала цикл шёл через 3 с после sys.boot_completed, и на очень
# быстрых картах (100-150 МБ/с) жалоба вернулась: там конец загрузки, а с ним
# и цикл, наступают раньше. Почему ранний цикл там не помог, без журнала с
# платы A неизвестно, поэтому момент подобран, а не выведен: не раньше 3 с
# после конца загрузки и не раньше AT_S секунд от старта ядра. 36 с позже
# любого момента, в котором старый цикл заведомо работал на обычных картах
# (около 28-32 с на нынешних сборках), с запасом на карту медленнее нашей; на
# обычной карте цикл теперь на 5-8 с позже прежнего. Отложенная очистка
# регуляторов (около 34 с) ни при чём: питание панели держит её prepare (с
# первого включения DSI и после каждого сна), а очистка регуляторы с
# потребителями пропускает. Ждать окончания служб конца загрузки нельзя: часть
# их работает минуту и дольше (rg52_ime, регулятор rg52_gpucap).
#
# Время - по /proc/uptime: от старта ядра, без u-boot и меню двойной загрузки.
# Метки dmesg идут от включения питания, так что в журнале ядра к числам из
# строк этого скрипта прибавляется время до ядра (сейчас около 9 с, с меню
# двойной загрузки около 14).
#
# Цикла нет, если экран после конца загрузки уже гас: владелец сам нажал
# питание дважды, консоль усыпили или rg52-hdmi-unplug вернул экран сном и
# пробуждением - панель уже переинициализирована, лишнее мигание ни к чему.
# И не больше одного раза за загрузку ядра: при перезапуске system_server
# sys.boot_completed выставляется снова, а панель у u-boot тогда не
# перехватывается.
#
# Ревизию A узнаём по любому из двух признаков:
# - дерево устройства: наш u-boot, не найдя HUSB311 на i2c@ffa10000 по адресу
#   0x4e, ставит его узлу status = "disabled";
# - Wi-Fi: модуль rk915 есть в /proc/modules. На ревизии B его инициализация
#   проваливается и модуля в списке нет (см. wifi_pick.sh), а к моменту цикла
#   модули давно загружены. Этот признак от u-boot не зависит: с чужим
#   загрузчиком (без проверки HUSB311) дерево у ядра как на ревизии B, и по
#   одному первому признаку пинка на плате A не было вовсе (ноябрь 2026).
#
# Итог - в sys.rg52.panel_kick.result (getprop): logcat и dmesg кольцевые, и
# через несколько минут работы строк этого скрипта в них уже нет, а свойство
# живёт до перезагрузки.
#
# persist.rg52.panel_kick: 1 - делать на любой ревизии (проверка), 0 - не
# делать никогда, пусто - только на ревизии A.
# persist.rg52.panel_kick.at: секунды по /proc/uptime, раньше которых цикла
# нет (по умолчанию AT_S; 0 - прежние 3 с после конца загрузки).
#
# Проверять запуском службы, а не скрипта руками (от shell нет доступа к
# wake_lock и /dev/kmsg, а флаг busy init снимет сразу):
#   setprop sys.rg52.panel_kick.done 0; setprop persist.rg52.panel_kick.at 0
#   start rg52_panel_kick
# Цикл - через 3 с; потом setprop persist.rg52.panel_kick.at ''.
# Итог: getprop sys.rg52.panel_kick.result.

TAG=rg52-panel-kick
NODE=/sys/firmware/devicetree/base/i2c@ffa10000/husb311@4e/status
LOCK=rg52_panel_kick
AT_S=36
AFTER_BOOT_S=3
OFF_S=1.5

# Журнал и в logcat, и в журнал ядра: в dmesg видно время рядом с событиями
# драйверов (DSI, RK915).
say() {
    log -t $TAG "$*"
    echo "$TAG: $*" 2>/dev/null > /dev/kmsg
}

# Итог в свойство (значение не длиннее 91 символа).
result() {
    setprop sys.rg52.panel_kick.result "$*"
}

# Пропуск цикла: в журналы и в итог.
skip() {
    say "$1, skipping"
    result "skipped at uptime $(sec $now) s: $1"
    exit 0
}

# Сотые доли секунды из /proc/uptime (там всегда два знака после точки) и
# обратно - встроенными средствами, без запуска процессов.
uptime_cs() {
    read -r up _ < /proc/uptime
    now=${up%.*}${up#*.}
}
sec() {
    echo "$(($1 / 100)).$(($1 / 10 % 10))$(($1 % 10))"
}

mode=$(getprop persist.rg52.panel_kick)
if [ "$mode" = 0 ]; then
    result "off by persist.rg52.panel_kick=0"
    exit 0
fi
husb=$(tr -d '\0' 2>/dev/null < $NODE)
if [ "$mode" = 1 ]; then
    board="forced by persist.rg52.panel_kick=1"
elif [ "$husb" = disabled ]; then
    board="board revision A (no HUSB311)"
elif grep -q '^rk915 ' /proc/modules 2>/dev/null; then
    board="board revision A (RK915 Wi-Fi)"
else
    result "not revision A: husb311 ${husb:-missing}, no rk915 module"
    exit 0
fi

[ "$(getprop sys.rg52.panel_kick.done)" = 1 ] && exit 0
setprop sys.rg52.panel_kick.done 1

uptime_cs
boot=$now
at=$(getprop persist.rg52.panel_kick.at)
case "$at" in ''|*[!0-9]*) at=$AT_S ;; esac
target=$((at * 100))
[ $target -lt $((boot + AFTER_BOOT_S * 100)) ] && target=$((boot + AFTER_BOOT_S * 100))
say "boot completed at uptime $(sec $boot) s, kick planned at uptime $(sec $target) s"
result "waiting until uptime $(sec $target) s, $board"

sleep "$(sec $((target - boot)))"

# uptime идёт и во сне ядра, а sleep - нет: сильное опоздание значит, что
# консоль за время ожидания спала.
uptime_cs
if [ $now -gt $((target + 1000)) ]; then
    skip "the device slept while waiting"
fi

# С подключённым HDMI встроенный экран не показывается, переинициализировать
# нечего.
if grep -qx "HDMI=1" /sys/class/extcon/extcon*/state 2>/dev/null; then
    skip "HDMI connected"
fi

# Устройство спит - значит, его усыпили; будить без спроса нельзя. Экран гас
# после конца загрузки - панель уже переинициализирована. mLastSleepTime - в
# мс по uptimeMillis (CLOCK_MONOTONIC): до первого сна ядра он идёт вровень с
# /proc/uptime, а сон ядра после конца загрузки и так даёт пропуск выше. Не
# спала - там 0.
power=$(dumpsys power 2>/dev/null)
case "$power" in
    *mWakefulness=Awake*) ;;
    *) skip "device is not awake" ;;
esac
slept=0
case "$power" in
    *mLastSleepTime=[0-9]*)
        slept=${power#*mLastSleepTime=}
        slept=${slept%%[!0-9]*}
        ;;
esac
if [ $((slept / 10)) -ge $boot ]; then
    skip "screen was off at uptime $(sec $((slept / 10))) s, after boot completed"
fi

wlan=absent
[ -r /sys/class/net/wlan0/operstate ] && read -r wlan < /sys/class/net/wlan0/operstate
say "$board: sleep/wake to re-init the panel at uptime $(sec $now) s, off for $OFF_S s, wlan0 $wlan"
# Wakelock ядра на время цикла, с тайм-аутом на случай гибели скрипта: без
# USB к ПК ядро могло бы уснуть по-настоящему, и пробуждение не наступило бы.
# Полторы секунды - меньше двух, после которых rg52_audio_sleep
# (rg52-audio-standby.rc) останавливает audioserver. sys.rg52.panel_kick.busy=1
# - страховка на случай, если под нагрузкой цикл затянется; если скрипт
# погибнет посреди цикла, флаг снимет init (rg52-panel-kick.rc).
echo "$LOCK 10000000000" > /sys/power/wake_lock
setprop sys.rg52.panel_kick.busy 1
input keyevent KEYCODE_SLEEP
sleep $OFF_S
input keyevent KEYCODE_WAKEUP
setprop sys.rg52.panel_kick.busy 0
echo $LOCK > /sys/power/wake_unlock
uptime_cs
say "done at uptime $(sec $now) s"
result "done at uptime $(sec $now) s, $board"
