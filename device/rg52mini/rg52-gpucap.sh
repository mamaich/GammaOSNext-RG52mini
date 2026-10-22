#!/system/bin/sh
# Потолок процессора следует за графикой, когда чип перегрет (режимы stock, max и
# overclock; выключается галкой в GammaOS Toolbox, persist.rg52.gpucap=0).
#
# Процессор и графика делят один тепловой бюджет: после первого порога зоны
# soc-thermal (75 °C, в overclock 83) регулятор power_allocator отнимает частоту
# у обоих. Игру, которая ждёт графику, это бьёт дважды: графику прижимает к
# 300-700 МГц, а процессор остаётся около 2 ГГц, хотя кадр держит не он.
#
# Прежний режим 3D Games ставил процессору постоянный потолок 1416 МГц и этим
# лечил одни игры за счёт других. Замеры dArkOS на этой же консоли, постоянный
# потолок 1608 МГц: God of War (ARMSX2, графика занята на 80-93 %) на горячей
# консоли +12 %, Jak and Daxter (упор в процессор) -11 %. У нас в процессор
# упираются 3DS (Azahar) и большая часть PS2, то есть как раз тяжёлые игры.
#
# Наш замер с регулятором (22.10.2026, Minecraft, неподвижная сцена, 78-83 °C,
# четыре пары окон по 3 мин, регулятор включён и выключен попеременно):
#   - max: 32,6 к/с против 29,8 (+9 %, выигрыш во всех четырёх парах), графика
#     в среднем 835 МГц против 472;
#   - stock: 33,8 против 33,6 - разницы нет. Здесь Minecraft упирается в главный
#     поток процессора; графика ускорилась (807 МГц против 595), но стала
#     простаивать, и кадров не прибавилось. Потеря - в пределах разброса.
# В max процессор стоит на верхней частоте и сжигает бюджет сам, регулятор
# возвращает его графике; в stock schedutil и так не держит процессор наверху.
#
# Поэтому потолок двигается по факту, раз в 2 с (логика и пороги взяты из
# gpu-cpucap dArkOS, там они проверены замерами):
#   - ступень вниз, пока графика занята на 80 % и больше и тепловая защита её
#     держит;
#   - ступень вверх, пока графика занята меньше чем на 60 % или SoC на 5 °C
#     холоднее первого порога.
# Опущенный слишком низко процессор не успевает кормить графику, её загрузка
# падает, и спуск останавливается сам, так что глубина подбирается по
# устройству, игре и комнате. Пол 1200 МГц (persist.rg52.gpucap.floor_khz). На
# холодной консоли регулятор не трогает ничего.
#
# «Тепловая защита держит графику» - это cur_state > 0 у охлаждающего
# устройства графики. Не max_freq против cur_freq: под троттлингом max_freq у
# devfreq показывает уже урезанное значение, и запуск на горячей консоли принял
# бы его за верх графики. Устройство берётся из привязок зоны soc-thermal
# (cdevN), там только cpu0 и графика. Первое попавшееся thermal-devfreq-* -
# не гарантия: такое же умеет регистрировать и драйвер контроллера памяти
# (rockchip_dmc.c, #cooling-cells у dmc в rk3562.dtsi), и тогда меньший номер
# достанется тому, кто раньше загрузился. На нашем ядре его у памяти нет
# (проверено 22.10: cooling_device0 - графика, 1 - процессор), но выбор через
# зону от порядка не зависит.
#
# Связь с rg52-perf.sh. Регулятор - отдельная служба (rg52_gpucap в
# rg52-perf.rc): фоновый процесс из setclock_<режим> не выжил бы, init убивает
# группу процессов oneshot-службы, когда та завершается. Верх потолка задаёт
# rg52-perf.sh числом из строки режима: в stock, max и overclock пишет его в
# /dev/rg52-gpucap.top, в powersave и при выключенной галке файл удаляет. Из
# scaling_max_freq верх брать нельзя: на этом ядре он показывает итог всех
# ограничений, включая тепловую защиту процессора, и на горячей консоли дал бы
# урезанную частоту. Регулятор перечитывает файл на каждом шаге: файла нет -
# выход (возвращать потолок незачем, его уже записал новый режим), другое число
# (смена режима, низкий заряд) - новый верх. Потолок пишется под
# тем же замком /dev/rg52-perf.lock, что у rg52-perf.sh, и под замком файл
# сверяется ещё раз - иначе шаг, начатый до смены режима, лёг бы поверх потолка
# нового режима.
#
# HAL питания Rockchip умеет сам писать scaling_max_freq. Пока потолок опущен,
# регулятор сверяет его на каждом шаге и, если его подняли, ставит свой обратно.
# То же бывает, когда режим применяется заново с тем же верхом (azahar-nano и
# drastic-nano делают это при запуске игры): снижение, набранное на горячей
# консоли, при этом не теряется. Сверка только в одну сторону: ниже нашего
# scaling_max_freq бывает и от тепловой защиты, а выше - только если его
# переписали.
#
# Журнал по шагам для замеров: touch /data/local/tmp/rg52-gpucap.log - пока файл
# есть, в него пишется строка на каждый шаг. Смена потолка всегда видна в logcat
# (тег rg52-gpucap).
#
# Чтения - встроенным read, без запуска процессов: на шаг приходится только
# sleep, а mkdir/rmdir замка и log - лишь когда потолок меняется.

set -u

CPU=/sys/devices/system/cpu/cpufreq/policy0
TOPF=/dev/rg52-gpucap.top
LOCK=/dev/rg52-perf.lock
TRACE=/data/local/tmp/rg52-gpucap.log

