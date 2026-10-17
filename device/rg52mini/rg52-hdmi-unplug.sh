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
#
# Режим nano (аргумент nano, служба rg52_hdmi_nano): запускается, когда
# DRM-оболочка nano отдала экран SurfaceFlinger - при запуске игры или при
# передаче экрана из-за подключённого HDMI. Пока экраном владела она, HWC не мог
# обработать отключение кабеля: вставили и вынули HDMI в главном меню - и HWC так
# и считает его подключённым (hwc_hotplug: Unplug ... ReleaseDpyResByNormal fail,
# state is error, skip hotplug), а получив экран, отдаёт видеопорт «телевизору»:
# встроенный экран чёрный, звук тоже уходит на HDMI. Сон и пробуждение сами по себе
# не помогают (display-0 = DSI-1:..:connected:compete, экран чёрный); помогает,
# если на это время принудительно «отключить» разъём в DRM - HWC отпускает HDMI
# (display-1 = ...:mirror-disconnected) - и потом вернуть автоопределение.
# Проверено на консоли 17.10.2026.

TAG=rg52-hdmi-unplug

[ "$(getprop persist.rg52.hdmi_rescue)" = 0 ] && exit 0

if [ "$1" = nano ]; then
    C=/sys/class/drm/card0-HDMI-A-1/status
    [ -w "$C" ] || exit 0
    # Кабель вставлен - HDMI подключён по-настоящему, копию на него ведёт nano.
    grep -qx "HDMI=1" /sys/class/extcon/extcon*/state 2>/dev/null && exit 0
    i=0
    while [ $i -lt 6 ]; do
        sleep 0.5
        case "$(getprop vendor.hwc.device.display-0)" in
            *:connected) exit 0 ;;
        esac
        i=$((i + 1))
    done
    dumpsys power | grep -q "mWakefulness=Awake" || exit 0
    log -t $TAG "nano handed over the display with a stale HDMI ($(getprop vendor.hwc.device.display-0), $(getprop vendor.hwc.device.display-1)), forcing HDMI off over sleep/wake"
    echo "rg52_hdmi_unplug 15000000000" > /sys/power/wake_lock
    echo off > "$C"
    input keyevent KEYCODE_SLEEP
    sleep 1.5
    input keyevent KEYCODE_WAKEUP
    sleep 3
    echo detect > "$C"
    echo rg52_hdmi_unplug > /sys/power/wake_unlock
    log -t $TAG "after: $(getprop vendor.hwc.device.display-0), $(getprop vendor.hwc.device.display-1)"
    exit 0
fi

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
