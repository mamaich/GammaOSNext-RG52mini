#!/system/bin/sh
# Удерживает выбранную экранную клавиатуру после загрузки.
#
# Штатная клавиатура Android TV (`com.android.inputmethod.leanback`) на этом
# устройстве неудобна, поэтому в образ положена LeanKey. Одного присутствия в
# образе мало: система при каждой загрузке возвращает `default_input_method` на
# свою, причём не сразу, а когда поднимется служба ввода — однократной записи в
# начале загрузки не хватает. Список включённых методов при этом сохраняется,
# слетает только выбор по умолчанию.
#
# Другую клавиатуру можно закрепить своим свойством:
#
#     setprop persist.rg52.ime <имя>
#
# Имена установленных: `ime list -a -s`. Свойство persist.* живёт на разделе
# данных: переживает перезагрузку, но не перепрошивку.
#
# Если пакета нет (клавиатуру удалили), скрипт молча ничего не делает.

IME=$(getprop persist.rg52.ime 2>/dev/null)
[ -z "$IME" ] && IME=com.liskovsoft.leankeyboard/.ime.LeanbackImeService

PKG=${IME%%/*}

set_it() {
    pm path "$PKG" > /dev/null 2>&1 || return 1
    cur=$(settings get secure default_input_method 2>/dev/null)
    [ "$cur" = "$IME" ] && return 0
    ime enable "$IME" > /dev/null 2>&1
    ime set "$IME" > /dev/null 2>&1 || return 1
    log -t rg52-ime "default_input_method $cur -> $IME"
    return 0
}

i=0
while [ $i -lt 30 ]; do
    set_it
    sleep 2
    i=$((i + 1))
done

log -t rg52-ime "done, method=$(settings get secure default_input_method 2>/dev/null)"
