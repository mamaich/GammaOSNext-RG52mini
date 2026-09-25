#!/system/bin/sh
# Режимы производительности: частоты процессора и графики.
#
# Зачем этот файл. В GammaOS режим производительности — это одно свойство,
# persist.gammaos.performance_mode, а применяют его скрипты
# /vendor/bin/setclock_<режим>.sh, которые приходят с vendor каждого
# устройства. В нашем vendor (он от SyachOS) их нет: ни setclock_*.sh, ни
# init.gammaos_power.rc. Из-за этого все три режима в меню не делали ничего —
# свойство послушно менялось, а регуляторы оставались на своих значениях.
# Проверено на устройстве: переключение stock/max/powersave не меняло ни
# scaling_governor, ни границы частот, ни регулятор графики.
#
# Здесь то же самое сделано со стороны system, чтобы vendor не трогать.
#
# Откуда взяты значения. Из perf_apply.sh самой SyachOS — это набор, который
# на этом железе уже отработан. Отличие одно: их «balanced» держит нижнюю
# границу процессора на 1416 МГц, а у нас режим stock оставляет заводские
# 408 МГц. Причина в названии: stock в меню показывается как «Normal», и
# выбравший его вправе ожидать поведение по умолчанию, а не тихо поднятый
# пол частоты с расходом батареи. Кому ближе вариант SyachOS — это одно
# свойство, менять пересборкой не нужно:
#
#     setprop persist.rg52.perf.stock schedutil:1416000:2016000:simple_ondemand
#
# Формат свойства persist.rg52.perf.<режим>:
#
#     <рег. cpu>:<мин. cpu>:<макс. cpu>:<рег. gpu>:<мин. память>:<макс. память>
#
# Два последних поля необязательны, пустое значит «не ограничивать». Заданное
# ими не прописывается в память числом: список частот у неё не фиксирован, он
# приходит от ATF и зависит от загрузчика. На штатном устройстве это
# 324/528/780/798 МГц, на устройстве с поднятой частотой - 324/528/780/928.
# Поэтому из available_frequencies выбирается ближайшая подходящая: для потолка
# наибольшая не выше заданной, для пола наименьшая не ниже.
#
# Про память по умолчанию. Ограничивается только powersave сверху (528 МГц) и
# max снизу (780 МГц) - обе частоты есть в любом списке, и с разгоном, и без,
# так что поведение одинаково на всех устройствах.
#
# В stock и 3d_game память намеренно свободна. Для 3d_game это принципиально:
# режим придерживает процессор, чтобы отдать тепловой бюджет графике, а графика
# работает на общей с процессором памяти - срезав ей полосу, мы уронили бы ровно
# те кадры, ради которых всё и затевалось.
#
# Выигрыш от потолка в powersave скромнее, чем кажется: регулятор dmc_ondemand и
# так держит память на нижней ступени почти всё время, а потолок ограничивает
# пики, а не постоянное потребление.
#
# Про режим 3d_game. Он снижает потолок процессора, а графику оставляет
# свободной. Смысл в тепловом бюджете: четыре ядра съедают его заметно
# больше, чем одно графическое, и при перегреве выгоднее придержать их, чем
# позволить троттлингу резать кадры в игре.

set -u

# Внешнее питание — любой источник, который не батарея и у которого online=1.
# Имена узлов привязывать нельзя: на этом устройстве их четыре (ac типа Mains,
# battery, usb и tcpm-source-psy-2-004e типа USB), а на другом SoC набор другой.
# Кабель к компьютеру тоже считается внешним питанием, и это осознанно: с точки
# зрения теплового и энергетического бюджета разницы с зарядкой нет.
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

MODE=${1:-}

# Особый аргумент boot: его передаёт только служба rg52_perf_boot. Режим
# выбирается по тому, от чего устройство включилось — со вставленной зарядкой
# есть смысл в max, от батареи разумнее stock. Выбранное записывается в
# persist.gammaos.performance_mode, иначе меню выключателя показывало бы
# сохранённый с прошлого раза режим, а не действующий.
#
# Решение принимается на каждой загрузке и перебивает сохранённое. Кому это
# мешает — в обоих приложениях настроек есть галка «Remember performance mode
# across reboots» (GammaOS Toolbox и настройки оболочки nano), она же
# свойство:
#
#     setprop persist.rg52.perf.remember_mode 1
#
# Тогда на загрузке, как раньше, применяется сохранённый режим. По умолчанию
# галка снята, то есть режим выбирается по питанию.
if [ "$MODE" = boot ]; then
    MODE=""
    if [ "$(getprop persist.rg52.perf.remember_mode 0)" != 1 ]; then
        if on_external_power; then
            MODE=max
            log -t rg52-perf "загрузка от внешнего питания: режим max"
        else
            MODE=stock
            log -t rg52-perf "загрузка от батареи: режим stock"
        fi
        # Только при изменении: на любую запись init поднимает setclock_<режим>,
        # то есть ещё один проход применения. На второй и дальнейших загрузках
        # значение обычно уже верное, и лишний проход ни к чему.
        if [ "$(getprop persist.gammaos.performance_mode)" != "$MODE" ]; then
            setprop persist.gammaos.performance_mode "$MODE"
        fi
    fi
fi

[ -z "$MODE" ] && MODE=$(getprop persist.gammaos.performance_mode)
[ -z "$MODE" ] && MODE=stock

