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
#     <рег. cpu>:<мин. cpu>:<макс. cpu>:<рег. gpu>:<мин. память>:<макс. память>:<макс. gpu>
#
# Седьмое поле - потолок графики, по умолчанию 900 МГц (верх штатной таблицы).
# В полях частот процессора тоже можно писать max - верхняя ступень вместе с
# turbo.
#
# Два последних поля необязательны, пустое значит «не ограничивать», max -
# верхняя ступень из списка (пол max прибивает память к максимуму). Заданное
# ими не прописывается в память числом: список частот у неё не фиксирован, он
# приходит от ATF и зависит от загрузчика. На штатном устройстве это
# 324/528/780/798 МГц, на устройстве с поднятой частотой - 324/528/780/928.
# Поэтому из available_frequencies выбирается ближайшая подходящая: для потолка
# наибольшая не выше заданной, для пола наименьшая не ниже.
#
# Про память по умолчанию. Ограничивается только powersave сверху (528 МГц) и
# max снизу. Режим max пользователь выбирает осознанно, поэтому память в нём
# прибита к верхней ступени (пол = потолок): 928 МГц с поднятой частотой, 798 на
# штатном. Числом это не задать - на штатном устройстве пол «не ниже 928» не
# нашёл бы ни одной ступени, отсюда значение max. Цена - постоянный лишний
# нагрев и расход, пока режим включён; выигрыш - там, где dmc_ondemand не
# успевает поднять частоту к пику нагрузки на память.
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
# Про режим overclock (в меню «Overclock»). Всё на верхнюю ступень из таблиц
# ядра: процессор с включённым boost (2208 МГц на разгонном дереве), графика
# 1000 МГц, память 928, пол процессора равен потолку. Ступени
# разгона есть только в дереве с ними и работают только с BL31, в таблицу
# которого они вписаны (u-boot: tools/rg52mini/bl31_oc.py); на штатном BL31
# режим сводится к max с графикой на верхней штатной ступени. Защиту от
# перегрева режим не отключает: пороги троттлинга и аварийное выключение
# остаются. Через перезагрузку не сохраняется - при загрузке будет max.
#
# Про режим max. Верх штатных таблиц оригинальной прошивки, то есть частоты,
# рекомендованные вендором (процессор 2016 МГц, графика 900 МГц), без разгона;
# память на верхней ступени.
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
# Выбор по питанию перебивал бы сохранённый режим на каждой загрузке, поэтому
# по умолчанию включена галка «Remember performance mode across reboots» (она
# есть в обоих приложениях настроек - GammaOS Toolbox и настройки оболочки
# nano), она же свойство:
#
#     setprop persist.rg52.perf.remember_mode 0
#
# Снимешь галку - режим на каждой загрузке выбирается по источнику питания: с
# подключённой зарядкой max, от батареи stock. Умолчание сменилось на обратное
# после того, как стало ясно, что чаще мешает именно подмена: выбранный режим
# должен оставаться выбранным.
BOOTING=
if [ "$MODE" = boot ]; then
    BOOTING=1
    MODE=""
    if [ "$(getprop persist.rg52.perf.remember_mode 1)" != 1 ]; then
        if on_external_power; then
            MODE=max
            log -t rg52-perf "boot on external power: mode max"
        else
            MODE=stock
            log -t rg52-perf "boot on battery: mode stock"
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

# Разгон не переживает перезагрузку: если ступени разгона на этом экземпляре
# чипа нестабильны, сохранённый overclock ронял бы систему на каждой загрузке
# сразу после boot_completed. Поэтому при загрузке он заменяется на max.
if [ "$BOOTING" = 1 ] && [ "$MODE" = overclock ]; then
    MODE=max
    setprop persist.gammaos.performance_mode max
    log -t rg52-perf "boot: overclock is not kept across reboots, mode max"
fi
# То же для режима, запаркованного drastic-nano на время игры с собственным режимом
# (persist.gammaos.drastic.perf_restore): после перезагрузки посреди такой игры оболочка
# вернула бы запаркованный overclock.
if [ "$BOOTING" = 1 ] && [ "$(getprop persist.gammaos.drastic.perf_restore)" = overclock ]; then
    setprop persist.gammaos.drastic.perf_restore max
    log -t rg52-perf "boot: parked overclock replaced with max"
