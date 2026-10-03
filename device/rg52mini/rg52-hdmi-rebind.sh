#!/system/bin/sh
# Возврат HDMI после пробуждения.
#
# Видеоконтроллер у RK3562 один (см. rg52-hdmi-unplug.sh). При вставке кабеля
# двоичный HWC от Rockchip отдаёт его телевизору. А при пробуждении Android
# включает встроенный экран, и HWC путается двумя способами:
#
# * отдаёт видеопорт встроенному экрану, отпуская HDMI (в журнале
#   ReleaseConnectorAndCrtc ... HDMI-A-1, display-1 = ...:release): картинка
#   на встроенном экране, телевизор чёрный. Так бывает, если HDMI вставили
#   после загрузки;
# * если HDMI был вставлен при загрузке, HWC ведёт оба экрана «зеркалом» и при
#   пробуждении сначала назначает плоскости встроенному экрану, а потом
#   перекидывает видеопорт на HDMI («compete»). Плоскости остаются за
#   встроенным экраном (can't get plane_groups size=0, presentOrValidate failed
#   for display 1), и HDMI на видеопорту, но выводить ему нечем - телевизор
#   чёрный. В /sys/kernel/debug/dri/0/summary это видно: у Video Port0
#   коннектор HDMI-A-1, но ни одного окна *-win*: ACTIVE.
#
# Исходников HWC нет, поэтому здесь повторяется то, что он делает правильно, -
# подключение. Коннектор HDMI в DRM на секунду принудительно «отключается» и
# снова «подключается» (/sys/class/drm/card0-HDMI-A-1/status), HWC получает два
# события hotplug и привязывает HDMI заново, с плоскостями, как при вставке
# кабеля. Потом принуждение снимается (detect), и настоящее отключение кабеля
# снова замечается.
#
# Звук эти секунды не теряется: драйвер моста rk628 в ядре принимает поток и
# без видеопорта, а настраивает звук, когда HDMI снова включается.
#
# Делается, только если кабель действительно вставлен (extcon моста rk628,
# HDMI=1), устройство бодрствует, а HDMI отпущен или на видеопорту без плоскостей.
# Запускается init при пробуждении, см. rg52-hdmi-unplug.rc; постоянно не
# работает.
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
# HDMI на видеопорту, но HWC не вывел на него ни одной плоскости.
dark() {
    sed -n '/^Video Port0/,/^Video Port1/p' /sys/kernel/debug/dri/0/summary 2>/dev/null | awk '
        /Connector:HDMI-A-1/ { h = 1 }
        /-win[0-9]+: ACTIVE/ { w = 1 }
        END { exit !(h && !w) }'
}
state() {
    echo "display-0=$(getprop vendor.hwc.device.display-0) display-1=$(getprop vendor.hwc.device.display-1)" \
        "drm=$(cat $C) cable=$(cable_in && echo in || echo out)"
}

# HWC расставляет экраны в первые доли секунды после пробуждения, а встроенный
# экран включается ещё около полусекунды. Ждём, пока это устоится: беда видна
# две проверки подряд с интервалом 0,5 с, не раньше чем через секунду после
# пробуждения. Если за шесть секунд всё в порядке - выходим (код 1). Кабель
# вынут или экран погас - выходим из скрипта совсем.
find_trouble() {
    n=0
    i=0
    while [ $i -lt 10 ]; do
        cable_in || exit 0
        [ "$(getprop sys.screen.state)" = on ] || exit 0
        if released; then
            why="HWC released it"
        elif dark; then
            why="HDMI has the video port but no planes"
        else
            why=
        fi
        if [ -n "$why" ]; then
            n=$((n + 1))
            [ $n -ge 2 ] && return 0
        else
            n=0
        fi
        sleep 0.5
        i=$((i + 1))
    done
    return 1
}

# Переподключение длится около 6 с. На это время держим wakelock ядра (с
# тайм-аутом на случай гибели скрипта): если ядро уснёт посреди пауз, коннектор
# останется принудительно отключённым до следующего пробуждения. Кабель могут
# выдернуть и в эти секунды - тогда принуждение снимается сразу (extcon моста
# обновляется по прерыванию HPD и при принуждении).
LOCK=rg52_hdmi_rebind
replug() {
    echo "$LOCK 15000000000" > /sys/power/wake_lock
    echo off > "$C"
    sleep 1
    if cable_in; then
        echo on > "$C"
        i=0
        while [ $i -lt 6 ] && cable_in; do
            sleep 0.5
            i=$((i + 1))
        done
    fi
    echo detect > "$C"
    sleep 1
    echo $LOCK > /sys/power/wake_unlock
}

# После переподключения проверяем ещё раз: если устройство успело уснуть и
# проснуться, пока скрипт работал, init второй экземпляр не запустит (oneshot),
# и новое пробуждение разбирает этот же. Не больше трёх переподключений подряд.
pass=0
while [ $pass -lt 3 ]; do
    sleep 1
    why=
    find_trouble || exit 0
    dumpsys power | grep -q "mWakefulness=Awake" || exit 0
    log -t $TAG "HDMI cable is in but $why, re-plugging: $(state)"
    replug
    log -t $TAG "after re-plug: $(state)"
    pass=$((pass + 1))
done