# Замок на применение. При загрузке оно запускается несколько раз подряд: init
# срабатывает по триггеру на восстановленное persist-свойство, плюс служба
# rg52_perf_boot, плюс запуск из оболочки или меню. Порядок внутри скрипта -
# сперва отпустить границы на всю ширину, потом поставить новые, поэтому два
# наложившихся экземпляра успевают оставить заведомо неверное состояние: на
# устройстве в журнале поймано "cpu performance 2016000-2016000", то есть пол,
# поднятый до потолка, и "ddr 928000000-928000000". Финальное состояние
# выправлялось следующим проходом, но полагаться на это нельзя.
#
# mkdir - атомарная операция, годится как примитив блокировки; /dev это tmpfs и
# существует всегда, в отличие от /data на раннем этапе. Если замок остался от
# убитого экземпляра, через пять секунд применяем без него: лучше рискнуть
# наложением, чем не применить режим вовсе.
LOCK=/dev/rg52-perf.lock
i=0
while ! mkdir "$LOCK" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 50 ]; then
        log -t rg52-perf "замок $LOCK занят 5 с, применяю без него"
        LOCK=
        break
    fi
    sleep 0.1
done
[ -n "$LOCK" ] && trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

CPU=/sys/devices/system/cpu/cpufreq/policy0
# Имя узла графики зависит от SoC: на RK3562 это ff320000.gpu. Ищем, а не
# прописываем, чтобы скрипт пережил смену платы. dmc — контроллер памяти,
# он сюда не годится.
GPU=
for d in /sys/class/devfreq/*gpu*; do
    [ -d "$d" ] && GPU=$d && break
done

# Контроллер памяти. У него свой регулятор (dmc_ondemand) и свои границы,
# независимые от процессора и графики.
DMC=
for d in /sys/class/devfreq/*dmc*; do
    [ -d "$d" ] && DMC=$d && break
done

case "$MODE" in
    powersave) DEF=schedutil:408000:1416000:powersave::528000000 ;;
    max)       DEF=performance:1416000:2016000:performance:780000000: ;;
    3d_game)   DEF=schedutil:408000:1416000:simple_ondemand ;;
    stock|*)   MODE=stock; DEF=schedutil:408000:2016000:simple_ondemand ;;
esac

SPEC=$(getprop "persist.rg52.perf.$MODE")
[ -z "$SPEC" ] && SPEC=$DEF

OLDIFS=$IFS; IFS=:; set -- $SPEC; IFS=$OLDIFS
CPU_GOV=${1:-}; CPU_MIN=${2:-}; CPU_MAX=${3:-}; GPU_GOV=${4:-}
DDR_MIN=${5:-}; DDR_MAX=${6:-}

w() { [ -e "$1" ] && echo "$2" > "$1" 2>/dev/null; }

# Нижняя доступная частота — чтобы опустить пол перед установкой потолка.
# Иначе порядок записи начинает значить: новый потолок ниже текущего пола
# ядро не примет, и наоборот.
LOWEST=$(set -- $(cat "$CPU/scaling_available_frequencies" 2>/dev/null); echo "${1:-}")

[ -n "$CPU_GOV" ] && w "$CPU/scaling_governor" "$CPU_GOV"
[ -n "$LOWEST"  ] && w "$CPU/scaling_min_freq" "$LOWEST"
[ -n "$CPU_MAX" ] && w "$CPU/scaling_max_freq" "$CPU_MAX"
[ -n "$CPU_MIN" ] && w "$CPU/scaling_min_freq" "$CPU_MIN"
[ -n "$GPU_GOV" ] && [ -n "$GPU" ] && w "$GPU/governor" "$GPU_GOV"

# Память. Порядок тот же, что у процессора: сначала распускаем границы на весь
# список, потом ставим потолок, потом пол. Иначе ядро не примет потолок ниже
# текущего пола. Роспуск заодно снимает ограничение, поставленное прежним
# режимом, - без него powersave оставлял бы свой потолок навсегда.
if [ -n "$DMC" ]; then
    DDR_LO=; DDR_HI=
    for f in $(cat "$DMC/available_frequencies" 2>/dev/null); do
        [ -z "$DDR_LO" ] || [ "$f" -lt "$DDR_LO" ] && DDR_LO=$f
        [ -z "$DDR_HI" ] || [ "$f" -gt "$DDR_HI" ] && DDR_HI=$f
    done
    [ -n "$DDR_LO" ] && w "$DMC/min_freq" "$DDR_LO"
    [ -n "$DDR_HI" ] && w "$DMC/max_freq" "$DDR_HI"

    # Ближайшая доступная: для потолка не выше заданной, для пола не ниже.
    if [ -n "$DDR_MAX" ]; then
        PICK=
        for f in $(cat "$DMC/available_frequencies" 2>/dev/null); do
            [ "$f" -le "$DDR_MAX" ] || continue
            [ -z "$PICK" ] || [ "$f" -gt "$PICK" ] && PICK=$f
        done
        [ -n "$PICK" ] && w "$DMC/max_freq" "$PICK"
    fi
    if [ -n "$DDR_MIN" ]; then
        PICK=
        for f in $(cat "$DMC/available_frequencies" 2>/dev/null); do
            [ "$f" -ge "$DDR_MIN" ] || continue
            [ -z "$PICK" ] || [ "$f" -lt "$PICK" ] && PICK=$f
        done
        [ -n "$PICK" ] && w "$DMC/min_freq" "$PICK"
    fi
fi

log -t rg52-perf "режим $MODE: cpu $(cat $CPU/scaling_governor 2>/dev/null) \
$(cat $CPU/scaling_min_freq 2>/dev/null)-$(cat $CPU/scaling_max_freq 2>/dev/null), \
gpu $(cat ${GPU:-/dev/null}/governor 2>/dev/null), ddr $(cat ${DMC:-/dev/null}/min_freq 2>/dev/null)-$(cat ${DMC:-/dev/null}/max_freq 2>/dev/null)"