fi

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
        log -t rg52-perf "lock $LOCK busy for 5 s, applying without it"
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
    max)       DEF=performance:1416000:2016000:performance:max: ;;
    overclock) DEF=performance:max:max:performance:max::max ;;
    3d_game)   DEF=schedutil:408000:1416000:simple_ondemand ;;
    stock|*)   MODE=stock; DEF=schedutil:408000:2016000:simple_ondemand ;;
esac

SPEC=$(getprop "persist.rg52.perf.$MODE")
[ -z "$SPEC" ] && SPEC=$DEF

OLDIFS=$IFS; IFS=:; set -- $SPEC; IFS=$OLDIFS
CPU_GOV=${1:-}; CPU_MIN=${2:-}; CPU_MAX=${3:-}; GPU_GOV=${4:-}
DDR_MIN=${5:-}; DDR_MAX=${6:-}; GPU_MAX=${7:-}
# Потолок графики по умолчанию - 900 МГц, верх штатной таблицы. Ступень
# 1000 МГц из разгонного дерева без turbo-mode, и без потолка simple_ondemand
# и performance забирались бы на неё в любом режиме.
[ -z "$GPU_MAX" ] && GPU_MAX=900000000

w() { [ -e "$1" ] && echo "$2" > "$1" 2>/dev/null; }

# Нижняя доступная частота — чтобы опустить пол перед установкой потолка.
# Иначе порядок записи начинает значить: новый потолок ниже текущего пола
# ядро не примет, и наоборот.
LOWEST=$(set -- $(cat "$CPU/scaling_available_frequencies" 2>/dev/null); echo "${1:-}")

[ -n "$CPU_GOV" ] && w "$CPU/scaling_governor" "$CPU_GOV"
[ -n "$LOWEST"  ] && w "$CPU/scaling_min_freq" "$LOWEST"
# Ступень 2208 МГц в разгонном дереве помечена turbo-mode: пока boost выключен,
# потолок её не видит. Включается только в overclock.
w /sys/devices/system/cpu/cpufreq/boost "$([ "$MODE" = overclock ] && echo 1 || echo 0)"

# Тепловые пороги. В overclock троттлинг начинается позже: power_allocator
# включается с 83 °C и держит чип около 93 (штатно 75 и 85). Окно то же, 10 °C:
# коэффициенты регулятора ядро считает один раз при загрузке из штатных порогов
# (k_po = sustainable_power / окно) и при смене порогов не пересчитывает, так
# что с другим окном регулятор поджимал бы сильнее или слабее задуманного. Цель
# 93, а не 95: выше 95 °C rockchip,high-temp отключает у процессора ступени
# выше 1,1 В (2208 и 2016 -> 1800 МГц) и возвращает их только ниже 90 °C
# (temp-hysteresis 5 °C); с целью 95 и выше процессор застревал бы на 1800.
# Совсем не выключаем (policy user_space) намеренно: у таблицы графики в
# дереве нет rockchip,high-temp, и без регулятора графику не сдерживало бы
# ничего до аварийного выключения на 115 °C посреди игры.
# Критический порог 115 °C и аппаратный сброс tsadc на 120 °C не трогаем.
# Пороги записываются только при CONFIG_THERMAL_WRITABLE_TRIPS; порядок -
# сперва верхний при подъёме, сперва нижний при возврате.
TZ=
for z in /sys/class/thermal/thermal_zone*; do
    [ "$(cat "$z/type" 2>/dev/null)" = soc-thermal ] && TZ=$z && break
done
if [ -n "$TZ" ]; then
    if [ "$MODE" = overclock ]; then
        w "$TZ/trip_point_1_temp" 93000
        w "$TZ/trip_point_0_temp" 83000
    else
        w "$TZ/trip_point_0_temp" 75000
        w "$TZ/trip_point_1_temp" 85000
    fi
    [ "$(cat "$TZ/policy" 2>/dev/null)" = power_allocator ] || w "$TZ/policy" power_allocator
fi
# max в поле частоты процессора - верхняя ступень из списка вместе с turbo.
CPU_TOP=
for f in $(cat "$CPU/scaling_available_frequencies" "$CPU/scaling_boost_frequencies" 2>/dev/null); do
    [ -z "$CPU_TOP" ] || [ "$f" -gt "$CPU_TOP" ] && CPU_TOP=$f
