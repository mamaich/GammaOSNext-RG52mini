#!/system/bin/sh
# Возврат HDMI после пробуждения.
#
# Видеоконтроллер у RK3562 один (см. rg52-hdmi-unplug.sh). При вставке кабеля
# двоичный HWC от Rockchip отдаёт его телевизору. А при пробуждении Android
# включает встроенный экран, и HWC отдаёт контроллер ему, отпуская HDMI (в
# журнале ReleaseConnectorAndCrtc ... HDMI-A-1): картинка уходит на встроенный
# экран, телевизор чёрный.
#
# Исходников HWC нет, поэтому здесь повторяется то, что он делает правильно, -
# подключение. Коннектор HDMI в DRM на секунду принудительно «отключается» и
# снова «подключается» (/sys/class/drm/card0-HDMI-A-1/status), HWC получает два
# события hotplug и привязывает HDMI, как при вставке кабеля. Потом принуждение
# снимается (detect), и настоящее отключение кабеля снова замечается.
#
# Звук эти секунды не теряется: драйвер моста rk628 в ядре принимает поток и
# без видеопорта, а настраивает звук, когда HDMI снова включается.
#
# Делается, только если кабель действительно вставлен (extcon моста rk628,
# HDMI=1), устройство бодрствует, а HWC держит HDMI отпущенным. Запускается
# init при пробуждении, см. rg52-hdmi-unplug.rc; постоянно не работает.
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

# HWC отдаёт видеопорт встроенному экрану в первые доли секунды после
# пробуждения, а экран включается ещё около полусекунды. Ждём, пока это
# устоится: HDMI отпущен две проверки подряд с интервалом 0,5 с, не раньше чем
# через секунду после пробуждения. Если за шесть секунд HDMI так и не
# отпущен - всё в порядке, выходим.
sleep 1
n=0
i=0
while [ $i -lt 10 ]; do
    cable_in || exit 0
    [ "$(getprop sys.screen.state)" = on ] || exit 0
    if released; then
        n=$((n + 1))
        [ $n -ge 2 ] && break
    else
        n=0
    fi
    sleep 0.5
    i=$((i + 1))
done
[ $n -ge 2 ] || exit 0
dumpsys power | grep -q "mWakefulness=Awake" || exit 0

log -t $TAG "HDMI cable is in but HWC released it, re-plugging: $(state)"
echo off > "$C"
sleep 1
echo on > "$C"
sleep 3
echo detect > "$C"
sleep 1
log -t $TAG "after re-plug: $(state)"