GPU=
for d in /sys/class/devfreq/*gpu*; do
    [ -d "$d" ] && GPU=$d && break
done
TZ=
for z in /sys/class/thermal/thermal_zone*; do
    [ "$(cat "$z/type" 2>/dev/null)" = soc-thermal ] && TZ=$z && break
done
COOL=
if [ -n "$TZ" ]; then
    for c in "$TZ"/cdev*; do
        [ -d "$c" ] || continue
        case "$(cat "$c/type" 2>/dev/null)" in thermal-devfreq*) COOL=$c; break ;; esac
    done
fi
if [ -z "$GPU" ] || [ -z "$COOL" ]; then
    log -t rg52-gpucap "no gpu devfreq or gpu cooling device in soc-thermal (gpu '$GPU', zone '$TZ'), not running"
    exit 0
fi

FLOOR=$(getprop persist.rg52.gpucap.floor_khz 1200000)
case "$FLOOR" in ''|*[!0-9]*) FLOOR=1200000 ;; esac
# Первый порог зоны. Перечитывается на каждом шаге: при переходе в overclock и
# обратно rg52-perf.sh меняет его (75 <-> 83 °C), а регулятор при этом не
# перезапускается.
read_trip() {
    TRIP=
    read -r TRIP 2>/dev/null < "$TZ/trip_point_0_temp"
    case "$TRIP" in ''|*[!0-9]*) TRIP=75000 ;; esac
}
read_trip

# Ступени процессора от пола до верха; верх входит, даже если его нет в списке
# (потолок при низком заряде задаётся числом).
steps() {
    local av
    av=
    read -r av 2>/dev/null < "$CPU/scaling_available_frequencies"
    STEPS=
    for f in $av; do
        [ "$f" -ge "$FLOOR" ] && [ "$f" -lt "$TOP" ] && STEPS="$STEPS $f"
    done
    STEPS="$STEPS $TOP"
}
# Соседняя ступень ниже и выше CAP; порядок в списке не важен.
step_down() {
    NEXT=
    for f in $STEPS; do
        [ "$f" -lt "$CAP" ] && { [ -z "$NEXT" ] || [ "$f" -gt "$NEXT" ]; } && NEXT=$f
    done
}
step_up() {
    NEXT=
    for f in $STEPS; do
        [ "$f" -gt "$CAP" ] && { [ -z "$NEXT" ] || [ "$f" -lt "$NEXT" ]; } && NEXT=$f
    done
}
# Запись потолка под замком rg52-perf.sh. Замок занят - шаг пропускается, через
# 2 с будет следующий.
set_cap() {
    local t
    mkdir "$LOCK" 2>/dev/null || return 1
    t=
    read -r t 2>/dev/null < "$TOPF"
    if [ "$t" = "$TOP" ]; then
        echo "$1" > "$CPU/scaling_max_freq"
        rmdir "$LOCK"
        return 0
    fi
    rmdir "$LOCK"
    return 1
}

log -t rg52-gpucap "started: gpu $GPU, cooling $COOL ($(cat "$COOL/type" 2>/dev/null)), floor $((FLOOR / 1000)) MHz, trip $((TRIP / 1000)) C"

TOP=
CAP=
while :; do
    # sleep первым: rg52-perf.sh, запустивший службу, к этому времени закончит
    # запись режима
    sleep 2
    T=
    read -r T 2>/dev/null < "$TOPF"
    case "$T" in ''|*[!0-9]*) break ;; esac
    # Новый верх (смена режима, низкий заряд) rg52-perf.sh только что записал сам,
    # спуск начинается заново от него. Иначе после max -> overclock потолок 2016
    # остался бы «своим» и возвращался бы поверх 2208.
    if [ "$T" != "$TOP" ]; then
        TOP=$T
        steps
        CAP=$TOP
    fi
    read_trip

    L=; GF=; H=; TEMP=; M=; CUR=
    read -r L 2>/dev/null < "$GPU/load"
    read -r GF 2>/dev/null < "$GPU/cur_freq"
    read -r H 2>/dev/null < "$COOL/cur_state"
    read -r TEMP 2>/dev/null < "$TZ/temp"
    read -r M 2>/dev/null < "$CPU/scaling_max_freq"
    read -r CUR 2>/dev/null < "$CPU/scaling_cur_freq"
    L=${L%%@*}; L=${L:-0}; GF=${GF:-0}; H=${H:-0}; TEMP=${TEMP:-0}; M=${M:-0}; CUR=${CUR:-0}

    NEXT=
    if [ "$L" -ge 80 ] && [ "$H" -gt 0 ]; then
        step_down
    elif [ "$L" -lt 60 ] || [ "$TEMP" -lt $((TRIP - 5000)) ]; then
        step_up
    fi
    if [ -n "$NEXT" ]; then
        if set_cap "$NEXT"; then
            CAP=$NEXT
            log -t rg52-gpucap "cpu cap $((CAP / 1000)) MHz: gpu ${L}% at $((GF / 1000000)) MHz, gpu cooling state $H, soc $((TEMP / 1000)) C"
        fi
    elif [ "$CAP" -lt "$TOP" ] && [ "$M" -gt "$CAP" ]; then
        set_cap "$CAP" && log -t rg52-gpucap "cpu cap $((CAP / 1000)) MHz put back (was raised to $((M / 1000)))"
    fi

    if [ -f "$TRACE" ]; then
        read -r UP REST < /proc/uptime
        echo "${UP%%.*} gpu=$((GF / 1000000))MHz/${L}% held=$H temp=$((TEMP / 1000)) cap=$((CAP / 1000)) cpu=$((CUR / 1000))" >> "$TRACE"
    fi
done
log -t rg52-gpucap "stopped: turned off for this mode"