done
[ "$CPU_MAX" = max ] && CPU_MAX=$CPU_TOP
[ "$CPU_MIN" = max ] && CPU_MIN=$CPU_TOP
[ -n "$CPU_MAX" ] && w "$CPU/scaling_max_freq" "$CPU_MAX"
[ -n "$CPU_MIN" ] && w "$CPU/scaling_min_freq" "$CPU_MIN"
[ -n "$GPU_GOV" ] && [ -n "$GPU" ] && w "$GPU/governor" "$GPU_GOV"
# Графика: потолок - ближайшая ступень не выше заданной, max - верхняя.
if [ -n "$GPU" ]; then
    PICK=
    for f in $(cat "$GPU/available_frequencies" 2>/dev/null); do
        [ "$GPU_MAX" = max ] || [ "$f" -le "$GPU_MAX" ] || continue
        [ -z "$PICK" ] || [ "$f" -gt "$PICK" ] && PICK=$f
    done
    [ -n "$PICK" ] && w "$GPU/max_freq" "$PICK"
fi

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
    # Пол max держится регулятором, а не min_freq: HAL питания Rockchip из
    # vendor (android.hardware.power-service.rockchip) на подсказках питания сам
    # переписывает min_freq памяти (как и scaling_min_freq процессора) и сбивал
    # бы её на 324 МГц - так и было, пока здесь стояла запись в min_freq.
    # Регулятор performance держит max_freq, а его HAL не трогает. В остальных
    # режимах возвращается штатный dmc_ondemand.
    if [ "$DDR_MIN" = max ]; then
        w "$DMC/governor" performance
    else
        [ "$(cat "$DMC/governor" 2>/dev/null)" = dmc_ondemand ] || w "$DMC/governor" dmc_ondemand
    fi
    if [ "$DDR_MIN" = max ]; then
        :
    elif [ -n "$DDR_MIN" ]; then
        PICK=
        for f in $(cat "$DMC/available_frequencies" 2>/dev/null); do
            [ "$f" -ge "$DDR_MIN" ] || continue
            [ -z "$PICK" ] || [ "$f" -lt "$PICK" ] && PICK=$f
        done
        [ -n "$PICK" ] && w "$DMC/min_freq" "$PICK"
    fi
fi

# Опрос геймпада. Стики, курки, B, X, Y и крестовина (кроме «вверх») сидят на
# АЦП, и драйвер опрашивает их по таймеру. Его 16 мс из дерева устройства на
# деле давали период 20 мс: таймер ядра тикает по 3,3 мс (HZ=300), и к пяти-шести
# тикам прибавляется время самого опроса. 50 опросов в секунду на игре в 60
# кадров - это кадр без свежих данных стика примерно каждые шесть кадров, отсюда
# подёргивание камеры в 3D. С 8 мс выходит 76 опросов в секунду (замер по
# прерываниям АЦП) ценой около 1 % одного ядра. В powersave остаётся 16 мс.
#
# persist.rg52.joypad.poll_ms задаёт интервал явно, в любом режиме, и действует
# сразу (триггер в rg52-perf.rc). Драйвер принимает 8-100 мс: значение вне
# диапазона прижимается к границе. 10# - чтобы "08" не читалось как восьмеричное.
POLL=$(getprop persist.rg52.joypad.poll_ms)
case "$POLL" in
    ''|*[!0-9]*) POLL=8; [ "$MODE" = powersave ] && POLL=16 ;;
    *) POLL=$((10#$POLL)); [ "$POLL" -lt 8 ] && POLL=8; [ "$POLL" -gt 100 ] && POLL=100 ;;
esac
JOY=none
for d in /sys/class/input/input*; do
    read -r NAME 2>/dev/null < "$d/name" || continue
    if [ "$NAME" = retrogame_joypad ]; then
        w "$d/poll" "$POLL"
        read -r JOY 2>/dev/null < "$d/poll" || JOY=?
    fi
done

log -t rg52-perf "mode $MODE: cpu $(cat $CPU/scaling_governor 2>/dev/null) \
$(cat $CPU/scaling_min_freq 2>/dev/null)-$(cat $CPU/scaling_max_freq 2>/dev/null), \
gpu $(cat ${GPU:-/dev/null}/governor 2>/dev/null) max $(cat ${GPU:-/dev/null}/max_freq 2>/dev/null), boost $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null), thermal $(cat ${TZ:-/dev/null}/trip_point_0_temp 2>/dev/null)/$(cat ${TZ:-/dev/null}/trip_point_1_temp 2>/dev/null), ddr $(cat ${DMC:-/dev/null}/governor 2>/dev/null) $(cat ${DMC:-/dev/null}/min_freq 2>/dev/null)-$(cat ${DMC:-/dev/null}/max_freq 2>/dev/null), \
joypad poll ${JOY} ms"
