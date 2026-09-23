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
#     <регулятор cpu>:<мин. частота cpu>:<макс. частота cpu>:<регулятор gpu>
#
# Про режим 3d_game. Он снижает потолок процессора, а графику оставляет
# свободной. Смысл в тепловом бюджете: четыре ядра съедают его заметно
# больше, чем одно графическое, и при перегреве выгоднее придержать их, чем
# позволить троттлингу резать кадры в игре.

set -u

MODE=${1:-}
[ -z "$MODE" ] && MODE=$(getprop persist.gammaos.performance_mode)
[ -z "$MODE" ] && MODE=stock

CPU=/sys/devices/system/cpu/cpufreq/policy0
# Имя узла графики зависит от SoC: на RK3562 это ff320000.gpu. Ищем, а не
# прописываем, чтобы скрипт пережил смену платы. dmc — контроллер памяти,
# он сюда не годится.
GPU=
for d in /sys/class/devfreq/*gpu*; do
    [ -d "$d" ] && GPU=$d && break
done

case "$MODE" in
    powersave) DEF=schedutil:408000:1416000:powersave ;;
    max)       DEF=performance:1416000:2016000:performance ;;
    3d_game)   DEF=schedutil:408000:1416000:simple_ondemand ;;
    stock|*)   MODE=stock; DEF=schedutil:408000:2016000:simple_ondemand ;;
esac

SPEC=$(getprop "persist.rg52.perf.$MODE")
[ -z "$SPEC" ] && SPEC=$DEF

OLDIFS=$IFS; IFS=:; set -- $SPEC; IFS=$OLDIFS
CPU_GOV=${1:-}; CPU_MIN=${2:-}; CPU_MAX=${3:-}; GPU_GOV=${4:-}

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

log -t rg52-perf "режим $MODE: cpu $(cat $CPU/scaling_governor 2>/dev/null) \
$(cat $CPU/scaling_min_freq 2>/dev/null)-$(cat $CPU/scaling_max_freq 2>/dev/null), \
gpu $(cat ${GPU:-/dev/null}/governor 2>/dev/null)"
