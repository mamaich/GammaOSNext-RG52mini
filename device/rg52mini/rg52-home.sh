#!/system/bin/sh
# Восстановление домашнего экрана.
#
# Зачем. Если ни один лаунчер не назначен домашним, система вместо оболочки
# показывает диалог выбора. На этом устройстве он оказывается недосягаем: он
# висит под меню выключателя, кнопки до него не доходят, курсор мыши тоже -
# экран выглядит мёртвым, хотя загрузка дошла до конца. Ровно это и случилось
# после перезагрузки в безопасный режим.
#
# Почему штатного назначения мало. Его делает post-хук в gammaos/setup.sh, но
# он привязан к установке пакетов. Если тот проход случился в безопасном
# режиме, сторонние приложения отключены, Daijisho не существует как кандидат
# на HOME, и назначение не удерживается. Потом обычная загрузка возвращает
# приложения - а предпочтение остаётся пустым.
#
# Что делает этот скрипт. Смотрит, разрешается ли HOME во что-то осмысленное.
# Если да - не трогает ничего, в том числе если вы намеренно выбрали другой
# лаунчер. Если разрешение пустое или ведёт в диалог выбора - назначает
# Daijisho. Компонент ищется динамически: в 1.8.1 он переехал с .app.HomeActivity
# на .ui.activities.BootstrapActivity, и жёстко прописанное имя уже один раз
# оставляло устройство без домашнего экрана.
#
# Выключается: setprop persist.rg52.home_guard 0

TAG=rg52-home
PKG=com.magneticchen.daijishou

[ "$(getprop persist.rg52.home_guard 1)" = "0" ] && exit 0

res=$(cmd package resolve-activity --brief \
        -a android.intent.action.MAIN \
        -c android.intent.category.HOME 2>/dev/null | tail -1)

case "$res" in
    *ResolverActivity*|*"No activity found"*|"")
        ;;                      # чинить
    *)
        exit 0 ;;               # домашний экран есть, не вмешиваемся
esac

home=$(cmd package query-activities --components \
        -a android.intent.action.MAIN \
        -c android.intent.category.HOME 2>/dev/null | tr -d '\r' \
        | grep -oE "$PKG/[A-Za-z0-9_.]+" | head -n1)

# Запасное имя на случай, если опрос вернул пусто: так же поступает и
# post-хук в gammaos/setup.sh. Но только если пакет вообще установлен -
# назначать несуществующее бессмысленно.
if [ -z "$home" ]; then
    if pm path "$PKG" >/dev/null 2>&1; then
        home=$PKG/.ui.activities.BootstrapActivity
    else
        log -p w -t $TAG "домашний экран не назначен, а $PKG не установлен - пропускаю"
        exit 1
    fi
fi

if cmd package set-home-activity "$home" >/dev/null 2>&1; then
    log -t $TAG "домашний экран был не назначен, назначен $home"
else
    log -p w -t $TAG "не удалось назначить $home"
    exit 1
fi
