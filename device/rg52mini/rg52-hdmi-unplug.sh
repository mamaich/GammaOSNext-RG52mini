#!/system/bin/sh
# Возврат встроенного экрана после отключения HDMI.
#
# Видеоконтроллер у RK3562 один, и при HDMI двоичный HWC от Rockchip
# (hwcomposer.rk30board.so) отдаёт его телевизору, а встроенный экран
# отпускает. При отключении кабеля он должен привязать экран обратно, но
# иногда этого не делает: в журнале "display 0 crtc is NULL", свойство
# vendor.hwc.device.display-0 остаётся DSI-1:..:release, экран чёрный.
# Исходников HWC нет. Руками это лечится двойным нажатием кнопки питания -
# сон и пробуждение заставляют HWC заново привязать экран. Здесь то же самое,
# но само.
#
# Запускается по каждой записи в vendor.hwc.device.display-1, см.
# rg52-hdmi-unplug.rc, и сразу выходит, если HDMI не отключён. Постоянно не
# работает и батарею не тратит.
#
# Выключается: setprop persist.rg52.hdmi_rescue 0

TAG=rg52-hdmi-unplug

[ "$(getprop persist.rg52.hdmi_rescue)" = 0 ] && exit 0

case "$(getprop vendor.hwc.device.display-1)" in
    *:disconnected) ;;
    *) exit 0 ;;
esac

# Нормально HWC привязывает экран за доли секунды. Ждём с запасом.
i=0
while [ $i -lt 6 ]; do
    sleep 0.5
    case "$(getprop vendor.hwc.device.display-0)" in
        *:connected*) exit 0 ;;
    esac
    # Кабель успели вставить обратно - экран и не должен был вернуться.
    case "$(getprop vendor.hwc.device.display-1)" in
        *:disconnected) ;;
        *) exit 0 ;;
    esac
    i=$((i + 1))
done

# Если устройство спит, экран и не обязан быть привязан, а будить его без
# спроса нельзя.
dumpsys power | grep -q "mWakefulness=Awake" || exit 0

log -t $TAG "internal display not rebound after HDMI unplug ($(getprop vendor.hwc.device.display-0)), sleep/wake"
# Между «сном» и «пробуждением» ядро может успеть уснуть по-настоящему (без USB
# к ПК его ничто не держит), и тогда пробуждение не наступит до кнопки питания.
# Держим wakelock, с тайм-аутом на случай гибели скрипта.
echo "rg52_hdmi_unplug 10000000000" > /sys/power/wake_lock
input keyevent KEYCODE_SLEEP
sleep 1
input keyevent KEYCODE_WAKEUP
echo rg52_hdmi_unplug > /sys/power/wake_unlock

sleep 2
log -t $TAG "after sleep/wake: $(getprop vendor.hwc.device.display-0)"
