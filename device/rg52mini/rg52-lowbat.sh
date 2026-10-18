#!/system/bin/sh
# Защита от перезапуска консоли на почти пустой батарее.
#
# Что происходит. При напряжении батареи около 3,66 В (по таблице OCV из дерева
# это примерно 25 % настоящего заряда) консоль перезапускается, если усилитель
# динамика включается в момент, когда все четыре ядра процессора работают на
# 2016 МГц. Внутреннее сопротивление почти разряженной батареи велико, бросок
# тока усилителя вместе с током процессора роняет vcc_sys, и PMIC делает рестарт:
# RK817 пишет source: on=0x10, off=0x08, как при обычной перезагрузке, а журнал в
# pstore обрывается без паники и с испорченными битами - память на миг теряла
# питание. Проверено 18.10.2026 на ревизии B (журнал опытов -
# doc/rg52mini/02-план.md):
#
#   4 ядра на 2016 или 1800 МГц + включение динамика    перезапуск
#   4 ядра на 1608 МГц + включение динамика             нет
#   одно включение динамика, процессор почти простаивает нет
#
# Чаще всего это видно при отключении кабеля: Android в ту же секунду рассылает
# события смены питания (все ядра на верхней частоте) и открывает поток на
# динамик под звук зарядки. Жалоба с ревизии A (перезагрузка при отключении USB на
# 20-25 %) - тот же случай. dArkOS при отключении кабеля звук не играет и
# процессор так не нагружает - там сбоя нет.
#
# Что здесь делается.
#
# 1. Звук зарядки выключается один раз (persist.rg52.chgsound_off). На чистой
#    установке он и так выключен по умолчанию (оверлей SettingsProvider,
#    def_charging_sounds_enabled), здесь - для обновления по воздуху. Самого звука в
#    образе нет (ChargingStarted.ogg отсутствует), выключение убирает только
#    открытие потока на динамик. Включивший его обратно в настройках получит
#    своё: отметка не даёт выключать повторно.
#
# 2. Потолок процессора при низком напряжении. Пока консоль работает от батареи,
#    раз в 20 с оценивается напряжение без нагрузки (OCV ~ voltage_now + ток
#    разряда * сопротивление цепи). Ниже порога ставится sys.rg52.lowbat=1, и
#    rg52-perf.sh ограничивает процессор частотой persist.rg52.lowbat.cpu_khz в
#    любом режиме; обратно - выше порога + 50 мВ два замера подряд или при
#    внешнем питании. Таймер sleep консоль из сна не будит: в сне цикл стоит.
#    Графику не трогаем: запуск игры с графикой на 900 МГц сброса не дал.
#
# Настройки (действуют без перезапуска, со следующего замера):
#
#     persist.rg52.lowbat.mv        порог OCV, мВ (по умолчанию 3750); 0 - выключить
#     persist.rg52.lowbat.cpu_khz   потолок процессора (1416000)
#     persist.rg52.lowbat.res_mohm  сопротивление батареи и цепи, мОм (150)

set -u

B=/sys/class/power_supply/battery

# Как в rg52-perf.sh: внешнее питание - любой не батарейный источник с online=1.
on_external_power() {
    local d t
    for d in /sys/class/power_supply/*; do
        [ -d "$d" ] || continue
        t=$(cat "$d/type" 2>/dev/null)
        [ "$t" = Battery ] && continue
        [ "$(cat "$d/online" 2>/dev/null)" = 1 ] && return 0
    done
    return 1
}

num() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }

if [ "$(getprop persist.rg52.chgsound_off)" != 1 ]; then
    if settings put secure charging_sounds_enabled 0; then
        setprop persist.rg52.chgsound_off 1
        log -t rg52-lowbat "charging sounds disabled"
    fi
fi

state=$(getprop sys.rg52.lowbat)
[ "$state" = 1 ] || state=0
high=0
while :; do
    mv=$(num "$(getprop persist.rg52.lowbat.mv)" 3750)
    res=$(num "$(getprop persist.rg52.lowbat.res_mohm)" 150)
    want=$state
    if [ "$mv" -eq 0 ] || on_external_power; then
        want=0
        ocv=-
    else
        v=$(cat $B/voltage_now 2>/dev/null)
        i=$(cat $B/current_now 2>/dev/null)
        v=$(num "${v#-}" 0)
        case "$i" in -*) i=$(num "${i#-}" 0) ;; *) i=0 ;; esac
        # мкВ + мкА * мОм / 1000 = мкВ; итог в мВ
        ocv=$(( (v + i * res / 1000) / 1000 ))
        if [ "$v" -eq 0 ]; then
            :
        elif [ "$ocv" -lt "$mv" ]; then
            want=1
            high=0
        elif [ "$ocv" -ge $((mv + 50)) ]; then
            high=$((high + 1))
            [ "$high" -ge 2 ] && want=0
        else
            high=0
        fi
    fi
    if [ "$want" != "$state" ]; then
        state=$want
        setprop sys.rg52.lowbat "$state"
        log -t rg52-lowbat "lowbat $state (ocv ~${ocv} mV, threshold ${mv} mV)"
        # Применение напрямую, а не через триггер init: oneshot-служба, уже
        # запущенная по другому поводу, повторный start пропустила бы.
        /system/bin/rg52-perf.sh
    fi
    sleep 20
done
