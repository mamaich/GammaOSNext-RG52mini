#!/system/bin/sh
# Режим 3D Games: потолок процессора следует за графикой.
#
# Процессор и графика делят один тепловой бюджет: после первого порога зоны
# soc-thermal (75 °C) регулятор power_allocator отнимает частоту у обоих. Игру,
# которая ждёт графику, это бьёт дважды: графику прижимает к 300-700 МГц, а
# процессор остаётся около 2 ГГц, хотя кадр держит не он. Прежний 3D Games
# ставил процессору постоянный потолок 1416 МГц и этим лечил одни игры за счёт
# других. Замеры dArkOS на этой же консоли, постоянный потолок 1608 МГц: God of
# War (ARMSX2, графика занята на 80-93 %) на горячей консоли +12 %, Jak and
# Daxter (упор в процессор) -11 %. У нас в процессор упираются 3DS (Azahar) и
# большая часть PS2, то есть как раз тяжёлые игры, ради которых режим выбирают.
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
# холодной консоли регулятор не трогает ничего, и режим ведёт себя как stock.
#
# «Тепловая защита держит графику» - это cur_state > 0 у охлаждающего
# устройства графики. Не max_freq против cur_freq: под троттлингом max_freq у
# devfreq показывает уже урезанное значение, и запуск на горячей консоли принял
# бы его за верх графики. Устройство берётся из привязок зоны soc-thermal
# (cdevN), там только cpu0 и графика. Первое попавшееся thermal-devfreq-* не
# годится: такое же регистрирует контроллер памяти, и какое из них получит
# меньший номер, решает порядок загрузки драйверов.
#
# Связь с rg52-perf.sh. Регулятор - отдельная служба (rg52_gpucap в
# rg52-perf.rc): фоновый процесс из setclock_3d_game не выжил бы, init убивает
# группу процессов oneshot-службы, когда та завершается. Верх потолка задаёт
# rg52-perf.sh: в 3d_game пишет его в /dev/rg52-gpucap.top, в остальных режимах
# файл удаляет. Регулятор перечитывает файл на каждом шаге: файла нет - выход
# (возвращать потолок незачем, его уже записал новый режим), другое число (режим
# применён заново, например при низком заряде) - новый верх. Потолок пишется под
# тем же замком /dev/rg52-perf.lock, что у rg52-perf.sh, и под замком файл
# сверяется ещё раз - иначе шаг, начатый до смены режима, лёг бы поверх потолка
# нового режима.
#
# HAL питания Rockchip умеет сам писать scaling_max_freq. Пока потолок опущен,
# регулятор сверяет его на каждом шаге и, если его подняли, ставит свой обратно.
# То же бывает, когда режим применяется заново с тем же верхом (azahar-nano и
# drastic-nano делают это при запуске игры): снижение, набранное на горячей
# консоли, при этом не теряется.
#
# Журнал по шагам для замеров: touch /data/local/tmp/rg52-gpucap.log - пока файл
# есть, в него пишется строка на каждый шаг. Смена потолка всегда видна в logcat
# (тег rg52-gpucap). Выключить регулятор: setprop persist.rg52.gpucap 0 (тогда
# 3d_game - это потолок из persist.rg52.perf.3d_game или stock).
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
TRIP=
read -r TRIP 2>/dev/null < "$TZ/trip_point_0_temp"
case "$TRIP" in ''|*[!0-9]*) TRIP=75000 ;; esac

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
    if [ "$T" != "$TOP" ]; then
        TOP=$T
        steps
        { [ -z "$CAP" ] || [ "$CAP" -gt "$TOP" ]; } && CAP=$TOP
    fi

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
log -t rg52-gpucap "stopped: mode is no longer 3d_game"
