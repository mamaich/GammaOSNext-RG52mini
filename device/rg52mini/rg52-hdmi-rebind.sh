#!/system/bin/sh
# Возврат HDMI после пробуждения.
#
# Видеоконтроллер у RK3562 один (см. rg52-hdmi-unplug.sh). При вставке кабеля
# двоичный HWC от Rockchip отдаёт его телевизору. А при пробуждении Android
# первым включает встроенный экран, и HWC отдаёт контроллер ему, отпуская HDMI
# (в журнале ReleaseConnectorAndCrtc ... HDMI-A-1): картинка уходит на
# встроенный экран, телевизор чёрный, а звук по-прежнему идёт в «подключённый»
# HDMI - тишина везде, пока кабель не вынуть.
#
# Исходников HWC нет, поэтому здесь повторяется то, что он делает правильно, -
# подключение. Коннектор HDMI в DRM на секунду принудительно «отключается» и
# снова «подключается» (/sys/class/drm/card0-HDMI-A-1/status), HWC получает два
# события hotplug и привязывает HDMI, как при вставке кабеля. Потом принуждение
# снимается (detect), и настоящее отключение кабеля снова замечается.
#
# Делается, только если кабель действительно вставлен (extcon моста rk628,
# HDMI=1), устройство бодрствует, а HWC держит HDMI отпущенным. Запускается при
# пробуждении и при каждой записи HWC в vendor.hwc.device.display-1, см.
# rg52-hdmi-unplug.rc; постоянно не работает.
#
# Выключается: setprop persist.rg52.hdmi_rebind 0

TAG=rg52-hdmi-rebind
C=/sys/class/drm/card0-HDMI-A-1/status

[ "$(getprop persist.rg52.hdmi_rebind)" = 0 ] && exit 0
[ -w "$C" ] || exit 0

cable_in() { grep -qx "HDMI=1" /sys/class/extcon/extcon*/state 2>/dev/null; }
released() {
    case "$(getprop vendor.hwc.device.display-1)" in
        *:release*) return 0 ;;
    esac
    return 1
}
state() {
    echo "display-0=$(getprop vendor.hwc.device.display-0) display-1=$(getprop vendor.hwc.device.display-1)" \
        "drm=$(cat $C) cable=$(cable_in && echo in || echo out)"
}

# После пробуждения HWC расставляет экраны за доли секунды - даём ему закончить.
sleep 2
cable_in || exit 0
released || exit 0
[ "$(getprop sys.screen.state)" = on ] || exit 0
dumpsys power | grep -q "mWakefulness=Awake" || exit 0

log -t $TAG "HDMI cable is in but HWC released it, re-plugging: $(state)"
echo off > "$C"
sleep 1
echo on > "$C"
sleep 3
echo detect > "$C"
sleep 1
log -t $TAG "after re-plug: $(state)"
